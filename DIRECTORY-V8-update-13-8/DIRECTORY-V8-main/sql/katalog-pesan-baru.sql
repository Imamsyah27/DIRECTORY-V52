-- =====================================================================
-- 1) KATALOG (Supply & Stock): kategori Koin / Voucher / Farm, status Ready / Tidak Ready
-- 2) PESAN LANGGANAN BARU (BEM / SEM / LEM) dari pelanggan, dikonfirmasi admin
--
-- Jalankan SELURUH file ini SEKALI di Supabase SQL Editor.
-- Syarat: customer_portal_fixed.sql, supply.sql, perpanjang.sql sudah dijalankan.
-- Jika admin-view.sql sudah dijalankan, file ini tidak mengubahnya. Aman dijalankan ulang.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) KATALOG
-- ---------------------------------------------------------------------
create table if not exists catalog_items (
    id bigint generated always as identity primary key,
    kategori text not null check (kategori in ('koin', 'voucher', 'farm')),
    nama text not null,
    deskripsi text not null default '',
    harga text not null default '',            -- teks bebas, mis. "Rp 10.000 / 100 koin" (boleh kosong)
    ready boolean not null default true,
    urut integer not null default 0,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);
create index if not exists catalog_items_kat_idx on catalog_items (kategori, urut, id);

-- Gambar katalog: ikut terhapus otomatis saat item dihapus (on delete cascade)
create table if not exists catalog_images (
    item_id bigint primary key references catalog_items(id) on delete cascade,
    mime text not null check (mime in ('image/jpeg', 'image/png', 'image/webp')),
    data text not null,
    updated_at timestamptz not null default now()
);
alter table catalog_items enable row level security;
alter table catalog_images enable row level security;   -- tanpa policy publik

