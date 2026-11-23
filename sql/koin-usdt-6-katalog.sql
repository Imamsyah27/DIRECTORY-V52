-- =====================================================================
-- KOIN — BAGIAN 6/8: KATALOG (Koin Hayday & Voucher) dipesan dengan KOIN AKUN
-- Jalankan SETELAH bagian 1-5 dan katalog-pesan-baru.sql + katalog-kategori.sql. Aman diulang.
--
-- Item katalog diberi "Harga koin" (1 koin = Rp 1) oleh admin. Pelanggan memesan -> koin dipotong ->
-- pesanan MENUNGGU admin (menu Order). Admin tandai Selesai (dikirim) atau Tolak (koin dikembalikan).
-- Item tanpa harga koin tetap tampil seperti biasa (pesan via WhatsApp).
-- =====================================================================

alter table catalog_items add column if not exists harga_koin bigint not null default 0 check (harga_koin >= 0);

create table if not exists catalog_orders (
    id bigint generated always as identity primary key,
    customer_id bigint not null references customer_accounts(id) on delete cascade,
    username text not null,
    item_id bigint,
    item_nama text not null,
    kategori text not null,
    qty integer not null check (qty >= 1),
    harga_satuan bigint not null,
    total bigint not null,
    catatan text,
    status text not null default 'pending' check (status in ('pending', 'done', 'rejected')),
    catatan_admin text,
    created_at timestamptz not null default now(),
    processed_at timestamptz
);
create index if not exists catalog_orders_status_idx on catalog_orders (status, created_at desc);
create index if not exists catalog_orders_cust_idx on catalog_orders (customer_id, created_at desc);
alter table catalog_orders enable row level security;      -- tanpa policy publik

create or replace function ct_set_harga_koin(p_pin text, p_id bigint, p_harga bigint)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    if coalesce(p_harga, -1) < 0 or p_harga > 1000000000 then raise exception 'Harga koin tidak valid'; end if;
    update catalog_items set harga_koin = p_harga, updated_at = now() where id = p_id;
end; $$;

create or replace function ct_list(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v jsonb;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    select coalesce(jsonb_agg(jsonb_build_object(
        'id', c.id, 'kategori', c.kategori, 'nama', c.nama, 'deskripsi', c.deskripsi, 'harga', c.harga, 'ready', c.ready, 'urut', c.urut,
        'harga_koin', c.harga_koin,
        'img_v', (select (extract(epoch from i.updated_at) * 1000)::bigint from catalog_images i where i.item_id = c.id)
    ) order by c.kategori, c.urut, c.id), '[]'::jsonb) into v from catalog_items c;
    return v;
end; $$;

create or replace function cu_catalog(p_session_token uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v jsonb;
begin
    perform portal_session_acc(p_session_token);
    select coalesce(jsonb_agg(jsonb_build_object(
        'id', c.id, 'kategori', c.kategori, 'nama', c.nama, 'deskripsi', c.deskripsi, 'harga', c.harga, 'ready', c.ready,
        'harga_koin', c.harga_koin,
        'img_v', (select (extract(epoch from i.updated_at) * 1000)::bigint from catalog_images i where i.item_id = c.id)
    ) order by c.kategori, c.ready desc, c.urut, c.id), '[]'::jsonb) into v from catalog_items c;
    return v;
end; $$;

-- Pelanggan: pesan item katalog dengan koin
create or replace function cu_order_catalog(p_session_token uuid, p_item_id bigint, p_qty integer, p_catatan text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare acc customer_accounts%rowtype; it catalog_items%rowtype; v_total bigint; v_id bigint;
begin
    acc := portal_session_acc(p_session_token);
    if p_qty is null or p_qty < 1 or p_qty > 1000 then raise exception 'Jumlah pesanan tidak valid'; end if;
    select * into it from catalog_items where id = p_item_id;
    if not found or it.kategori = 'farm' then raise exception 'Item tidak tersedia'; end if;
    if not it.ready then raise exception 'Item sedang tidak ready'; end if;
    if it.harga_koin <= 0 then raise exception 'Harga koin item belum diatur admin'; end if;
    if (select count(*) from catalog_orders where customer_id = acc.id and status = 'pending') >= 20 then
        raise exception 'Terlalu banyak pesanan yang masih menunggu'; end if;
    v_total := it.harga_koin * p_qty;
    insert into catalog_orders (customer_id, username, item_id, item_nama, kategori, qty, harga_satuan, total, catatan)
    values (acc.id, acc.username, it.id, it.nama, it.kategori, p_qty, it.harga_koin, v_total, nullif(left(trim(coalesce(p_catatan, '')), 300), ''))
    returning id into v_id;
    perform coin_apply(acc.id, -v_total, 'order', left(it.nama, 60) || ' x' || p_qty || ' · order #' || v_id, 'catalog', v_id);
    return jsonb_build_object('id', v_id, 'total', v_total, 'status', 'pending');
end; $$;

create or replace function cu_my_catalog_orders(p_session_token uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare acc customer_accounts%rowtype;
begin
    acc := portal_session_acc(p_session_token);
    return coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'item_nama', o.item_nama, 'kategori', o.kategori, 'qty', o.qty,
                'total', o.total, 'status', o.status, 'catatan_admin', o.catatan_admin, 'created_at', o.created_at) order by o.created_at desc)
              from (select * from catalog_orders where customer_id = acc.id order by created_at desc limit 20) o), '[]'::jsonb);
