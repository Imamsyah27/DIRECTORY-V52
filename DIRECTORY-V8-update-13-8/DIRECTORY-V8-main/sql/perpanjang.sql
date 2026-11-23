-- =====================================================================
-- PERPANJANG LANGGANAN — pelanggan request, admin konfirmasi
--
-- Jalankan SELURUH file ini SEKALI di Supabase SQL Editor.
-- Syarat: customer_portal_fixed.sql dan supply.sql sudah pernah dijalankan
-- (memakai admin_verify_pin, portal_session_acc, tabel archives).
-- AMAN dijalankan ulang. Tidak ada data lama yang dihapus/diubah.
--
-- Alur:
--   1. Pelanggan (langganan yang sudah LIMIT) klik "Perpanjang" -> pilih
--      jumlah hari, paket BEM/SEM/LEM, dan (opsional) tagar baru -> Kirim.
--   2. Permintaan tersimpan dengan status 'pending' (Menunggu Konfirmasi).
--   3. Muncul di dashboard admin pada tab paket yang dipesan (BEM/SEM/LEM).
--   4. Admin SETUJUI -> dibuat langganan BARU di Dashboard Aktif paket itu
--      (H0/H<hari>), langganan lama yang sudah limit dipindah ke Arsip.
--      Admin TOLAK -> status 'rejected' (+ catatan opsional).
-- =====================================================================

create table if not exists renewal_requests (
    id bigint generated always as identity primary key,
    customer_id bigint not null references customer_accounts(id) on delete cascade,
    username text not null,

    source text not null default 'order' check (source in ('order', 'archive')),
    source_id bigint,                          -- orders.id atau archives.id yang diperpanjang

    nomor_pesanan text not null,               -- nama pemesan (dipakai untuk order baru)
    nomor_whatsapp text,
    dashboard_lama text,
    tagar_lama text not null,

    dashboard_baru text not null check (dashboard_baru in ('BEM', 'SEM', 'LEM')),
    tagar_baru text not null,
    tagar_diganti boolean not null default false,
    hari integer not null check (hari between 1 and 365),

    status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
    catatan_admin text,
    result_order_id bigint,

    created_at timestamptz not null default now(),
    processed_at timestamptz
);

-- satu langganan hanya boleh punya SATU permintaan yang masih menunggu
create unique index if not exists renewal_one_pending_idx
    on renewal_requests (source, source_id) where status = 'pending';
create index if not exists renewal_status_idx
    on renewal_requests (status, dashboard_baru, created_at desc);

alter table renewal_requests enable row level security;
-- Tanpa policy publik: hanya bisa diakses lewat function di bawah.

-- ---------------------------------------------------------------------
-- PELANGGAN
-- ---------------------------------------------------------------------

-- Kirim permintaan perpanjangan
create or replace function cu_request_renewal(
    p_session_token uuid,
    p_source text,            -- 'order' (Dashboard Aktif) / 'archive' (Arsip Saya)
    p_source_id bigint,
    p_dashboard text,         -- BEM / SEM / LEM
    p_hari integer,
    p_tagar_baru text default null   -- null / kosong = tetap pakai tagar lama
)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
    acc customer_accounts%rowtype;
    v_dash text := upper(trim(coalesce(p_dashboard, '')));
    v_nama text; v_wa text; v_dash_lama text; v_tagar_lama text;
    v_total int; v_kirim int;
    v_tagar_baru text := nullif(trim(coalesce(p_tagar_baru, '')), '');
    v_diganti boolean := false;
    v_id bigint;
