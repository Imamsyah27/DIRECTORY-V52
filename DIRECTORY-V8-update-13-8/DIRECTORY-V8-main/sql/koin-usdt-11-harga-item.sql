-- =====================================================================
-- KOIN — BAGIAN 11 (1/2): CUSTOM PRICE & HARGA PELANGGAN untuk SEMUA item
-- Jalankan SETELAH koin-usdt-1…10 (butuh price_custom/price_special dan koin-usdt-10-hav-catalog.sql). Aman diulang.
--
-- Sebelumnya hanya BEM / SEM / LEM + Bot yang bisa diberi harga khusus per pelanggan. Kini SEMUA item berkoin ikut:
--   Farm (Farm Sell) · Hav Token (HAV Sell) · Product (Supply & Stock, tiap tier 100/500/1000) · Katalog (Koin, Voucher,
--   kategori lain) · Pre Order (koin-usdt-12). Item BARU yang dijual otomatis muncul di daftar kedua menu admin.
--
-- Aturan tampil (sama seperti harga harian): Custom Price menang -> tampil sebagai harga biasa (tanpa coretan);
-- Harga Pelanggan (istimewa) -> harga umum dicoret; selain itu harga umum. Pembayaran memakai harga yang dilihat pelanggan.
-- Jalankan juga bagian 11 (2/2) = koin-usdt-11b-harga-item-pelanggan.sql.
-- Daftar item (pi_catalog) dibaca langsung dari tabel penjualan, jadi tidak perlu daftar harga yang dipelihara manual.
-- =====================================================================

create table if not exists price_item (
    customer_id bigint not null references customer_accounts(id) on delete cascade,
    kind text not null check (kind in ('custom', 'special')),
    item_key text not null check (item_key ~ '^(farm|hav|cat|pre):[0-9]+$' or item_key ~ '^sup:[0-9]+:(100|500|1000)$'),
    harga bigint not null check (harga > 0 and harga <= 1000000000),
    updated_at timestamptz not null default now(),
    primary key (customer_id, kind, item_key)
);
alter table price_item enable row level security;      -- tanpa policy publik: pelanggan tidak bisa membaca harga asli

-- Fungsi internal (hanya dipanggil fungsi lain): harga akhir & harga normal yang dicoret (null bila tidak perlu dicoret)
create or replace function pi_final(p_customer bigint, p_key text, p_default bigint)
returns bigint language sql stable security definer set search_path = public, extensions as $$
    select coalesce((select harga from price_item where customer_id = p_customer and kind = 'custom' and item_key = p_key),
                    (select harga from price_item where customer_id = p_customer and kind = 'special' and item_key = p_key),
                    p_default);
$$;
create or replace function pi_normal(p_customer bigint, p_key text, p_default bigint)
returns bigint language sql stable security definer set search_path = public, extensions as $$
    select case when exists (select 1 from price_item where customer_id = p_customer and kind = 'custom' and item_key = p_key) then null
                when exists (select 1 from price_item where customer_id = p_customer and kind = 'special' and item_key = p_key) and p_default > 0 then p_default
                else null end;
$$;
revoke all on function pi_final(bigint, text, bigint), pi_normal(bigint, text, bigint) from public, anon, authenticated;

-- ---------------- ADMIN ----------------
-- Semua item berharga yang sedang dijual (otomatis ikut bertambah)
create or replace function pi_catalog(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    return coalesce((select jsonb_agg(to_jsonb(r) order by r.ord, r.sub, r.nama) from (
        select ('farm:' || b.id)::text as key, 'Farm'::text as grup, '🌱'::text as ikon, 1 as ord, ''::text as sub, b.nama::text as nama, b.harga_koin as harga, '/ token'::text as satuan
          from farm_batches b where b.etalase and b.harga_koin > 0
        union all
        select 'hav:' || b.id, 'Hav Token', '🔑', 2, '', b.nama, b.harga_koin, '/ key' from hav_batches b where b.etalase and b.harga_koin > 0
        union all
        select 'sup:' || b.id || ':100', 'Product (Supply & Stock)', '📦', 3, b.nama, coalesce(nullif(b.item, ''), b.nama) || ' · 100 ' || b.satuan, b.price_100::bigint, 'total' from supply_batches b where b.visible and b.price_100 > 0
        union all
        select 'sup:' || b.id || ':500', 'Product (Supply & Stock)', '📦', 3, b.nama, coalesce(nullif(b.item, ''), b.nama) || ' · 500 ' || b.satuan, b.price_500::bigint, 'total' from supply_batches b where b.visible and b.price_500 > 0
        union all
        select 'sup:' || b.id || ':1000', 'Product (Supply & Stock)', '📦', 3, b.nama, coalesce(nullif(b.item, ''), b.nama) || ' · 1000 ' || b.satuan, b.price_1000::bigint, 'total' from supply_batches b where b.visible and b.price_1000 > 0
        union all
        select 'cat:' || c.id, coalesce(k.nama, c.kategori), coalesce(k.ikon, '🛍'), 10 + coalesce(k.urut, 99), c.kategori, c.nama, c.harga_koin, '/ item'
          from catalog_items c left join catalog_categories k on k.slug = c.kategori where c.kategori <> 'farm' and c.harga_koin > 0
    ) r), '[]'::jsonb);
end; $$;

create or replace function pi_get(p_pin text, p_kind text, p_customer_id bigint)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    return coalesce((select jsonb_agg(jsonb_build_object('key', item_key, 'harga', harga) order by item_key)
                       from price_item where customer_id = p_customer_id and kind = p_kind), '[]'::jsonb);
end; $$;

-- p_items = {"farm:3": 120, "hav:1": 80, ...}. Menggantikan SEMUA harga item pelanggan ini untuk jenis tsb (kosong / 0 = ikut harga umum)
create or replace function pi_save(p_pin text, p_kind text, p_customer_id bigint, p_items jsonb)
returns integer language plpgsql security definer set search_path = public, extensions as $$
declare r record; n integer := 0;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    if p_kind not in ('custom', 'special') then raise exception 'Jenis harga tidak valid'; end if;
    if not exists (select 1 from customer_accounts where id = p_customer_id) then raise exception 'Akun pelanggan tidak ditemukan'; end if;
    delete from price_item where customer_id = p_customer_id and kind = p_kind;
    for r in select key, value from jsonb_each_text(coalesce(p_items, '{}'::jsonb)) loop
        if r.value ~ '^[0-9]{1,9}$' then
            if r.value::bigint > 0 then
                insert into price_item (customer_id, kind, item_key, harga) values (p_customer_id, p_kind, r.key, r.value::bigint);
                n := n + 1;
            end if;
        end if;
    end loop;
    return n;
end; $$;

create or replace function pi_delete(p_pin text, p_kind text, p_customer_id bigint)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    delete from price_item where customer_id = p_customer_id and kind = p_kind;
end; $$;

create or replace function pi_summary(p_pin text, p_kind text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    return coalesce((select jsonb_agg(jsonb_build_object('customer_id', x.customer_id, 'username', ca.username, 'n', x.n) order by ca.username)
                       from (select customer_id, count(*) as n from price_item where kind = p_kind group by customer_id) x
                       join customer_accounts ca on ca.id = x.customer_id), '[]'::jsonb);
end; $$;

grant execute on function pi_catalog(text), pi_get(text, text, bigint), pi_save(text, text, bigint, jsonb), pi_delete(text, text, bigint), pi_summary(text, text)
to anon, authenticated;
