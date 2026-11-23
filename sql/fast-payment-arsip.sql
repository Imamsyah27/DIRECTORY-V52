-- =====================================================================
-- FAST ORDER + PEMBAYARAN (QRIS/Binance/DANA/PayPal) + DAFTAR HARGA BOT + NOTIF ARSIP
--
-- Jalankan SEKALI di Supabase SQL Editor, SETELAH price.sql, pesan-baru-multi-tagar.sql,
-- bot-order.sql (dan admin-view.sql bila dipakai). Aman dijalankan ulang.
--
-- 1. FAST ORDER  : permintaan (pesan baru / perpanjang) dengan hari = 1 saat di-ACC masuk ke
--                  dashboard "FAST-BEM / FAST-SEM / FAST-LEM" (bukan BEM/SEM/LEM biasa).
-- 2. PEMBAYARAN  : pengaturan metode bayar (QRIS foto, Binance ID, DANA, PayPal F&F) dari admin.
-- 3. DAFTAR HARGA: cu_price_info ikut mengirim harga bot per tagar (terpisah dari harian).
-- 4. NOTIF ARSIP : penanda arsip yang belum dilihat pelanggan (badge + banner).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. FAST ORDER — rn_approve: hari = 1 -> dashboard FAST-xxx
-- ---------------------------------------------------------------------
create or replace function rn_approve(p_pin text, p_id bigint)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
    r renewal_requests%rowtype;
    o orders%rowtype;
    v_wa_digits text;
    v_ket text;
    v_new_id bigint;
    v_first_id bigint;
    v_archived boolean := false;
    v_tags text[];
    v_tag text;
    v_count int := 0;
    v_note text;
    v_dash text;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;

    select * into r from renewal_requests where id = p_id for update;
    if not found then raise exception 'Permintaan tidak ditemukan'; end if;
    if r.status <> 'pending' then raise exception 'Permintaan ini sudah diproses'; end if;

    -- pesanan 1 hari = Fast Order
    v_dash := case when r.hari = 1 then 'FAST-' || r.dashboard_baru else r.dashboard_baru end;

    v_wa_digits := regexp_replace(coalesce(r.nomor_whatsapp, ''), '[^0-9]', '', 'g');
    v_tags := case when r.source = 'new' and r.tagar_list is not null and cardinality(r.tagar_list) > 0
                   then r.tagar_list else array[r.tagar_baru] end;
    v_note := nullif(regexp_replace(trim(coalesce(r.catatan_pelanggan, '')), '\s+', ' ', 'g'), '');

    foreach v_tag in array v_tags loop
        v_ket := v_dash || ' H0/H' || r.hari || ' | ' || v_tag || ' | ' ||
                 case when v_wa_digits <> '' then 'https://wa.me/' || v_wa_digits else '' end ||
                 case when v_note is not null then ' | Catatan: ' || v_note else '' end;
        insert into orders (dashboard, nomor_pesanan, tagar, nomor_whatsapp, paket_total, paket_terkirim, last_check_utc, keterangan)
        values (v_dash, r.nomor_pesanan, v_tag, coalesce(r.nomor_whatsapp, ''), r.hari, 0, '', v_ket)
        returning id into v_new_id;
        if v_count = 0 then v_first_id := v_new_id; end if;
        v_count := v_count + 1;
    end loop;
    v_new_id := v_first_id;

    -- langganan lama (sudah limit) di Dashboard Aktif -> pindah ke Arsip
    if r.source = 'order' and r.source_id is not null then
        select * into o from orders where id = r.source_id;
        if found and o.paket_terkirim >= o.paket_total then
            insert into archives (order_id, dashboard, nomor_pesanan, tagar, nomor_whatsapp, paket_total, paket_terkirim, keterangan, created_at)
            values (o.id, o.dashboard, o.nomor_pesanan, o.tagar, coalesce(o.nomor_whatsapp, ''), o.paket_total, o.paket_terkirim, coalesce(o.keterangan, ''), o.created_at);

            insert into customer_order_labels (order_id, inisial, updated_at)
            select v_new_id, l.inisial, now() from customer_order_labels l where l.order_id = o.id
            on conflict (order_id) do nothing;
            delete from customer_order_labels where order_id = o.id;

            delete from orders where id = o.id;
            v_archived := true;
        end if;
    end if;

    update renewal_requests set status = 'approved', processed_at = now(), result_order_id = v_new_id where id = r.id;

    return jsonb_build_object('order_id', v_new_id, 'dashboard', v_dash, 'archived_old', v_archived, 'jumlah', v_count, 'fast', r.hari = 1);
end; $$;