begin
    acc := portal_session_acc(p_session_token);

    if v_dash not in ('BEM', 'SEM', 'LEM') then
        raise exception 'Paket tidak valid';
    end if;
    if p_hari is null or p_hari < 1 or p_hari > 365 then
        raise exception 'Jumlah hari harus antara 1 dan 365';
    end if;
    if p_source not in ('order', 'archive') then
        raise exception 'Sumber langganan tidak valid';
    end if;

    if p_source = 'order' then
        select o.nomor_pesanan, o.nomor_whatsapp, o.dashboard, o.tagar, o.paket_total, o.paket_terkirim
          into v_nama, v_wa, v_dash_lama, v_tagar_lama, v_total, v_kirim
          from orders o
         where o.id = p_source_id and normalize_pelanggan_name(o.nomor_pesanan) = acc.match_key;
    else
        select a.nomor_pesanan, a.nomor_whatsapp, a.dashboard, a.tagar, a.paket_total, a.paket_terkirim
          into v_nama, v_wa, v_dash_lama, v_tagar_lama, v_total, v_kirim
          from archives a
         where a.id = p_source_id and normalize_pelanggan_name(a.nomor_pesanan) = acc.match_key;
    end if;

    if v_tagar_lama is null then
        raise exception 'Langganan tidak ditemukan';
    end if;
    if coalesce(v_kirim, 0) < coalesce(v_total, 0) then
        raise exception 'Perpanjangan hanya bisa diajukan untuk langganan yang sudah limit';
    end if;

    if v_tagar_baru is not null then
        if length(v_tagar_baru) > 100 then
            raise exception 'Tagar maksimal 100 karakter';
        end if;
        v_diganti := lower(replace(v_tagar_baru, '#', '')) <> lower(replace(v_tagar_lama, '#', ''));
    end if;

    if exists (select 1 from renewal_requests r
                where r.source = p_source and r.source_id = p_source_id and r.status = 'pending') then
        raise exception 'Permintaan perpanjangan untuk langganan ini masih menunggu konfirmasi';
    end if;

    insert into renewal_requests (
        customer_id, username, source, source_id, nomor_pesanan, nomor_whatsapp,
        dashboard_lama, tagar_lama, dashboard_baru, tagar_baru, tagar_diganti, hari
    ) values (
        acc.id, acc.username, p_source, p_source_id, v_nama,
        coalesce(nullif(trim(coalesce(v_wa, '')), ''), acc.whatsapp),
        v_dash_lama, v_tagar_lama, v_dash,
        case when v_diganti then v_tagar_baru else v_tagar_lama end,
        v_diganti, p_hari
    ) returning id into v_id;

    return jsonb_build_object('id', v_id, 'status', 'pending');
end; $$;

