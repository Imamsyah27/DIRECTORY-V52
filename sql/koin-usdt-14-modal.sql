-- =====================================================================
-- KOIN — BAGIAN 14: MENU "MODAL" (satu tempat untuk SEMUA modal) + profit otomatis di BSL Profit & CashFlow
-- Jalankan SETELAH koin-usdt-13. Urutan: 13, 14, 14b, 14c, 15 (dipecah karena SQL Editor memotong skrip ~20.000 karakter).
-- JANGAN menjalankan ulang bot-order.sql / bsl-profit.sql SESUDAH file ini (akan menimpa fungsi modal dengan versi lama).
--
--  1. Tabel modal_items: modal per satuan jual untuk Farm, Hav Token, Product (tiap tier), Katalog, Pre Order
--     + modal BSL (BEM/SEM/LEM harian dan Bot). Modal lama di BSL (bsl_settings) DIPINDAHKAN otomatis ke sini.
--  2. BSL Profit & CashFlow membaca modal dari tabel ini. Catat penjualan: pilih barang + jumlah -> omset, modal, profit otomatis.
-- =====================================================================

create table if not exists modal_items (
    item_key text primary key check (item_key ~ '^(farm|hav|cat|pre):[0-9]+$' or item_key ~ '^sup:[0-9]+:(100|500|1000)$' or item_key ~ '^bsl:(bem|sem|lem|bot_bem|bot_sem|bot_lem)$'),
    modal bigint not null default 0 check (modal >= 0 and modal <= 100000000000),
    updated_at timestamptz not null default now()
);
alter table modal_items enable row level security;     -- tanpa policy publik

-- pindahkan modal lama dari BSL (tidak menimpa bila sudah pernah diisi di sini)
do $$
begin
    if exists (select 1 from information_schema.tables where table_schema = 'public' and table_name = 'bsl_settings') then
        insert into modal_items (item_key, modal) select 'bsl:bem', modal_bem from bsl_settings where id = 1 on conflict do nothing;
        insert into modal_items (item_key, modal) select 'bsl:sem', modal_sem from bsl_settings where id = 1 on conflict do nothing;
        insert into modal_items (item_key, modal) select 'bsl:lem', modal_lem from bsl_settings where id = 1 on conflict do nothing;
        if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'bsl_settings' and column_name = 'modal_bot_bem') then
            insert into modal_items (item_key, modal) select 'bsl:bot_bem', modal_bot_bem from bsl_settings where id = 1 on conflict do nothing;
            insert into modal_items (item_key, modal) select 'bsl:bot_sem', modal_bot_sem from bsl_settings where id = 1 on conflict do nothing;
            insert into modal_items (item_key, modal) select 'bsl:bot_lem', modal_bot_lem from bsl_settings where id = 1 on conflict do nothing;
        end if;
    end if;
end $$;

-- kolom tambahan catatan BSL untuk penjualan barang
alter table bsl_entries add column if not exists item_key text;
alter table bsl_entries add column if not exists item_nama text;
alter table bsl_entries add column if not exists qty integer;
alter table bsl_entries add column if not exists harga_satuan bigint;
alter table bsl_entries add column if not exists modal_satuan bigint;

-- kolom tambahan CashFlow
alter table cashflow_entries add column if not exists modal bigint not null default 0 check (modal >= 0);   -- modal per satuan (snapshot)
alter table cashflow_entries add column if not exists item_key text;

-- ---------------- internal ----------------
create or replace function md_get(p_key text)
returns bigint language sql stable security definer set search_path = public, extensions as $$
    select coalesce((select modal from modal_items where item_key = p_key), 0);
$$;