-- ---------------------------------------------------------------------
-- 3. DAFTAR HARGA: cu_price_info + harga bot per tagar
-- ---------------------------------------------------------------------
create or replace function cu_price_info(p_session_token uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare acc customer_accounts%rowtype; v jsonb := '{}'::jsonb; p text; q jsonb; s price_settings%rowtype;
begin
    acc := portal_session_acc(p_session_token);
    foreach p in array array['BEM', 'SEM', 'LEM'] loop
        q := price_calc(acc.id, p, 1, 1, null);
        v := v || jsonb_build_object(p, jsonb_build_object('normal', q->'normal_hari', 'final', q->'harga_hari', 'jenis', q->'jenis',
                                                            'label', q->'diskon_label', 'persen', q->'diskon_persen'));
    end loop;
    select * into s from price_settings where id = 1;
    return v || jsonb_build_object(
        'istimewa', exists (select 1 from price_special where customer_id = acc.id),
        'bot', jsonb_build_object('BEM', s.bot_bem, 'SEM', s.bot_sem, 'LEM', s.bot_lem));
end; $$;

-- ---------------------------------------------------------------------
-- 2. PEMBAYARAN
-- ---------------------------------------------------------------------
create table if not exists payment_settings (
    id integer primary key default 1 check (id = 1),
    binance_id text not null default '',
    dana_number text not null default '',
    dana_name text not null default '',
    paypal text not null default '',
    qris_mime text,
    qris_data text,
    qris_v integer not null default 0,
    updated_at timestamptz not null default now()
);
insert into payment_settings (id) values (1) on conflict (id) do nothing;
alter table payment_settings enable row level security;
-- Tanpa policy publik: hanya bisa diakses lewat function di bawah.

create or replace function pr_pay_get(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    return (select to_jsonb(s) from payment_settings s where s.id = 1);
end; $$;

-- p_qris_data null = foto tidak diubah ; p_hapus_qris = true menghapus foto
create or replace function pr_pay_save(p_pin text, p_binance text, p_dana text, p_dana_name text, p_paypal text,
                                       p_qris_mime text default null, p_qris_data text default null, p_hapus_qris boolean default false)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    if p_qris_data is not null then
        if coalesce(p_qris_mime, '') not in ('image/jpeg', 'image/png', 'image/webp') then raise exception 'Format foto QRIS harus JPG / PNG / WEBP'; end if;
        if length(p_qris_data) > 2000000 then raise exception 'Foto QRIS terlalu besar'; end if;
    end if;
    update payment_settings set
        binance_id = left(trim(coalesce(p_binance, '')), 120),
        dana_number = left(trim(coalesce(p_dana, '')), 40),
        dana_name = left(trim(coalesce(p_dana_name, '')), 120),
        paypal = left(trim(coalesce(p_paypal, '')), 160),
        qris_mime = case when p_hapus_qris then null when p_qris_data is not null then p_qris_mime else qris_mime end,
        qris_data = case when p_hapus_qris then null when p_qris_data is not null then p_qris_data else qris_data end,
        qris_v = case when p_hapus_qris or p_qris_data is not null then qris_v + 1 else qris_v end,
        updated_at = now()
     where id = 1;
end; $$;

-- Pelanggan: metode bayar yang diisi admin
create or replace function cu_payment_info(p_session_token uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare acc customer_accounts%rowtype; s payment_settings%rowtype;
begin
    acc := portal_session_acc(p_session_token);
    select * into s from payment_settings where id = 1;
    return jsonb_build_object(
        'configured', (s.qris_data is not null or s.binance_id <> '' or s.dana_number <> '' or s.paypal <> ''),
        'binance_id', s.binance_id, 'dana_number', s.dana_number, 'dana_name', s.dana_name, 'paypal', s.paypal,
        'qris_mime', s.qris_mime, 'qris_data', s.qris_data, 'qris_v', s.qris_v);
end; $$;

-- ---------------------------------------------------------------------
-- 4. NOTIFIKASI ARSIP BARU (per akun pelanggan, tersimpan di server)
-- ---------------------------------------------------------------------
create table if not exists customer_archive_seen (
    customer_id bigint primary key references customer_accounts(id) on delete cascade,
    last_seen_at timestamptz not null default now()
);
alter table customer_archive_seen enable row level security;
-- Arsip yang SUDAH ada saat file ini dijalankan dianggap sudah dilihat (tidak memunculkan notif lama).
insert into customer_archive_seen (customer_id, last_seen_at) select id, now() from customer_accounts on conflict do nothing;

create or replace function cu_archive_unseen(p_session_token uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare acc customer_accounts%rowtype; v_seen timestamptz; v_count integer; v_latest timestamptz; v_items jsonb;
begin
    acc := portal_session_acc(p_session_token);
    select last_seen_at into v_seen from customer_archive_seen where customer_id = acc.id;
    v_seen := coalesce(v_seen, acc.created_at, '-infinity'::timestamptz);

    select count(*), max(a.archived_at) into v_count, v_latest
      from archives a where normalize_pelanggan_name(a.nomor_pesanan) = acc.match_key and a.archived_at > v_seen;

    select coalesce(jsonb_agg(jsonb_build_object('tagar', x.tagar, 'dashboard', x.dashboard, 'archived_at', x.archived_at)
                              order by x.archived_at desc), '[]'::jsonb) into v_items
      from (select a.tagar, a.dashboard, a.archived_at from archives a
             where normalize_pelanggan_name(a.nomor_pesanan) = acc.match_key and a.archived_at > v_seen
             order by a.archived_at desc limit 30) x;

    return jsonb_build_object('count', v_count, 'latest', v_latest, 'items', v_items);
end; $$;

-- p_upto = archived_at terbaru yang sudah tampil di layar (supaya arsip yang masuk bersamaan tidak ikut hilang)
create or replace function cu_archive_mark_seen(p_session_token uuid, p_upto timestamptz default null)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare acc customer_accounts%rowtype;
begin
    acc := portal_session_acc(p_session_token);
    insert into customer_archive_seen (customer_id, last_seen_at) values (acc.id, coalesce(p_upto, now()))
    on conflict (customer_id) do update set last_seen_at = greatest(customer_archive_seen.last_seen_at, excluded.last_seen_at);
end; $$;

grant execute on function
    rn_approve(text, bigint), cu_price_info(uuid),
    pr_pay_get(text), pr_pay_save(text, text, text, text, text, text, text, boolean), cu_payment_info(uuid),
    cu_archive_unseen(uuid), cu_archive_mark_seen(uuid, timestamptz)
to anon, authenticated;
