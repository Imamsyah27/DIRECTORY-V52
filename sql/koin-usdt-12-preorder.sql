-- =====================================================================
-- KOIN — BAGIAN 12 (1/2): PRE ORDER (tabel + sisi admin) (admin: Supply & Stock → Pre Order · pelanggan: Catalog → Pre Order · admin Order → Pre Order)
-- Jalankan SETELAH koin-usdt-11-harga-item.sql dan 11b; lanjutkan dengan koin-usdt-12b-preorder-pelanggan.sql. Aman diulang.
--
-- Admin mengisi barang pre order: nama, harga KOIN PER BARANG, deskripsi, foto, isi barang tiap 1 request farm (bawaan 100)
-- dan batas barang per pemesanan (bawaan 10.000). Pelanggan mengisi baris "tagar | jumlah" (maks 10 tagar per batch);
-- jumlah = jumlah REQUEST FARM, tiap request = per_farm barang (1k barang = 10 request). Total barang per batch maks 10.000;
-- lebih dari itu = pemesanan berikutnya (batch berikutnya, maks 5 batch sekali kirim). Koin dipotong saat memesan,
-- dikembalikan bila admin menolak / menghapus pesanan yang masih menunggu. Harga per barang ikut Custom Price / Harga Pelanggan.
-- =====================================================================

create table if not exists preorder_items (
    id bigint generated always as identity primary key,
    nama text not null check (length(trim(nama)) between 1 and 80),
    deskripsi text not null default '',
    harga_koin bigint not null default 0 check (harga_koin >= 0),
    per_farm integer not null default 100 check (per_farm between 1 and 100000),
    max_barang integer not null default 10000 check (max_barang between 1 and 1000000),
    max_tagar integer not null default 10 check (max_tagar between 1 and 50),
    aktif boolean not null default true,
    urut integer not null default 0,
    created_at timestamptz not null default now()
);
alter table preorder_items enable row level security;

create table if not exists preorder_images (
    item_id bigint primary key references preorder_items(id) on delete cascade,
    mime text not null check (mime in ('image/jpeg', 'image/png', 'image/webp')),
    data text not null,
    updated_at timestamptz not null default now()
);
alter table preorder_images enable row level security;

create table if not exists preorder_orders (
    id bigint generated always as identity primary key,
    grup uuid not null,
    batch_no integer not null default 1,
    batch_total integer not null default 1,
    customer_id bigint not null references customer_accounts(id) on delete cascade,
    username text not null,
    item_id bigint,
    item_nama text not null,
    harga_satuan bigint not null,
    per_farm integer not null,
    lines jsonb not null default '[]'::jsonb,        -- [{tagar, jumlah (request farm), barang}]
    total_farm integer not null,
    total_barang integer not null,
    total_koin bigint not null,
    catatan text,
    status text not null default 'pending' check (status in ('pending', 'done', 'rejected')),
    catatan_admin text,
    created_at timestamptz not null default now(),
    processed_at timestamptz
);
create index if not exists preorder_orders_cust_idx on preorder_orders (customer_id, created_at desc);
create index if not exists preorder_orders_status_idx on preorder_orders (status, created_at desc);
alter table preorder_orders enable row level security;

-- ---------------- ADMIN: barang pre order ----------------
create or replace function po_list_items(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    return coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'nama', p.nama, 'deskripsi', p.deskripsi, 'harga_koin', p.harga_koin,
                'per_farm', p.per_farm, 'max_barang', p.max_barang, 'max_tagar', p.max_tagar, 'aktif', p.aktif,
                'img_v', (select (extract(epoch from i.updated_at) * 1000)::bigint from preorder_images i where i.item_id = p.id),
                'pending', (select count(*) from preorder_orders o where o.item_id = p.id and o.status = 'pending')) order by p.urut, p.id)
              from preorder_items p), '[]'::jsonb);
end; $$;

create or replace function po_save_item(p_pin text, p_id bigint, p_nama text, p_deskripsi text, p_harga bigint, p_per_farm integer, p_max_barang integer, p_aktif boolean)
returns bigint language plpgsql security definer set search_path = public, extensions as $$
declare v_id bigint := p_id; v_nama text := trim(coalesce(p_nama, '')); v_pf integer := coalesce(p_per_farm, 100); v_mx integer := coalesce(p_max_barang, 10000);
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    if v_nama = '' or length(v_nama) > 80 then raise exception 'Nama barang wajib diisi (maks. 80 karakter)'; end if;
    if coalesce(p_harga, -1) < 0 or p_harga > 1000000000 then raise exception 'Harga koin tidak valid'; end if;
    if v_pf < 1 or v_pf > 100000 then raise exception 'Isi barang per farm tidak valid'; end if;
    if v_mx < v_pf or v_mx > 1000000 then raise exception 'Batas barang per pemesanan tidak valid'; end if;
    if v_id is null then
        insert into preorder_items (nama, deskripsi, harga_koin, per_farm, max_barang, aktif, urut)
        values (v_nama, left(trim(coalesce(p_deskripsi, '')), 500), p_harga, v_pf, v_mx, coalesce(p_aktif, true),
                coalesce((select max(urut) + 1 from preorder_items), 0)) returning id into v_id;
    else
        update preorder_items set nama = v_nama, deskripsi = left(trim(coalesce(p_deskripsi, '')), 500), harga_koin = p_harga,
               per_farm = v_pf, max_barang = v_mx, aktif = coalesce(p_aktif, aktif) where id = v_id;
        if not found then raise exception 'Barang tidak ditemukan'; end if;
    end if;
    return v_id;
