-- =====================================================================
-- BOT ORDER (BEM / SEM / LEM Bot) — Price, BSL Profit, dan PEMESANAN oleh pelanggan
--
-- Jalankan SELURUH file ini SEKALI di Supabase SQL Editor.
-- Urutan: SETELAH price.sql dan bsl-profit.sql, SEBELUM fast-payment-arsip.sql. Aman dijalankan ulang.
-- (Menggantikan bulk-order.sql lama: bila Anda sudah menjalankannya, data harga/modal/catatan
--  "bulk" otomatis diganti namanya menjadi "bot".)
--
-- Isi:
--   1. Harga jual bot per tagar (terpisah dari harga harian)  -> price_settings.bot_bem/sem/lem
--   2. Modal bot per tagar (terpisah dari modal harian)       -> bsl_settings.modal_bot_bem/sem/lem
--   3. Jenis catatan 'bot' pada bsl_entries
--   4. Fungsi admin: pr_save_bot, bp_save_modal_bot, bp_add_bot (tambah manual)
--   5. PEMESANAN pelanggan: tabel bot_orders + cu_request_bot_order / cu_my_bot_orders,
--      antrian admin: bot_list / bot_tags / bot_approve / bot_reject / bot_delete
--   6. Saat admin SETUJUI bot order -> otomatis tercatat di BSL Profit (omset, modal, profit)
--
-- Aturan: omset = harga bot x jumlah tagar ; modal = modal bot x jumlah tagar ; profit = omset - modal
-- Modal & harga dicatat sebagai snapshot saat transaksi. Harga istimewa / diskon / kode referal
-- TIDAK berlaku untuk bot order.
-- =====================================================================

-- ---- Migrasi dari penamaan lama "bulk" (aman bila belum pernah ada) ----
do $$
begin
    if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'price_settings' and column_name = 'bulk_bem') then
        alter table price_settings rename column bulk_bem to bot_bem;
        alter table price_settings rename column bulk_sem to bot_sem;
        alter table price_settings rename column bulk_lem to bot_lem;
    end if;
    if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'bsl_settings' and column_name = 'modal_bulk_bem') then
        alter table bsl_settings rename column modal_bulk_bem to modal_bot_bem;
        alter table bsl_settings rename column modal_bulk_sem to modal_bot_sem;
        alter table bsl_settings rename column modal_bulk_lem to modal_bot_lem;
    end if;
end $$;
alter table bsl_entries drop constraint if exists bsl_entries_jenis_check;
update bsl_entries set jenis = 'bot', kategori = regexp_replace(kategori, ' Bulk$', ' Bot') where jenis = 'bulk';
drop function if exists pr_save_bulk(text, integer, integer, integer);
drop function if exists bp_save_modal_bulk(text, integer, integer, integer);
drop function if exists bp_add_bulk(text, text, integer, text, text, date, integer);

alter table price_settings add column if not exists bot_bem integer not null default 0 check (bot_bem >= 0);
alter table price_settings add column if not exists bot_sem integer not null default 0 check (bot_sem >= 0);
alter table price_settings add column if not exists bot_lem integer not null default 0 check (bot_lem >= 0);

alter table bsl_entries add column if not exists bot_order_id bigint;   -- penanda bot order yang sudah dicatat (mencegah dobel)
create unique index if not exists bsl_entries_bot_uidx on bsl_entries (bot_order_id) where bot_order_id is not null;

alter table bsl_settings add column if not exists modal_bot_bem integer not null default 0 check (modal_bot_bem >= 0);
alter table bsl_settings add column if not exists modal_bot_sem integer not null default 0 check (modal_bot_sem >= 0);
alter table bsl_settings add column if not exists modal_bot_lem integer not null default 0 check (modal_bot_lem >= 0);

-- izinkan jenis 'bot'
alter table bsl_entries drop constraint if exists bsl_entries_jenis_check;
alter table bsl_entries add constraint bsl_entries_jenis_check check (jenis in ('langganan', 'request', 'manual', 'bot'));

