-- =====================================================================
-- KOIN — BAGIAN 15: BULK ORDER (BEM + SEM + LEM dalam 1 pesanan)
-- Jalankan SETELAH koin-usdt-14-modal.sql (dan bot-order.sql, bot-order-kirim-arsip.sql, koin-usdt-3). Aman diulang.
--
-- Pelanggan mengisi tagar untuk BEM / SEM / LEM sekaligus (total 1–100 tagar) + catatan.
-- Pesanan masuk ke antrian Bot Order admin (baris bertanda BULK), daftar tagar per paket + catatan bisa dibuka admin.
-- Harga diatur admin di menu Price (per tagar, 4 tier berdasarkan JUMLAH TOTAL tagar dalam 1 pesanan):
--     tier 1 = 1–5 tagar, tier 2 = 6–10, tier 3 = 11–50, tier 4 = 51–100.
-- Pembayaran memakai koin (sama seperti bot order); ditolak / dihapus saat menunggu -> koin kembali.
-- Setujui -> otomatis tercatat di BSL Profit (modal dari menu Modal: modal Bot BEM/SEM/LEM x jumlah tagar).
-- =====================================================================

-- harga per tagar per tier (t1..t4) per paket
do $$
declare t text; d text;
begin
    foreach t in array array['t1', 't2', 't3', 't4'] loop
        foreach d in array array['bem', 'sem', 'lem'] loop
            execute format('alter table price_settings add column if not exists bulk_%s_%s integer not null default 0 check (bulk_%s_%s >= 0)', t, d, t, d);
        end loop;
    end loop;
end $$;
alter table price_settings add column if not exists avail_bulk boolean not null default true;

-- bot_orders: izinkan dashboard 'BULK' + simpan tagar per paket
alter table bot_orders drop constraint if exists bot_orders_dashboard_check;
alter table bot_orders add constraint bot_orders_dashboard_check check (dashboard in ('BEM', 'SEM', 'LEM', 'BULK'));
alter table bot_orders add column if not exists tagar_bem text[];
alter table bot_orders add column if not exists tagar_sem text[];
alter table bot_orders add column if not exists tagar_lem text[];
alter table bot_orders add column if not exists bulk_tier integer;

-- ---------------- ADMIN: harga bulk ----------------
-- p_prices = {"t1_bem": 100, "t1_sem": 120, ... "t4_lem": 80}
create or replace function pr_save_bulk(p_pin text, p_prices jsonb, p_avail boolean default true)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare r record; t text; d text;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    for r in select key, value from jsonb_each_text(coalesce(p_prices, '{}'::jsonb)) loop
        if r.key !~ '^t[1-4]_(bem|sem|lem)$' then raise exception 'Kode harga tidak valid: %', r.key; end if;
        if coalesce(r.value, '') !~ '^[0-9]{1,9}$' or r.value::bigint > 100000000 then raise exception 'Harga % harus angka bulat 0 – 100.000.000', r.key; end if;
        execute format('update price_settings set bulk_%s = %s where id = 1', r.key, r.value::bigint);
    end loop;
    update price_settings set avail_bulk = coalesce(p_avail, true), updated_at = now() where id = 1;
end; $$;

-- ---------------- PELANGGAN ----------------
create or replace function bulk_tier_of(p_n integer)
returns integer language sql immutable as $$
    select case when p_n between 1 and 5 then 1 when p_n between 6 and 10 then 2 when p_n between 11 and 50 then 3 when p_n between 51 and 100 then 4 else null end;
$$;