-- ADMIN
create or replace function ct_list(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v jsonb;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    select coalesce(jsonb_agg(jsonb_build_object(
        'id', c.id, 'kategori', c.kategori, 'nama', c.nama, 'deskripsi', c.deskripsi, 'harga', c.harga, 'ready', c.ready, 'urut', c.urut,
        'img_v', (select (extract(epoch from i.updated_at) * 1000)::bigint from catalog_images i where i.item_id = c.id)
    ) order by c.kategori, c.urut, c.id), '[]'::jsonb) into v from catalog_items c;
    return v;
end; $$;

create or replace function ct_save(p_pin text, p_id bigint, p_kategori text, p_nama text, p_deskripsi text, p_harga text, p_ready boolean)
returns bigint language plpgsql security definer set search_path = public, extensions as $$
declare v_id bigint; v_nama text := trim(coalesce(p_nama, ''));
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    if v_nama = '' then raise exception 'Nama item wajib diisi'; end if;
    if length(v_nama) > 120 then raise exception 'Nama item maksimal 120 karakter'; end if;
    if p_kategori not in ('koin', 'voucher', 'farm') then raise exception 'Kategori tidak valid'; end if;
    if p_id is null then
        insert into catalog_items (kategori, nama, deskripsi, harga, ready, urut)
        values (p_kategori, v_nama, left(trim(coalesce(p_deskripsi, '')), 500), left(trim(coalesce(p_harga, '')), 80), coalesce(p_ready, true),
                coalesce((select max(urut) + 1 from catalog_items where kategori = p_kategori), 0))
        returning id into v_id;
    else
        update catalog_items
           set kategori = p_kategori, nama = v_nama, deskripsi = left(trim(coalesce(p_deskripsi, '')), 500),
               harga = left(trim(coalesce(p_harga, '')), 80), ready = coalesce(p_ready, ready), updated_at = now()
         where id = p_id returning id into v_id;
        if v_id is null then raise exception 'Item tidak ditemukan'; end if;
    end if;
    return v_id;
end; $$;

create or replace function ct_set_ready(p_pin text, p_id bigint, p_ready boolean)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    update catalog_items set ready = p_ready, updated_at = now() where id = p_id;
end; $$;

create or replace function ct_delete(p_pin text, p_id bigint)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    delete from catalog_items where id = p_id;      -- gambar ikut terhapus (cascade)
end; $$;

create or replace function ct_set_image(p_pin text, p_id bigint, p_mime text, p_data text)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    if not exists (select 1 from catalog_items where id = p_id) then raise exception 'Item tidak ditemukan'; end if;
    if p_mime not in ('image/jpeg', 'image/png', 'image/webp') then raise exception 'Format gambar harus JPG, PNG, atau WebP'; end if;
    if p_data is null or length(p_data) < 100 then raise exception 'Data gambar kosong'; end if;
    if length(p_data) > 900000 then raise exception 'Ukuran gambar terlalu besar'; end if;
    insert into catalog_images (item_id, mime, data, updated_at) values (p_id, p_mime, p_data, now())
    on conflict (item_id) do update set mime = excluded.mime, data = excluded.data, updated_at = now();
end; $$;

create or replace function ct_delete_image(p_pin text, p_id bigint)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    delete from catalog_images where item_id = p_id;
end; $$;

create or replace function ct_get_image(p_pin text, p_id bigint)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v jsonb;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    select jsonb_build_object('mime', mime, 'data', data) into v from catalog_images where item_id = p_id;
    return v;
end; $$;

-- PELANGGAN (session_token; stok tidak ada, hanya Ready / Tidak Ready)
create or replace function cu_catalog(p_session_token uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v jsonb;
begin
    perform portal_session_acc(p_session_token);
    select coalesce(jsonb_agg(jsonb_build_object(
        'id', c.id, 'kategori', c.kategori, 'nama', c.nama, 'deskripsi', c.deskripsi, 'harga', c.harga, 'ready', c.ready,
        'img_v', (select (extract(epoch from i.updated_at) * 1000)::bigint from catalog_images i where i.item_id = c.id)
    ) order by c.kategori, c.ready desc, c.urut, c.id), '[]'::jsonb) into v from catalog_items c;
    return v;
end; $$;

create or replace function cu_catalog_image(p_session_token uuid, p_id bigint)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v jsonb;
begin
    perform portal_session_acc(p_session_token);
    select jsonb_build_object('mime', mime, 'data', data) into v from catalog_images where item_id = p_id;
    return v;
end; $$;

-- ---------------------------------------------------------------------
-- 2) PESAN LANGGANAN BARU (memakai tabel & alur permintaan perpanjangan)
--    Permintaan masuk ke panel yang sama di dashboard admin (tab BEM/SEM/LEM).
--    Admin SETUJUI -> langganan baru masuk Dashboard Aktif (rn_approve yang sudah ada).
-- ---------------------------------------------------------------------
alter table renewal_requests drop constraint if exists renewal_requests_source_check;
alter table renewal_requests add constraint renewal_requests_source_check check (source in ('order', 'archive', 'new'));

create or replace function cu_request_new_order(p_session_token uuid, p_dashboard text, p_hari integer, p_tagar text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
    acc customer_accounts%rowtype;
    v_dash text := upper(trim(coalesce(p_dashboard, '')));
    v_tagar text := trim(coalesce(p_tagar, ''));
    v_id bigint;
begin
    acc := portal_session_acc(p_session_token);
    if v_dash not in ('BEM', 'SEM', 'LEM') then raise exception 'Paket tidak valid'; end if;
    if p_hari is null or p_hari < 1 or p_hari > 365 then raise exception 'Jumlah hari harus antara 1 dan 365'; end if;
    if v_tagar = '' then raise exception 'Tagar wajib diisi'; end if;
    if length(v_tagar) > 100 then raise exception 'Tagar maksimal 100 karakter'; end if;

    if exists (select 1 from renewal_requests r
                where r.customer_id = acc.id and r.source = 'new' and r.status = 'pending'
                  and lower(replace(r.tagar_baru, '#', '')) = lower(replace(v_tagar, '#', ''))) then
        raise exception 'Pesanan dengan tagar ini masih menunggu konfirmasi';
    end if;

    insert into renewal_requests (
        customer_id, username, source, source_id, nomor_pesanan, nomor_whatsapp,
        dashboard_lama, tagar_lama, dashboard_baru, tagar_baru, tagar_diganti, hari
    ) values (
        acc.id, acc.username, 'new', null, acc.username, nullif(trim(coalesce(acc.whatsapp, '')), ''),
        null, '', v_dash, v_tagar, false, p_hari
    ) returning id into v_id;

    return jsonb_build_object('id', v_id, 'status', 'pending');
end; $$;

grant execute on function
    ct_list(text), ct_save(text, bigint, text, text, text, text, boolean), ct_set_ready(text, bigint, boolean), ct_delete(text, bigint),
    ct_set_image(text, bigint, text, text), ct_delete_image(text, bigint), ct_get_image(text, bigint),
    cu_catalog(uuid), cu_catalog_image(uuid, bigint), cu_request_new_order(uuid, text, integer, text)
to anon, authenticated;