-- simpan harga jual bot
create or replace function pr_save_bot(p_pin text, p_bem integer, p_sem integer, p_lem integer)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    if least(coalesce(p_bem, -1), coalesce(p_sem, -1), coalesce(p_lem, -1)) < 0 then raise exception 'Harga tidak boleh kosong atau negatif'; end if;
    if greatest(p_bem, p_sem, p_lem) > 100000000 then raise exception 'Harga terlalu besar'; end if;
    update price_settings set bot_bem = p_bem, bot_sem = p_sem, bot_lem = p_lem, updated_at = now() where id = 1;
end; $$;

-- simpan modal bot
create or replace function bp_save_modal_bot(p_pin text, p_bem integer, p_sem integer, p_lem integer)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    if least(coalesce(p_bem, -1), coalesce(p_sem, -1), coalesce(p_lem, -1)) < 0 then raise exception 'Modal tidak boleh kosong atau negatif'; end if;
    if greatest(p_bem, p_sem, p_lem) > 100000000 then raise exception 'Modal terlalu besar'; end if;
    update bsl_settings set modal_bot_bem = p_bem, modal_bot_sem = p_sem, modal_bot_lem = p_lem, updated_at = now() where id = 1;
end; $$;

-- bp_get: tambahkan harga bot (settings sudah memuat modal bot karena to_jsonb(row))
create or replace function bp_get(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    return jsonb_build_object(
        'settings', (select to_jsonb(s) from bsl_settings s where s.id = 1),
        'harga', (select jsonb_build_object('bem', p.bem, 'sem', p.sem, 'lem', p.lem,
                                            'bot_bem', p.bot_bem, 'bot_sem', p.bot_sem, 'bot_lem', p.bot_lem)
                    from price_settings p where p.id = 1),
        'entries', coalesce((select jsonb_agg(to_jsonb(e) order by e.tanggal desc, e.id desc)
                               from (select * from bsl_entries order by tanggal desc, id desc limit 5000) e), '[]'::jsonb)
    );
end; $$;

-- Tambah manual bot order: pilih paket (BEM/SEM/LEM), isi jumlah tagar -> omset & modal otomatis.
-- p_harga_tagar kosong/0 = pakai harga bot dari halaman Price.
create or replace function bp_add_bot(p_pin text, p_paket text, p_jumlah integer, p_pelanggan text default null,
                                       p_keterangan text default null, p_tanggal date default null, p_harga_tagar integer default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare s bsl_settings%rowtype; pr price_settings%rowtype; v_paket text := upper(coalesce(p_paket, ''));
        v_harga integer; v_m integer; v_id bigint; v_omset bigint; v_modal bigint;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    if v_paket not in ('BEM', 'SEM', 'LEM') then raise exception 'Paket tidak valid'; end if;
    if p_jumlah is null or p_jumlah < 1 or p_jumlah > 1000000 then raise exception 'Jumlah tagar tidak valid'; end if;
    if coalesce(p_harga_tagar, 0) < 0 or coalesce(p_harga_tagar, 0) > 100000000 then raise exception 'Harga tidak valid'; end if;
    select * into s from bsl_settings where id = 1;
    select * into pr from price_settings where id = 1;
    v_harga := case when coalesce(p_harga_tagar, 0) > 0 then p_harga_tagar
                    else case v_paket when 'BEM' then pr.bot_bem when 'SEM' then pr.bot_sem else pr.bot_lem end end;
    v_m := case v_paket when 'BEM' then s.modal_bot_bem when 'SEM' then s.modal_bot_sem else s.modal_bot_lem end;
    v_omset := v_harga::bigint * p_jumlah;
    v_modal := v_m::bigint * p_jumlah;

    insert into bsl_entries (tanggal, jenis, kategori, pelanggan, keterangan, hari, jumlah_tagar, harga_hari, modal_hari, omset, modal)
    values (coalesce(p_tanggal, (now() at time zone 'Asia/Jakarta')::date), 'bot', v_paket || ' Bot',
            left(trim(coalesce(p_pelanggan, '')), 120), left(trim(coalesce(p_keterangan, '')), 200),
            null, p_jumlah, v_harga, v_m, v_omset, v_modal)
    returning id into v_id;
    return jsonb_build_object('id', v_id, 'harga_tagar', v_harga, 'omset', v_omset, 'modal', v_modal, 'profit', v_omset - v_modal);
end; $$;


-- =====================================================================
-- PEMESANAN BOT ORDER OLEH PELANGGAN
-- Beberapa tagar dalam 1 pesanan = 1 baris (1 tabel) di antrian admin; daftar tagar lengkap
-- hanya diambil saat admin membukanya (bot_tags) supaya UI tetap ringkas.
-- =====================================================================
create table if not exists bot_orders (
    id bigint generated always as identity primary key,
    customer_id bigint not null references customer_accounts(id) on delete cascade,
    username text not null,
    dashboard text not null check (dashboard in ('BEM', 'SEM', 'LEM')),
    tagar_list text[] not null,
    jumlah integer not null check (jumlah >= 1),
    catatan_pelanggan text,
    harga_tagar integer not null default 0,
    total_harga bigint not null default 0,
    status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
    catatan_admin text,
    created_at timestamptz not null default now(),
    processed_at timestamptz
);
create index if not exists bot_orders_status_idx on bot_orders (status, created_at desc);
create index if not exists bot_orders_customer_idx on bot_orders (customer_id, created_at desc);
alter table bot_orders enable row level security;      -- tanpa policy publik: hanya lewat fungsi di bawah

-- Pelanggan: kirim pesanan bot order
create or replace function cu_request_bot_order(p_session_token uuid, p_dashboard text, p_tagar_list text[], p_catatan text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
    acc customer_accounts%rowtype; s price_settings%rowtype;
    v_dash text := upper(trim(coalesce(p_dashboard, '')));
    v_list text[] := '{}'; v_norm text[] := '{}'; x text; n text;
    v_note text := nullif(left(trim(coalesce(p_catatan, '')), 500), '');
    v_harga integer; v_id bigint; v_total bigint;
begin
    acc := portal_session_acc(p_session_token);
    if v_dash not in ('BEM', 'SEM', 'LEM') then raise exception 'Paket tidak valid'; end if;
    foreach x in array coalesce(p_tagar_list, '{}') loop
        x := trim(x);
        continue when x = '';
        if length(x) > 100 then raise exception 'Tagar maksimal 100 karakter'; end if;
        n := lower(replace(x, '#', ''));
        if not (n = any(v_norm)) then v_list := v_list || x; v_norm := v_norm || n; end if;   -- tagar kembar diabaikan
    end loop;
    if cardinality(v_list) = 0 then raise exception 'Tagar wajib diisi'; end if;
    if cardinality(v_list) > 500 then raise exception 'Maksimal 500 tagar per pesanan'; end if;

    select * into s from price_settings where id = 1;
    v_harga := case v_dash when 'BEM' then s.bot_bem when 'SEM' then s.bot_sem else s.bot_lem end;
    if coalesce(v_harga, 0) <= 0 then raise exception 'Harga Bot Order belum diatur admin'; end if;
    v_total := v_harga::bigint * cardinality(v_list);

    insert into bot_orders (customer_id, username, dashboard, tagar_list, jumlah, catatan_pelanggan, harga_tagar, total_harga)
    values (acc.id, acc.username, v_dash, v_list, cardinality(v_list), v_note, v_harga, v_total)
    returning id into v_id;
    return jsonb_build_object('id', v_id, 'status', 'pending', 'jumlah', cardinality(v_list), 'harga_tagar', v_harga, 'total', v_total);
end; $$;

-- Pelanggan: riwayat bot order sendiri
create or replace function cu_my_bot_orders(p_session_token uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare acc customer_accounts%rowtype; v jsonb;
begin
    acc := portal_session_acc(p_session_token);
    select coalesce(jsonb_agg(jsonb_build_object(
        'id', b.id, 'dashboard', b.dashboard, 'jumlah', b.jumlah, 'tagar_pertama', b.tagar_list[1],
        'harga_tagar', b.harga_tagar, 'total_harga', b.total_harga, 'status', b.status,
        'catatan_admin', b.catatan_admin, 'created_at', b.created_at, 'processed_at', b.processed_at
    ) order by b.created_at desc), '[]'::jsonb) into v
    from (select * from bot_orders where customer_id = acc.id order by created_at desc limit 30) b;
    return v;
end; $$;

-- Admin: antrian (tanpa daftar tagar lengkap, hanya jumlah + tagar pertama)
create or replace function bot_list(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v jsonb;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    select coalesce(jsonb_agg(to_jsonb(r) order by r.created_at desc), '[]'::jsonb) into v
    from (select b.id, b.username, b.dashboard, b.jumlah, b.tagar_list[1] as tagar_pertama, b.catatan_pelanggan,
                 b.harga_tagar, b.total_harga, b.status, b.catatan_admin, b.created_at, b.processed_at,
                 (select ca.whatsapp from customer_accounts ca where ca.id = b.customer_id) as whatsapp
            from bot_orders b order by b.created_at desc limit 300) r;
    return v;
end; $$;

-- Admin: daftar tagar lengkap 1 pesanan (dimuat hanya saat dibuka)
create or replace function bot_tags(p_pin text, p_id bigint)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v text[];
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    select tagar_list into v from bot_orders where id = p_id;
    if not found then raise exception 'Pesanan tidak ditemukan'; end if;
    return to_jsonb(v);
end; $$;

-- Admin: SETUJUI -> otomatis tercatat di BSL Profit (omset = total bayar, modal = modal bot x jumlah tagar)
create or replace function bot_approve(p_pin text, p_id bigint)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare b bot_orders%rowtype; s bsl_settings%rowtype; v_m integer; v_modal bigint;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    select * into b from bot_orders where id = p_id for update;
    if not found then raise exception 'Pesanan tidak ditemukan'; end if;
    if b.status <> 'pending' then raise exception 'Pesanan ini sudah diproses'; end if;

    select * into s from bsl_settings where id = 1;
    v_m := case b.dashboard when 'BEM' then s.modal_bot_bem when 'SEM' then s.modal_bot_sem else s.modal_bot_lem end;
    v_modal := v_m::bigint * b.jumlah;

    insert into bsl_entries (tanggal, jenis, kategori, pelanggan, keterangan, hari, jumlah_tagar, harga_hari, modal_hari, omset, modal, bot_order_id)
    values ((now() at time zone 'Asia/Jakarta')::date, 'bot', b.dashboard || ' Bot', b.username, 'Bot Order #' || b.id,
            null, b.jumlah, b.harga_tagar, v_m, b.total_harga, v_modal, b.id)
    on conflict (bot_order_id) where bot_order_id is not null do nothing;

    update bot_orders set status = 'approved', processed_at = now() where id = b.id;
    return jsonb_build_object('id', b.id, 'omset', b.total_harga, 'modal', v_modal, 'profit', b.total_harga - v_modal);
end; $$;

create or replace function bot_reject(p_pin text, p_id bigint, p_catatan text default null)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    update bot_orders set status = 'rejected', processed_at = now(), catatan_admin = nullif(left(trim(coalesce(p_catatan, '')), 300), '')
     where id = p_id and status = 'pending';
    if not found then raise exception 'Pesanan tidak ditemukan atau sudah diproses'; end if;
end; $$;

-- Hapus dari antrian. Catatan BSL Profit yang sudah tercatat TIDAK ikut terhapus (hapus manual di BSL Profit bila perlu).
create or replace function bot_delete(p_pin text, p_id bigint)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    delete from bot_orders where id = p_id;
end; $$;

grant execute on function
    pr_save_bot(text, integer, integer, integer), bp_save_modal_bot(text, integer, integer, integer),
    bp_get(text), bp_add_bot(text, text, integer, text, text, date, integer),
    cu_request_bot_order(uuid, text, text[], text), cu_my_bot_orders(uuid),
    bot_list(text), bot_tags(text, bigint), bot_approve(text, bigint), bot_reject(text, bigint, text), bot_delete(text, bigint)
to anon, authenticated;