-- tabel harga yang dilihat pelanggan
create or replace function cu_bulk_info(p_session_token uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare acc customer_accounts%rowtype; s price_settings%rowtype;
begin
    acc := portal_session_acc(p_session_token);
    select * into s from price_settings where id = 1;
    return jsonb_build_object('avail', s.avail_bulk, 'max', 100,
        'tiers', jsonb_build_array(
            jsonb_build_object('tier', 1, 'min', 1, 'max', 5,   'BEM', s.bulk_t1_bem, 'SEM', s.bulk_t1_sem, 'LEM', s.bulk_t1_lem),
            jsonb_build_object('tier', 2, 'min', 6, 'max', 10,  'BEM', s.bulk_t2_bem, 'SEM', s.bulk_t2_sem, 'LEM', s.bulk_t2_lem),
            jsonb_build_object('tier', 3, 'min', 11, 'max', 50, 'BEM', s.bulk_t3_bem, 'SEM', s.bulk_t3_sem, 'LEM', s.bulk_t3_lem),
            jsonb_build_object('tier', 4, 'min', 51, 'max', 100, 'BEM', s.bulk_t4_bem, 'SEM', s.bulk_t4_sem, 'LEM', s.bulk_t4_lem)));
end; $$;

-- rapikan 1 daftar tagar: trim, buang kosong, buang kembar (abaikan # dan huruf besar/kecil)
create or replace function bulk_clean_tags(p_list text[])
returns text[] language plpgsql immutable as $$
declare v_list text[] := '{}'; v_norm text[] := '{}'; x text; n text;
begin
    foreach x in array coalesce(p_list, '{}') loop
        x := trim(x);
        continue when x = '';
        if length(x) > 100 then raise exception 'Tagar maksimal 100 karakter'; end if;
        n := lower(replace(x, '#', ''));
        if not (n = any(v_norm)) then v_list := v_list || x; v_norm := v_norm || n; end if;
    end loop;
    return v_list;
end; $$;

create or replace function cu_request_bulk_order(p_session_token uuid, p_bem text[], p_sem text[], p_lem text[], p_catatan text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare acc customer_accounts%rowtype; s price_settings%rowtype;
        lb text[]; ls text[]; ll text[]; v_n integer; v_tier integer;
        pb integer; ps integer; pl integer; v_total bigint; v_id bigint;
        v_note text := nullif(left(trim(coalesce(p_catatan, '')), 500), '');
begin
    acc := portal_session_acc(p_session_token);
    lb := bulk_clean_tags(p_bem); ls := bulk_clean_tags(p_sem); ll := bulk_clean_tags(p_lem);
    v_n := cardinality(lb) + cardinality(ls) + cardinality(ll);
    if v_n = 0 then raise exception 'Tagar wajib diisi'; end if;
    if v_n > 100 then raise exception 'Bulk Order maksimal 100 tagar per pesanan'; end if;
    v_tier := bulk_tier_of(v_n);

    select * into s from price_settings where id = 1;
    if not s.avail_bulk then raise exception 'Bulk Order sedang tidak tersedia'; end if;
    pb := case v_tier when 1 then s.bulk_t1_bem when 2 then s.bulk_t2_bem when 3 then s.bulk_t3_bem else s.bulk_t4_bem end;
    ps := case v_tier when 1 then s.bulk_t1_sem when 2 then s.bulk_t2_sem when 3 then s.bulk_t3_sem else s.bulk_t4_sem end;
    pl := case v_tier when 1 then s.bulk_t1_lem when 2 then s.bulk_t2_lem when 3 then s.bulk_t3_lem else s.bulk_t4_lem end;
    if (cardinality(lb) > 0 and pb <= 0) or (cardinality(ls) > 0 and ps <= 0) or (cardinality(ll) > 0 and pl <= 0) then
        raise exception 'Harga Bulk Order belum diatur admin';
    end if;
    v_total := cardinality(lb)::bigint * pb + cardinality(ls)::bigint * ps + cardinality(ll)::bigint * pl;

    insert into bot_orders (customer_id, username, dashboard, tagar_list, tagar_bem, tagar_sem, tagar_lem, bulk_tier, jumlah, catatan_pelanggan,
                            harga_tagar, total_harga, koin_dipotong)
    values (acc.id, acc.username, 'BULK', lb || ls || ll, lb, ls, ll, v_tier, v_n, v_note,
            ((v_total + v_n - 1) / v_n), v_total, v_total)
    returning id into v_id;
    perform coin_apply(acc.id, -v_total, 'order', 'Bulk Order · ' || v_n || ' tagar', 'bot', v_id);
    return jsonb_build_object('id', v_id, 'status', 'pending', 'jumlah', v_n, 'tier', v_tier, 'total', v_total,
                              'bem', cardinality(lb), 'sem', cardinality(ls), 'lem', cardinality(ll));
end; $$;

-- ---------------- daftar tagar: bulk -> {bem:[..], sem:[..], lem:[..]}, biasa -> [..] ----------------
create or replace function bot_tags(p_pin text, p_id bigint)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare b bot_orders%rowtype;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    select * into b from bot_orders where id = p_id;
    if not found then raise exception 'Pesanan tidak ditemukan'; end if;
    if b.dashboard = 'BULK' then
        return jsonb_build_object('bem', to_jsonb(coalesce(b.tagar_bem, '{}')), 'sem', to_jsonb(coalesce(b.tagar_sem, '{}')), 'lem', to_jsonb(coalesce(b.tagar_lem, '{}')));
    end if;
    return to_jsonb(b.tagar_list);
end; $$;

create or replace function cu_bot_tags(p_session_token uuid, p_id bigint)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare acc customer_accounts%rowtype; b bot_orders%rowtype;
begin
    acc := portal_session_acc(p_session_token);
    select * into b from bot_orders where id = p_id and customer_id = acc.id;
    if not found then raise exception 'Pesanan tidak ditemukan'; end if;
    if b.dashboard = 'BULK' then
        return jsonb_build_object('bem', to_jsonb(coalesce(b.tagar_bem, '{}')), 'sem', to_jsonb(coalesce(b.tagar_sem, '{}')), 'lem', to_jsonb(coalesce(b.tagar_lem, '{}')));
    end if;
    return to_jsonb(b.tagar_list);
end; $$;

-- antrian admin & riwayat pelanggan: ikut membawa jumlah per paket + tier
create or replace function bot_list(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v jsonb;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    select coalesce(jsonb_agg(to_jsonb(r) order by r.created_at desc), '[]'::jsonb) into v
    from (select b.id, b.username, b.dashboard, b.jumlah, b.tagar_list[1] as tagar_pertama, b.catatan_pelanggan,
                 b.harga_tagar, b.total_harga, b.status, b.catatan_admin, b.created_at, b.processed_at,
                 b.dikirim_at, b.arsip, b.arsip_at, b.bulk_tier,
                 coalesce(cardinality(b.tagar_bem), 0) as n_bem, coalesce(cardinality(b.tagar_sem), 0) as n_sem, coalesce(cardinality(b.tagar_lem), 0) as n_lem,
                 (select ca.whatsapp from customer_accounts ca where ca.id = b.customer_id) as whatsapp
            from bot_orders b order by b.created_at desc limit 500) r;
    return v;
end; $$;

create or replace function cu_my_bot_orders(p_session_token uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare acc customer_accounts%rowtype; v jsonb;
begin
    acc := portal_session_acc(p_session_token);
    select coalesce(jsonb_agg(jsonb_build_object(
        'id', b.id, 'dashboard', b.dashboard, 'jumlah', b.jumlah, 'tagar_pertama', b.tagar_list[1],
        'harga_tagar', b.harga_tagar, 'total_harga', b.total_harga, 'status', b.status,
        'catatan_admin', b.catatan_admin, 'created_at', b.created_at, 'processed_at', b.processed_at,
        'dikirim_at', b.dikirim_at, 'arsip', b.arsip, 'bulk_tier', b.bulk_tier,
        'n_bem', coalesce(cardinality(b.tagar_bem), 0), 'n_sem', coalesce(cardinality(b.tagar_sem), 0), 'n_lem', coalesce(cardinality(b.tagar_lem), 0)
    ) order by b.created_at desc), '[]'::jsonb) into v
    from (select * from bot_orders where customer_id = acc.id order by created_at desc limit 100) b;
    return v;
end; $$;

-- ---------------- SETUJUI: modal Bulk = jumlah tagar tiap paket x modal Bot paket itu (menu Modal) ----------------
create or replace function bot_approve(p_pin text, p_id bigint)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare b bot_orders%rowtype; v_m integer; v_modal bigint; v_ket text;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    select * into b from bot_orders where id = p_id for update;
    if not found then raise exception 'Pesanan tidak ditemukan'; end if;
    if b.status <> 'pending' then raise exception 'Pesanan ini sudah diproses'; end if;

    if b.dashboard = 'BULK' then
        v_modal := coalesce(cardinality(b.tagar_bem), 0)::bigint * md_get('bsl:bot_bem')
                 + coalesce(cardinality(b.tagar_sem), 0)::bigint * md_get('bsl:bot_sem')
                 + coalesce(cardinality(b.tagar_lem), 0)::bigint * md_get('bsl:bot_lem');
        v_ket := 'Bulk Order #' || b.id || ' · BEM ' || coalesce(cardinality(b.tagar_bem), 0) || ' / SEM ' || coalesce(cardinality(b.tagar_sem), 0)
                 || ' / LEM ' || coalesce(cardinality(b.tagar_lem), 0);
        insert into bsl_entries (tanggal, jenis, kategori, pelanggan, keterangan, hari, jumlah_tagar, harga_hari, modal_hari, omset, modal, bot_order_id)
        values ((now() at time zone 'Asia/Jakarta')::date, 'bot', 'BULK Bot', b.username, v_ket, null, b.jumlah, b.harga_tagar,
                greatest((v_modal + b.jumlah - 1) / b.jumlah, 0), b.total_harga, v_modal, b.id)
        on conflict (bot_order_id) where bot_order_id is not null do nothing;
    else
        v_m := md_get('bsl:bot_' || lower(case when b.dashboard in ('BEM', 'SEM') then b.dashboard else 'LEM' end));
        v_modal := v_m::bigint * b.jumlah;
        insert into bsl_entries (tanggal, jenis, kategori, pelanggan, keterangan, hari, jumlah_tagar, harga_hari, modal_hari, omset, modal, bot_order_id)
        values ((now() at time zone 'Asia/Jakarta')::date, 'bot', b.dashboard || ' Bot', b.username, 'Bot Order #' || b.id,
                null, b.jumlah, b.harga_tagar, v_m, b.total_harga, v_modal, b.id)
        on conflict (bot_order_id) where bot_order_id is not null do nothing;
    end if;

    update bot_orders set status = 'approved', processed_at = now() where id = b.id;
    return jsonb_build_object('id', b.id, 'omset', b.total_harga, 'modal', v_modal, 'profit', b.total_harga - v_modal);
end; $$;

-- arsipkan semua yang terkirim: p_bulk = true (hanya Bulk), false (hanya Bot biasa), null (semua)
drop function if exists bot_archive_sent(text);
create or replace function bot_archive_sent(p_pin text, p_bulk boolean default null)
returns integer language plpgsql security definer set search_path = public, extensions as $$
declare n integer;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    update bot_orders set arsip = true, arsip_at = now()
     where status = 'approved' and dikirim_at is not null and not arsip
       and (p_bulk is null or (dashboard = 'BULK') = p_bulk);
    get diagnostics n = row_count;
    return n;
end; $$;

grant execute on function
    bot_archive_sent(text, boolean),
    pr_save_bulk(text, jsonb, boolean), cu_bulk_info(uuid), cu_request_bulk_order(uuid, text[], text[], text[], text),
    bot_tags(text, bigint), cu_bot_tags(uuid, bigint), bot_list(text), cu_my_bot_orders(uuid), bot_approve(text, bigint)
to anon, authenticated;
