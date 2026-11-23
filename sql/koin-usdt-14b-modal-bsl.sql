-- =====================================================================
-- KOIN — BAGIAN 14b/3: MODAL -> BSL PROFIT
-- Butuh koin-usdt-14-modal.sql. BSL Profit membaca modal dari menu Modal + Catat Penjualan Barang.
-- Aman diulang. Jalankan berurutan: 13, 14, 14b, 14c, 15.
-- =====================================================================

-- ---------------- BSL: baca modal dari modal_items ----------------
create or replace function bp_save_modal(p_pin text, p_bem integer, p_sem integer, p_lem integer)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    if least(coalesce(p_bem, -1), coalesce(p_sem, -1), coalesce(p_lem, -1)) < 0 then raise exception 'Modal tidak boleh kosong atau negatif'; end if;
    perform md_save(p_pin, jsonb_build_object('bsl:bem', p_bem, 'bsl:sem', p_sem, 'bsl:lem', p_lem));
end; $$;

create or replace function bp_save_modal_bot(p_pin text, p_bem integer, p_sem integer, p_lem integer)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    if least(coalesce(p_bem, -1), coalesce(p_sem, -1), coalesce(p_lem, -1)) < 0 then raise exception 'Modal tidak boleh kosong atau negatif'; end if;
    perform md_save(p_pin, jsonb_build_object('bsl:bot_bem', p_bem, 'bsl:bot_sem', p_sem, 'bsl:bot_lem', p_lem));
end; $$;