end; $$;

create or replace function po_set_aktif(p_pin text, p_id bigint, p_aktif boolean)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    update preorder_items set aktif = coalesce(p_aktif, false) where id = p_id;
end; $$;

create or replace function po_delete_item(p_pin text, p_id bigint)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    if exists (select 1 from preorder_orders where item_id = p_id and status = 'pending') then
        raise exception 'Masih ada pesanan menunggu untuk barang ini. Proses dulu di menu Order → Pre Order'; end if;
    delete from preorder_items where id = p_id;
end; $$;

create or replace function po_set_image(p_pin text, p_item_id bigint, p_mime text, p_data text)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    if not exists (select 1 from preorder_items where id = p_item_id) then raise exception 'Barang tidak ditemukan'; end if;
    if p_mime not in ('image/jpeg', 'image/png', 'image/webp') then raise exception 'Format gambar harus JPG, PNG, atau WebP'; end if;
    if p_data is null or length(p_data) < 100 then raise exception 'Data gambar kosong'; end if;
    if length(p_data) > 900000 then raise exception 'Ukuran gambar terlalu besar'; end if;
    insert into preorder_images (item_id, mime, data, updated_at) values (p_item_id, p_mime, p_data, now())
    on conflict (item_id) do update set mime = excluded.mime, data = excluded.data, updated_at = now();
end; $$;

create or replace function po_delete_image(p_pin text, p_item_id bigint)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    delete from preorder_images where item_id = p_item_id;
end; $$;

create or replace function po_get_image(p_pin text, p_item_id bigint)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v jsonb;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    select jsonb_build_object('mime', mime, 'data', data) into v from preorder_images where item_id = p_item_id;
    return v;
end; $$;

-- ---------------- ADMIN: pesanan (menu Order → Pre Order) ----------------
create or replace function po_list_orders(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    return coalesce((select jsonb_agg(to_jsonb(r) order by r.created_at desc, r.batch_no)
        from (select o.id, o.grup, o.batch_no, o.batch_total, o.username, o.item_nama, o.harga_satuan, o.per_farm, o.lines, o.total_farm, o.total_barang,
                     o.total_koin, o.catatan, o.status, o.catatan_admin, o.created_at, o.processed_at, ca.whatsapp
                from preorder_orders o join customer_accounts ca on ca.id = o.customer_id
               order by o.created_at desc, o.batch_no limit 300) r), '[]'::jsonb);
end; $$;

create or replace function po_done(p_pin text, p_id bigint)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    update preorder_orders set status = 'done', processed_at = now() where id = p_id and status = 'pending';
    if not found then raise exception 'Pesanan tidak ditemukan atau sudah diproses'; end if;
end; $$;

create or replace function po_reject(p_pin text, p_id bigint, p_catatan text default null)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare o preorder_orders%rowtype;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    select * into o from preorder_orders where id = p_id and status = 'pending' for update;
    if not found then raise exception 'Pesanan tidak ditemukan atau sudah diproses'; end if;
    update preorder_orders set status = 'rejected', processed_at = now(), catatan_admin = nullif(left(trim(coalesce(p_catatan, '')), 300), '') where id = p_id;
    perform coin_apply(o.customer_id, o.total_koin, 'refund', 'Pre Order ditolak #' || o.id, 'preorder', o.id);
end; $$;

create or replace function po_delete(p_pin text, p_id bigint)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare o preorder_orders%rowtype;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    select * into o from preorder_orders where id = p_id for update;
    if not found then return; end if;
    if o.status = 'pending' then perform coin_apply(o.customer_id, o.total_koin, 'refund', 'Pre Order dihapus #' || o.id, 'preorder', o.id); end if;
    delete from preorder_orders where id = p_id;
end; $$;

grant execute on function
    po_list_items(text), po_save_item(text, bigint, text, text, bigint, integer, integer, boolean), po_set_aktif(text, bigint, boolean), po_delete_item(text, bigint),
    po_set_image(text, bigint, text, text), po_delete_image(text, bigint), po_get_image(text, bigint),
    po_list_orders(text), po_done(text, bigint), po_reject(text, bigint, text), po_delete(text, bigint)
to anon, authenticated;
