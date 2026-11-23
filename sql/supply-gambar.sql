-- =====================================================================
-- GAMBAR PRODUK PER BATCH (Supply & Stock)
-- Jalankan SELURUH file ini SEKALI di Supabase SQL Editor.
-- Syarat: supply.sql sudah pernah dijalankan. Aman dijalankan ulang.
--
-- Gambar disimpan di tabel supply_images (base64, sudah dikompres di browser).
-- Tabel ini terhubung "on delete cascade" ke supply_batches, jadi saat batch
-- dihapus, gambarnya OTOMATIS ikut terhapus dari backend.
-- Tanpa policy publik: admin lewat PIN, pelanggan lewat session_token.
-- =====================================================================

create table if not exists supply_images (
    batch_id bigint primary key references supply_batches(id) on delete cascade,
    mime text not null check (mime in ('image/jpeg', 'image/png', 'image/webp')),
    data text not null,
    updated_at timestamptz not null default now()
);
alter table supply_images enable row level security;

-- ---------------------------------------------------------------------
-- ADMIN
-- ---------------------------------------------------------------------
create or replace function sp_set_batch_image(p_pin text, p_batch_id bigint, p_mime text, p_data text)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    if not exists (select 1 from supply_batches where id = p_batch_id) then raise exception 'Batch tidak ditemukan'; end if;
    if p_mime not in ('image/jpeg', 'image/png', 'image/webp') then raise exception 'Format gambar harus JPG, PNG, atau WebP'; end if;
    if p_data is null or length(p_data) < 100 then raise exception 'Data gambar kosong'; end if;
    if length(p_data) > 900000 then raise exception 'Ukuran gambar terlalu besar'; end if;
    insert into supply_images (batch_id, mime, data, updated_at)
    values (p_batch_id, p_mime, p_data, now())
    on conflict (batch_id) do update set mime = excluded.mime, data = excluded.data, updated_at = now();
end; $$;

create or replace function sp_delete_batch_image(p_pin text, p_batch_id bigint)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    delete from supply_images where batch_id = p_batch_id;
end; $$;

create or replace function sp_get_batch_image(p_pin text, p_batch_id bigint)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v jsonb;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    select jsonb_build_object('mime', mime, 'data', data) into v from supply_images where batch_id = p_batch_id;
    return v;
end; $$;

-- sp_list_batches: sama seperti sebelumnya + 'img_v' (versi gambar, null = belum ada gambar)
create or replace function sp_list_batches(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v jsonb;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    select coalesce(jsonb_agg(jsonb_build_object(
        'id', b.id, 'nama', b.nama, 'item', b.item, 'satuan', b.satuan, 'visible', b.visible, 'created_at', b.created_at,
        'img_v', (select (extract(epoch from i.updated_at) * 1000)::bigint from supply_images i where i.batch_id = b.id),
        'total', (select coalesce(sum(a.stok), 0) from supply_accounts a where a.batch_id = b.id),
        'accounts', (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'nama', a.nama, 'stok', a.stok, 'updated_at', a.updated_at) order by a.urut, a.id), '[]'::jsonb)
                     from supply_accounts a where a.batch_id = b.id)
    ) order by b.id), '[]'::jsonb) into v from supply_batches b;
    return v;
end; $$;

-- Hapus batch: gambar ikut terhapus lewat cascade (delete eksplisit sebagai pengaman)
create or replace function sp_delete_batch(p_pin text, p_id bigint)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    delete from supply_images where batch_id = p_id;
    delete from supply_batches where id = p_id;
end; $$;

-- ---------------------------------------------------------------------
-- PELANGGAN (session_token) — hanya batch yang ditampilkan
-- ---------------------------------------------------------------------
create or replace function cu_supply(p_session_token uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v jsonb;
begin
    perform portal_session_acc(p_session_token);
    select coalesce(jsonb_agg(jsonb_build_object(
        'id', b.id, 'nama', b.nama, 'item', b.item, 'satuan', b.satuan,
        'img_v', (select (extract(epoch from i.updated_at) * 1000)::bigint from supply_images i where i.batch_id = b.id),
        'total', (select coalesce(sum(a.stok), 0) from supply_accounts a where a.batch_id = b.id),
        'updated_at', (select max(a.updated_at) from supply_accounts a where a.batch_id = b.id)
    ) order by b.id), '[]'::jsonb) into v from supply_batches b where b.visible;
    return v;
end; $$;

create or replace function cu_supply_image(p_session_token uuid, p_batch_id bigint)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v jsonb;
begin
    perform portal_session_acc(p_session_token);
    select jsonb_build_object('mime', i.mime, 'data', i.data) into v
    from supply_images i join supply_batches b on b.id = i.batch_id
    where i.batch_id = p_batch_id and b.visible;
    return v;
end; $$;

grant execute on function
    sp_set_batch_image(text, bigint, text, text), sp_delete_batch_image(text, bigint), sp_get_batch_image(text, bigint),
    sp_list_batches(text), sp_delete_batch(text, bigint), cu_supply(uuid), cu_supply_image(uuid, bigint)
to anon, authenticated;