create or replace function bp_get(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    return jsonb_build_object(
        'settings', jsonb_build_object('modal_bem', md_get('bsl:bem'), 'modal_sem', md_get('bsl:sem'), 'modal_lem', md_get('bsl:lem'),
                                       'modal_bot_bem', md_get('bsl:bot_bem'), 'modal_bot_sem', md_get('bsl:bot_sem'), 'modal_bot_lem', md_get('bsl:bot_lem')),
        'harga', (select jsonb_build_object('bem', p.bem, 'sem', p.sem, 'lem', p.lem, 'bot_bem', p.bot_bem, 'bot_sem', p.bot_sem, 'bot_lem', p.bot_lem)
                    from price_settings p where p.id = 1),
        'entries', coalesce((select jsonb_agg(to_jsonb(e) order by e.tanggal desc, e.id desc)
                               from (select * from bsl_entries order by tanggal desc, id desc limit 5000) e), '[]'::jsonb)
    );
end; $$;

create or replace function bsl_request_approved()
returns trigger language plpgsql security definer set search_path = public, extensions as $$
declare v_dash text; v_n integer; v_m integer;
begin
    if new.status = 'approved' and old.status is distinct from 'approved' then
        v_dash := upper(coalesce(new.dashboard_baru, ''));
        v_n := greatest(coalesce(new.jumlah_item, cardinality(new.tagar_list), 1), 1);
        v_m := md_get('bsl:' || case v_dash when 'BEM' then 'bem' when 'SEM' then 'sem' else 'lem' end);
        insert into bsl_entries (tanggal, jenis, kategori, pelanggan, keterangan, hari, jumlah_tagar, harga_hari, modal_hari, omset, modal, request_id)
        values ((now() at time zone 'Asia/Jakarta')::date, 'request', v_dash, coalesce(new.nomor_pesanan, new.username, ''),
                case when new.source = 'new' then 'Pesanan baru' else 'Perpanjangan' end || ' #' || new.id
                    || case when new.kode_referal is not null then ' · kode ' || new.kode_referal else '' end,
                new.hari, v_n, new.harga_hari, v_m,
                coalesce(new.total_harga, 0), v_m::bigint * coalesce(new.hari, 0) * v_n, new.id)
        on conflict (request_id) where request_id is not null do nothing;
    end if;
    return new;
end; $$;

create or replace function bp_suggest(p_pin text, p_dashboard text, p_nama text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare acc customer_accounts%rowtype; q jsonb; v_dash text := upper(coalesce(p_dashboard, ''));
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    if v_dash not in ('BEM', 'SEM', 'LEM') then raise exception 'Paket tidak valid'; end if;
    if coalesce(trim(p_nama), '') <> '' then
        select * into acc from customer_accounts where match_key = normalize_pelanggan_name(p_nama) limit 1;
    end if;
    q := price_calc(coalesce(acc.id, -1), v_dash, 1, 1, null);
    return jsonb_build_object('normal_hari', q->'normal_hari', 'harga_hari', q->'harga_hari', 'jenis', q->'jenis',
        'istimewa', coalesce((q->>'istimewa')::boolean, false), 'akun', acc.username, 'modal_hari', md_get('bsl:' || lower(v_dash)));
end; $$;

create or replace function bp_add_sale(p_pin text, p_dashboard text, p_nama text, p_hari integer, p_jumlah integer,
                                       p_harga_hari integer, p_tanggal date default null, p_keterangan text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare acc customer_accounts%rowtype; q jsonb; v_dash text := upper(coalesce(p_dashboard, ''));
        v_harga integer; v_m integer; v_n integer := greatest(coalesce(p_jumlah, 1), 1); v_id bigint; v_omset bigint; v_modal bigint;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    if v_dash not in ('BEM', 'SEM', 'LEM') then raise exception 'Paket tidak valid'; end if;
    if p_hari is null or p_hari < 1 or p_hari > 3650 then raise exception 'Jumlah hari tidak valid'; end if;
    if coalesce(p_harga_hari, 0) < 0 or coalesce(p_harga_hari, 0) > 100000000 then raise exception 'Harga tidak valid'; end if;
    if coalesce(p_harga_hari, 0) > 0 then
        v_harga := p_harga_hari;
    else
        if coalesce(trim(p_nama), '') <> '' then
            select * into acc from customer_accounts where match_key = normalize_pelanggan_name(p_nama) limit 1;
        end if;
        q := price_calc(coalesce(acc.id, -1), v_dash, 1, 1, null);
        v_harga := coalesce((q->>'harga_hari')::integer, 0);
    end if;
    v_m := md_get('bsl:' || lower(v_dash));
    v_omset := v_harga::bigint * p_hari * v_n;
    v_modal := v_m::bigint * p_hari * v_n;
    insert into bsl_entries (tanggal, jenis, kategori, pelanggan, keterangan, hari, jumlah_tagar, harga_hari, modal_hari, omset, modal)
    values (coalesce(p_tanggal, (now() at time zone 'Asia/Jakarta')::date), 'langganan', v_dash, left(trim(coalesce(p_nama, '')), 120),
            left(trim(coalesce(p_keterangan, '')), 200), p_hari, v_n, v_harga, v_m, v_omset, v_modal)
    returning id into v_id;
    return jsonb_build_object('id', v_id, 'harga_hari', v_harga, 'omset', v_omset, 'modal', v_modal, 'profit', v_omset - v_modal);
end; $$;

create or replace function bp_add_bot(p_pin text, p_paket text, p_jumlah integer, p_pelanggan text default null,
                                       p_keterangan text default null, p_tanggal date default null, p_harga_tagar integer default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare pr price_settings%rowtype; v_paket text := upper(coalesce(p_paket, ''));
        v_harga integer; v_m integer; v_id bigint; v_omset bigint; v_modal bigint;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    if v_paket not in ('BEM', 'SEM', 'LEM') then raise exception 'Paket tidak valid'; end if;
    if p_jumlah is null or p_jumlah < 1 or p_jumlah > 1000000 then raise exception 'Jumlah tagar tidak valid'; end if;
    if coalesce(p_harga_tagar, 0) < 0 or coalesce(p_harga_tagar, 0) > 100000000 then raise exception 'Harga tidak valid'; end if;
    select * into pr from price_settings where id = 1;
    v_harga := case when coalesce(p_harga_tagar, 0) > 0 then p_harga_tagar
                    else case v_paket when 'BEM' then pr.bot_bem when 'SEM' then pr.bot_sem else pr.bot_lem end end;
    v_m := md_get('bsl:bot_' || lower(v_paket));
    v_omset := v_harga::bigint * p_jumlah;
    v_modal := v_m::bigint * p_jumlah;
    insert into bsl_entries (tanggal, jenis, kategori, pelanggan, keterangan, hari, jumlah_tagar, harga_hari, modal_hari, omset, modal)
    values (coalesce(p_tanggal, (now() at time zone 'Asia/Jakarta')::date), 'bot', v_paket || ' Bot',
            left(trim(coalesce(p_pelanggan, '')), 120), left(trim(coalesce(p_keterangan, '')), 200),
            null, p_jumlah, v_harga, v_m, v_omset, v_modal)
    returning id into v_id;
    return jsonb_build_object('id', v_id, 'harga_tagar', v_harga, 'omset', v_omset, 'modal', v_modal, 'profit', v_omset - v_modal);
end; $$;

create or replace function bot_approve(p_pin text, p_id bigint)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare b bot_orders%rowtype; v_m integer; v_modal bigint;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    select * into b from bot_orders where id = p_id for update;
    if not found then raise exception 'Pesanan tidak ditemukan'; end if;
    if b.status <> 'pending' then raise exception 'Pesanan ini sudah diproses'; end if;
    v_m := md_get('bsl:bot_' || lower(case when b.dashboard in ('BEM', 'SEM') then b.dashboard else 'LEM' end));
    v_modal := v_m::bigint * b.jumlah;
    insert into bsl_entries (tanggal, jenis, kategori, pelanggan, keterangan, hari, jumlah_tagar, harga_hari, modal_hari, omset, modal, bot_order_id)
    values ((now() at time zone 'Asia/Jakarta')::date, 'bot', b.dashboard || ' Bot', b.username, 'Bot Order #' || b.id,
            null, b.jumlah, b.harga_tagar, v_m, b.total_harga, v_modal, b.id)
    on conflict (bot_order_id) where bot_order_id is not null do nothing;
    update bot_orders set status = 'approved', processed_at = now() where id = b.id;
    return jsonb_build_object('id', b.id, 'omset', b.total_harga, 'modal', v_modal, 'profit', b.total_harga - v_modal);
end; $$;

-- Catat penjualan BARANG ke BSL Profit: pilih barang + jumlah. Harga jual = harga etalase (bisa di-override), modal = menu Modal.
create or replace function bp_add_item_sale(p_pin text, p_key text, p_qty integer, p_harga bigint default null, p_pelanggan text default null,
                                            p_keterangan text default null, p_tanggal date default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare it record; v_harga bigint; v_modal bigint; v_omset bigint; v_mt bigint; v_id bigint;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    if p_qty is null or p_qty < 1 or p_qty > 10000000 then raise exception 'Jumlah tidak valid'; end if;
    select * into it from md_all_items() i where i.key = p_key and p_key not like 'bsl:%';
    if not found then raise exception 'Barang tidak ditemukan di etalase'; end if;
    v_harga := case when coalesce(p_harga, 0) > 0 then p_harga else coalesce(it.harga, 0) end;
    if v_harga <= 0 then raise exception 'Harga jual belum diatur untuk barang ini'; end if;
    v_modal := md_get(p_key);
    v_omset := v_harga * p_qty; v_mt := v_modal * p_qty;
    insert into bsl_entries (tanggal, jenis, kategori, pelanggan, keterangan, omset, modal, item_key, item_nama, qty, harga_satuan, modal_satuan)
    values (coalesce(p_tanggal, (now() at time zone 'Asia/Jakarta')::date), 'manual', left(it.grup, 60), left(trim(coalesce(p_pelanggan, '')), 120),
            left(trim(coalesce(nullif(p_keterangan, ''), it.nama)), 200), v_omset, v_mt, p_key, left(it.nama, 120), p_qty, v_harga, v_modal)
    returning id into v_id;
    return jsonb_build_object('id', v_id, 'harga', v_harga, 'modal', v_modal, 'omset', v_omset, 'modal_total', v_mt, 'profit', v_omset - v_mt);
end; $$;

grant execute on function
    bp_save_modal(text, integer, integer, integer), bp_save_modal_bot(text, integer, integer, integer),
    bp_get(text), bp_suggest(text, text, text), bp_add_sale(text, text, text, integer, integer, integer, date, text),
    bp_add_bot(text, text, integer, text, text, date, integer), bot_approve(text, bigint),
    bp_add_item_sale(text, text, integer, bigint, text, text, date)
to anon, authenticated;