-- Semua barang di etalase (tanpa filter harga: barang yang belum diberi harga tetap bisa diberi modal)
create or replace function md_all_items()
returns table (key text, grup text, ikon text, ord integer, sub text, nama text, harga bigint, satuan text)
language sql stable security definer set search_path = public, extensions as $$
    select 'bsl:bem'::text, 'BSL · Langganan Harian'::text, '📈'::text, 0, ''::text, 'BEM'::text, coalesce((select bem from price_settings where id = 1), 0)::bigint, '/ tag / hari'::text
    union all select 'bsl:sem', 'BSL · Langganan Harian', '📈', 0, '', 'SEM', coalesce((select sem from price_settings where id = 1), 0)::bigint, '/ tag / hari'
    union all select 'bsl:lem', 'BSL · Langganan Harian', '📈', 0, '', 'LEM', coalesce((select lem from price_settings where id = 1), 0)::bigint, '/ tag / hari'
    union all select 'bsl:bot_bem', 'BSL · Bot Order', '🤖', 0, '', 'BEM Bot', coalesce((select bot_bem from price_settings where id = 1), 0)::bigint, '/ tagar'
    union all select 'bsl:bot_sem', 'BSL · Bot Order', '🤖', 0, '', 'SEM Bot', coalesce((select bot_sem from price_settings where id = 1), 0)::bigint, '/ tagar'
    union all select 'bsl:bot_lem', 'BSL · Bot Order', '🤖', 0, '', 'LEM Bot', coalesce((select bot_lem from price_settings where id = 1), 0)::bigint, '/ tagar'
    union all
    select 'farm:' || b.id, 'Farm', '🌱', 1, '', b.nama::text, b.harga_koin::bigint, '/ token' from farm_batches b where b.etalase
    union all
    select 'hav:' || b.id, 'Hav Token', '🔑', 2, '', b.nama::text, b.harga_koin::bigint, '/ key' from hav_batches b where b.etalase
    union all
    select 'sup:' || b.id || ':100', 'Product (Supply & Stock)', '📦', 3, b.nama::text, (coalesce(nullif(b.item, ''), b.nama) || ' · 100 ' || b.satuan)::text, b.price_100::bigint, 'total' from supply_batches b where b.visible and b.price_100 > 0
    union all
    select 'sup:' || b.id || ':500', 'Product (Supply & Stock)', '📦', 3, b.nama::text, (coalesce(nullif(b.item, ''), b.nama) || ' · 500 ' || b.satuan)::text, b.price_500::bigint, 'total' from supply_batches b where b.visible and b.price_500 > 0
    union all
    select 'sup:' || b.id || ':1000', 'Product (Supply & Stock)', '📦', 3, b.nama::text, (coalesce(nullif(b.item, ''), b.nama) || ' · 1000 ' || b.satuan)::text, b.price_1000::bigint, 'total' from supply_batches b where b.visible and b.price_1000 > 0
    union all
    select 'pre:' || p.id, 'Pre Order', '📝', 4, '', p.nama::text, p.harga_koin::bigint, '/ 10.000 barang' from preorder_items p
    union all
    select 'cat:' || c.id, coalesce(k.nama, c.kategori)::text, coalesce(k.ikon, '🛍')::text, 10 + coalesce(k.urut, 99), c.kategori::text, c.nama::text, c.harga_koin::bigint, '/ item'
      from catalog_items c left join catalog_categories k on k.slug = c.kategori where c.kategori <> 'farm';
$$;
revoke all on function md_get(text), md_all_items() from public, anon, authenticated;

-- ---------------- ADMIN: menu Modal ----------------
create or replace function md_catalog(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    return coalesce((select jsonb_agg(to_jsonb(r) order by r.ord, r.sub, r.nama) from (
        select i.key, i.grup, i.ikon, i.ord, i.sub, i.nama, coalesce(i.harga, 0) as harga, i.satuan, coalesce(m.modal, 0) as modal, (m.item_key is not null) as diisi
          from md_all_items() i left join modal_items m on m.item_key = i.key) r), '[]'::jsonb);
end; $$;

-- p_items = {"farm:3": 120, "pre:1": 150000, "bsl:bem": 3000, ...}; hanya yang dikirim yang diubah
create or replace function md_save(p_pin text, p_items jsonb)
returns integer language plpgsql security definer set search_path = public, extensions as $$
declare r record; n integer := 0;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    for r in select key, value from jsonb_each_text(coalesce(p_items, '{}'::jsonb)) loop
        if not (r.key ~ '^(farm|hav|cat|pre):[0-9]+$' or r.key ~ '^sup:[0-9]+:(100|500|1000)$' or r.key ~ '^bsl:(bem|sem|lem|bot_bem|bot_sem|bot_lem)$') then
            raise exception 'Kode barang tidak valid: %', r.key; end if;
        if not (coalesce(r.value, '') ~ '^[0-9]{1,12}$') then raise exception 'Modal untuk % harus angka bulat >= 0', r.key; end if;
        insert into modal_items (item_key, modal, updated_at) values (r.key, r.value::bigint, now())
        on conflict (item_key) do update set modal = excluded.modal, updated_at = now();
        n := n + 1;
    end loop;
    return n;
end; $$;

grant execute on function md_catalog(text), md_save(text, jsonb) to anon, authenticated;