end; $$;

-- Admin: daftar pesanan. p_kind: 'koin' | 'voucher' (selain koin) | 'all'
create or replace function co_list(p_pin text, p_kind text default 'all')
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    return coalesce((select jsonb_agg(to_jsonb(r) order by r.created_at desc)
        from (select o.id, o.username, o.item_nama, o.kategori, o.qty, o.harga_satuan, o.total, o.catatan, o.status, o.catatan_admin,
                     o.created_at, o.processed_at, ca.whatsapp
                from catalog_orders o join customer_accounts ca on ca.id = o.customer_id
               where p_kind = 'all' or (p_kind = 'koin' and o.kategori = 'koin') or (p_kind = 'voucher' and o.kategori <> 'koin')
               order by o.created_at desc limit 300) r), '[]'::jsonb);
end; $$;

create or replace function co_done(p_pin text, p_id bigint)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    update catalog_orders set status = 'done', processed_at = now() where id = p_id and status = 'pending';
    if not found then raise exception 'Pesanan tidak ditemukan atau sudah diproses'; end if;
end; $$;

create or replace function co_reject(p_pin text, p_id bigint, p_catatan text default null)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare o catalog_orders%rowtype;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    select * into o from catalog_orders where id = p_id and status = 'pending' for update;
    if not found then raise exception 'Pesanan tidak ditemukan atau sudah diproses'; end if;
    update catalog_orders set status = 'rejected', processed_at = now(), catatan_admin = nullif(left(trim(coalesce(p_catatan, '')), 300), '') where id = p_id;
    perform coin_apply(o.customer_id, o.total, 'refund', 'Pesanan ditolak #' || o.id, 'catalog', o.id);
end; $$;

create or replace function co_delete(p_pin text, p_id bigint)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare o catalog_orders%rowtype;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    select * into o from catalog_orders where id = p_id for update;
    if not found then return; end if;
    if o.status = 'pending' then perform coin_apply(o.customer_id, o.total, 'refund', 'Pesanan dihapus #' || o.id, 'catalog', o.id); end if;
    delete from catalog_orders where id = p_id;
end; $$;

grant execute on function
    ct_set_harga_koin(text, bigint, bigint), ct_list(text), cu_catalog(uuid), cu_order_catalog(uuid, bigint, integer, text),
    cu_my_catalog_orders(uuid), co_list(text, text), co_done(text, bigint), co_reject(text, bigint, text), co_delete(text, bigint)
to anon, authenticated;
