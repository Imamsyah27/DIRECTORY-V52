-- =====================================================================
-- KOIN — BAGIAN 10: HAV TOKEN dijual ke pelanggan (menu Catalog) dengan KOIN
-- Jalankan SETELAH havsell.sql dan koin-usdt-2-koin.sql. Aman diulang.
--
-- Admin     : menu HAV Sell -> pilih batch -> "Jual di Catalog pelanggan" + harga koin / key.
-- Pelanggan : Catalog -> Hav Token. Saldo koin cukup -> key sebanyak jumlah yang dibeli langsung
--             dikirim otomatis (diambil dari daftar key batch, pindah ke Arsip Key) dan tersimpan
--             di Riwayat Pembelian Hav (tabel hav_sales). Saldo kurang / stok kurang = ditolak.
-- =====================================================================

alter table hav_batches add column if not exists etalase boolean not null default false;
alter table hav_batches add column if not exists harga_koin bigint not null default 0 check (harga_koin >= 0);
alter table hav_batches add column if not exists deskripsi text not null default '';

create table if not exists hav_sales (
    id bigint generated always as identity primary key,
    customer_id bigint not null references customer_accounts(id) on delete cascade,
    username text not null,
    batch_id bigint,
    batch_nama text not null,
    qty integer not null,
    harga_satuan bigint not null,
    total bigint not null,
    keys jsonb not null default '[]'::jsonb,
    created_at timestamptz not null default now()
);
create index if not exists hav_sales_cust_idx on hav_sales (customer_id, created_at desc);
alter table hav_sales enable row level security;      -- tanpa policy publik (key = rahasia)

-- Admin: daftar batch (+ etalase, harga, deskripsi)
create or replace function hs_list_batches(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v jsonb;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'nama', b.nama, 'created_at', b.created_at,
        'etalase', b.etalase, 'harga_koin', b.harga_koin, 'deskripsi', b.deskripsi,
        'available', (select count(*) from hav_keys k where k.batch_id = b.id and k.status = 'available'),
        'taken', (select count(*) from hav_keys k where k.batch_id = b.id and k.status = 'taken')) order by b.id), '[]'::jsonb)
    into v from hav_batches b;
    return v;
end; $$;

-- Admin: atur harga jual ke pelanggan (1 koin = Rp 1) + tampilkan / sembunyikan di Catalog
create or replace function hs_set_etalase(p_pin text, p_id bigint, p_show boolean, p_harga bigint, p_deskripsi text default null)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    if coalesce(p_harga, -1) < 0 or p_harga > 1000000000 then raise exception 'Harga koin tidak valid'; end if;
    if p_show and p_harga <= 0 then raise exception 'Isi harga koin per key dulu'; end if;
    update hav_batches set etalase = coalesce(p_show, false), harga_koin = p_harga,
           deskripsi = left(trim(coalesce(p_deskripsi, '')), 300)
     where id = p_id;
    if not found then raise exception 'Batch tidak ditemukan'; end if;
end; $$;

-- Pelanggan: Hav Token yang dijual
create or replace function cu_hav_shop(p_session_token uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
    perform portal_session_acc(p_session_token);
    return coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'nama', b.nama, 'harga_koin', b.harga_koin, 'deskripsi', b.deskripsi,
                'available', (select count(*) from hav_keys k where k.batch_id = b.id and k.status = 'available')) order by b.id)
              from hav_batches b where b.etalase and b.harga_koin > 0), '[]'::jsonb);
end; $$;

-- Pelanggan: beli Hav Token dengan koin -> key LANGSUNG dikirim (atomik: gagal sebagian = batal semua)
create or replace function cu_buy_hav(p_session_token uuid, p_batch_id bigint, p_qty integer)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare acc customer_accounts%rowtype; b hav_batches%rowtype; v_keys jsonb; v_n integer; v_total bigint; v_id bigint;
begin
    acc := portal_session_acc(p_session_token);
    if p_qty is null or p_qty < 1 or p_qty > 1000 then raise exception 'Jumlah pesanan tidak valid'; end if;
    select * into b from hav_batches where id = p_batch_id;
    if not found or not b.etalase or b.harga_koin <= 0 then raise exception 'Hav Token tidak tersedia'; end if;
    v_total := b.harga_koin * p_qty;

    with pick as (select id from hav_keys where batch_id = b.id and status = 'available' order by id limit p_qty for update skip locked),
         upd as (update hav_keys k set status = 'taken', taken_at = now() from pick where k.id = pick.id returning k.id, k.key_value)
    select coalesce(jsonb_agg(to_jsonb(upd.key_value) order by upd.id), '[]'::jsonb), count(*) into v_keys, v_n from upd;
    if v_n < p_qty then raise exception 'Stok Hav Token tidak cukup'; end if;      -- membatalkan semuanya

    insert into hav_sales (customer_id, username, batch_id, batch_nama, qty, harga_satuan, total, keys)
    values (acc.id, acc.username, b.id, b.nama, p_qty, b.harga_koin, v_total, v_keys) returning id into v_id;
    perform coin_apply(acc.id, -v_total, 'order', 'Hav ' || left(b.nama, 40) || ' x' || p_qty || ' · #' || v_id, 'hav', v_id);   -- saldo kurang = batal semua
    return jsonb_build_object('id', v_id, 'qty', p_qty, 'total', v_total, 'keys', v_keys);
end; $$;

-- Pelanggan: riwayat pembelian Hav
create or replace function cu_my_hav_sales(p_session_token uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare acc customer_accounts%rowtype;
begin
    acc := portal_session_acc(p_session_token);
    return coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'batch_nama', s.batch_nama, 'qty', s.qty, 'total', s.total, 'keys', s.keys,
                'created_at', s.created_at) order by s.created_at desc)
              from (select * from hav_sales where customer_id = acc.id order by created_at desc limit 20) s), '[]'::jsonb);
end; $$;

-- Admin: riwayat penjualan Hav (tanpa isi key)
create or replace function hs_sales_list(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    return coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'username', s.username, 'batch_nama', s.batch_nama, 'qty', s.qty,
                'harga_satuan', s.harga_satuan, 'total', s.total, 'created_at', s.created_at) order by s.created_at desc)
              from (select * from hav_sales order by created_at desc limit 300) s), '[]'::jsonb);
end; $$;

grant execute on function
    hs_list_batches(text), hs_set_etalase(text, bigint, boolean, bigint, text), cu_hav_shop(uuid),
    cu_buy_hav(uuid, bigint, integer), cu_my_hav_sales(uuid), hs_sales_list(text)
to anon, authenticated;