-- Daftar permintaan milik pelanggan yang login
create or replace function cu_my_renewals(p_session_token uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare acc customer_accounts%rowtype; v jsonb;
begin
    acc := portal_session_acc(p_session_token);
    select coalesce(jsonb_agg(jsonb_build_object(
        'id', r.id, 'source', r.source, 'source_id', r.source_id,
        'dashboard_lama', r.dashboard_lama, 'dashboard_baru', r.dashboard_baru,
        'tagar_lama', r.tagar_lama, 'tagar_baru', r.tagar_baru, 'tagar_diganti', r.tagar_diganti,
        'hari', r.hari, 'status', r.status, 'catatan_admin', r.catatan_admin,
        'created_at', r.created_at, 'processed_at', r.processed_at
    ) order by r.created_at desc), '[]'::jsonb) into v
    from (select * from renewal_requests where customer_id = acc.id order by created_at desc limit 50) r;
    return v;
end; $$;

-- Batalkan permintaan yang masih menunggu
create or replace function cu_cancel_renewal(p_session_token uuid, p_id bigint)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare acc customer_accounts%rowtype;
begin
    acc := portal_session_acc(p_session_token);
    delete from renewal_requests where id = p_id and customer_id = acc.id and status = 'pending';
end; $$;

-- ---------------------------------------------------------------------
-- ADMIN (wajib PIN admin)
-- ---------------------------------------------------------------------

-- Semua permintaan terbaru (maks. 300); filter paket/status dilakukan di browser
create or replace function rn_list(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v jsonb;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    select coalesce(jsonb_agg(to_jsonb(r) order by r.created_at desc), '[]'::jsonb) into v
    from (select id, username, source, source_id, nomor_pesanan, nomor_whatsapp,
                 dashboard_lama, tagar_lama, dashboard_baru, tagar_baru, tagar_diganti, hari,
                 status, catatan_admin, result_order_id, created_at, processed_at
            from renewal_requests order by created_at desc limit 300) r;
    return v;
end; $$;

-- SETUJUI: buat langganan baru di Dashboard Aktif paket yang dipesan
create or replace function rn_approve(p_pin text, p_id bigint)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
    r renewal_requests%rowtype;
    o orders%rowtype;
    v_wa_digits text;
    v_ket text;
    v_new_id bigint;
    v_archived boolean := false;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;

    select * into r from renewal_requests where id = p_id for update;
    if not found then raise exception 'Permintaan tidak ditemukan'; end if;
    if r.status <> 'pending' then raise exception 'Permintaan ini sudah diproses'; end if;

    v_wa_digits := regexp_replace(coalesce(r.nomor_whatsapp, ''), '[^0-9]', '', 'g');
    v_ket := r.dashboard_baru || ' H0/H' || r.hari || ' | ' || r.tagar_baru || ' | ' ||
             case when v_wa_digits <> '' then 'https://wa.me/' || v_wa_digits else '' end;

    insert into orders (dashboard, nomor_pesanan, tagar, nomor_whatsapp, paket_total, paket_terkirim, last_check_utc, keterangan)
    values (r.dashboard_baru, r.nomor_pesanan, r.tagar_baru, coalesce(r.nomor_whatsapp, ''), r.hari, 0, '', v_ket)
    returning id into v_new_id;

    -- langganan lama (sudah limit) di Dashboard Aktif -> pindah ke Arsip
    if r.source = 'order' and r.source_id is not null then
        select * into o from orders where id = r.source_id;
        if found and o.paket_terkirim >= o.paket_total then
            insert into archives (order_id, dashboard, nomor_pesanan, tagar, nomor_whatsapp, paket_total, paket_terkirim, keterangan, created_at)
            values (o.id, o.dashboard, o.nomor_pesanan, o.tagar, coalesce(o.nomor_whatsapp, ''), o.paket_total, o.paket_terkirim, coalesce(o.keterangan, ''), o.created_at);

            -- inisial pribadi pelanggan ikut dibawa ke langganan baru
            insert into customer_order_labels (order_id, inisial, updated_at)
            select v_new_id, l.inisial, now() from customer_order_labels l where l.order_id = o.id
            on conflict (order_id) do nothing;
            delete from customer_order_labels where order_id = o.id;

            delete from orders where id = o.id;
            v_archived := true;
        end if;
    end if;

    update renewal_requests
       set status = 'approved', processed_at = now(), result_order_id = v_new_id
     where id = r.id;

    return jsonb_build_object('order_id', v_new_id, 'dashboard', r.dashboard_baru, 'archived_old', v_archived);
end; $$;

-- TOLAK (catatan opsional, tampil ke pelanggan)
create or replace function rn_reject(p_pin text, p_id bigint, p_catatan text default null)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    update renewal_requests
       set status = 'rejected', processed_at = now(), catatan_admin = nullif(trim(coalesce(p_catatan, '')), '')
     where id = p_id and status = 'pending';
    if not found then raise exception 'Permintaan tidak ditemukan atau sudah diproses'; end if;
end; $$;

-- Hapus riwayat permintaan yang sudah diproses (rapikan daftar)
create or replace function rn_delete(p_pin text, p_id bigint)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    delete from renewal_requests where id = p_id and status <> 'pending';
end; $$;

-- Arsip pelanggan: sama seperti sebelumnya + kolom order_id (untuk menandai
-- langganan arsip yang sudah diperpanjang). Hanya menambah 1 kunci JSON.
create or replace function cu_my_archives(p_session_token uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare acc customer_accounts%rowtype; v jsonb;
begin
    acc := portal_session_acc(p_session_token);
    select coalesce(jsonb_agg(jsonb_build_object(
        'id', a.id, 'order_id', a.order_id, 'dashboard', a.dashboard, 'tagar', a.tagar,
        'paket_total', a.paket_total, 'paket_terkirim', a.paket_terkirim,
        'created_at', a.created_at, 'archived_at', a.archived_at
    ) order by a.archived_at desc nulls last), '[]'::jsonb) into v
    from archives a where normalize_pelanggan_name(a.nomor_pesanan) = acc.match_key;
    return v;
end; $$;

grant execute on function
    cu_request_renewal(uuid, text, bigint, text, integer, text),
    cu_my_renewals(uuid),
    cu_cancel_renewal(uuid, bigint),
    rn_list(text),
    rn_approve(text, bigint),
    rn_reject(text, bigint, text),
    rn_delete(text, bigint)
to anon, authenticated;

-- =====================================================================
-- SELESAI.
-- =====================================================================
