-- =====================================================================
-- KOIN — BAGIAN 9: FOTO + DESKRIPSI AKUN pada FARM SELL (etalase pelanggan)
-- Jalankan SETELAH koin-usdt-7-farm-panel.sql (dan farmsell.sql). Aman diulang.
--
-- Admin  : tiap batch Farm Sell bisa diberi 1 foto + deskripsi akun (menu Farm Sell).
-- Pelanggan: foto & deskripsi tampil di kartu Farm (Supply & Stock → Katalog → Farm).
--           Sebelum membeli muncul konfirmasi harga; token yang dibeli otomatis masuk
--           ke Riwayat Pembelian Farm (tabel farm_sales yang sudah ada — tidak diganti).
-- Foto disimpan di tabel farm_images (base64, sudah dikompres di browser) dan ikut
-- terhapus otomatis bila batch dihapus (on delete cascade).
-- =====================================================================

alter table farm_batches add column if not exists deskripsi text not null default '';

create table if not exists farm_images (
    batch_id bigint primary key references farm_batches(id) on delete cascade,
    mime text not null check (mime in ('image/jpeg', 'image/png', 'image/webp')),
    data text not null,
    updated_at timestamptz not null default now()
);
alter table farm_images enable row level security;      -- tanpa policy publik

-- ---------------- ADMIN ----------------
create or replace function fs_set_deskripsi(p_pin text, p_id bigint, p_deskripsi text)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    update farm_batches set deskripsi = left(trim(coalesce(p_deskripsi, '')), 600) where id = p_id;
    if not found then raise exception 'Batch tidak ditemukan'; end if;
end; $$;

create or replace function fs_set_image(p_pin text, p_batch_id bigint, p_mime text, p_data text)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    if not exists (select 1 from farm_batches where id = p_batch_id) then raise exception 'Batch tidak ditemukan'; end if;
    if p_mime not in ('image/jpeg', 'image/png', 'image/webp') then raise exception 'Format gambar harus JPG, PNG, atau WebP'; end if;
    if p_data is null or length(p_data) < 100 then raise exception 'Data gambar kosong'; end if;
    if length(p_data) > 900000 then raise exception 'Ukuran gambar terlalu besar'; end if;
    insert into farm_images (batch_id, mime, data, updated_at) values (p_batch_id, p_mime, p_data, now())
    on conflict (batch_id) do update set mime = excluded.mime, data = excluded.data, updated_at = now();
end; $$;

create or replace function fs_delete_image(p_pin text, p_batch_id bigint)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    delete from farm_images where batch_id = p_batch_id;
end; $$;

create or replace function fs_get_image(p_pin text, p_batch_id bigint)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v jsonb;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    select jsonb_build_object('mime', mime, 'data', data) into v from farm_images where batch_id = p_batch_id;
    return v;
end; $$;

-- fs_list_batches: sama seperti sebelumnya + 'deskripsi' + 'img_v' (versi foto, null = belum ada foto)
create or replace function fs_list_batches(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v jsonb;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    select coalesce(jsonb_agg(jsonb_build_object(
        'id', b.id, 'nama', b.nama, 'created_at', b.created_at, 'etalase', b.etalase, 'harga_koin', b.harga_koin,
        'deskripsi', b.deskripsi,
        'img_v', (select (extract(epoch from i.updated_at) * 1000)::bigint from farm_images i where i.batch_id = b.id),
        'available', (select count(*) from farm_tokens t where t.batch_id = b.id and t.status = 'available'),
        'taken', (select count(*) from farm_tokens t where t.batch_id = b.id and t.status = 'taken')
    ) order by b.id), '[]'::jsonb) into v from farm_batches b;
    return v;
end; $$;

-- ---------------- PELANGGAN ----------------
-- Etalase farm: sama seperti sebelumnya + 'deskripsi' + 'img_v'
create or replace function cu_farm_shop(p_session_token uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
    perform portal_session_acc(p_session_token);
    return coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'nama', b.nama, 'harga_koin', b.harga_koin, 'deskripsi', b.deskripsi,
                'img_v', (select (extract(epoch from i.updated_at) * 1000)::bigint from farm_images i where i.batch_id = b.id),
                'available', (select count(*) from farm_tokens t where t.batch_id = b.id and t.status = 'available')) order by b.id)
              from farm_batches b where b.etalase and b.harga_koin > 0), '[]'::jsonb);
end; $$;

-- Foto farm (hanya batch yang sedang dipajang di etalase)
create or replace function cu_farm_image(p_session_token uuid, p_batch_id bigint)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v jsonb;
begin
    perform portal_session_acc(p_session_token);
    select jsonb_build_object('mime', i.mime, 'data', i.data) into v
      from farm_images i join farm_batches b on b.id = i.batch_id
     where i.batch_id = p_batch_id and b.etalase;
    return v;
end; $$;

grant execute on function
    fs_set_deskripsi(text, bigint, text), fs_set_image(text, bigint, text, text), fs_delete_image(text, bigint),
    fs_get_image(text, bigint), fs_list_batches(text), cu_farm_shop(uuid), cu_farm_image(uuid, bigint)
to anon, authenticated;
