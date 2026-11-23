-- =====================================================================
-- MIGRASI 005 — HEMAT EGRESS (auto-refresh lebih tepat sasaran, badge 1 request, index)
-- Jalankan SEKALI di Supabase SQL Editor, SETELAH sql/koin-usdt-21-autorefresh.sql dan migrasi 001–004. Aman diulang.
--
-- 1. Versi auto-refresh dicatat PER TABEL (dulu per kelompok besar, mis. "requests" = 9 tabel sekaligus).
--    Web hanya memuat ulang bagian yang tabelnya benar-benar berubah.
-- 2. Versi PER PELANGGAN untuk tabel milik pelanggan: pesanan pelanggan A tidak lagi membuat
--    semua pelanggan lain memuat ulang daftar pesanan mereka.
-- 3. admin_badges: semua angka lencana menu admin dalam 1 request kecil
--    (dulu 6 request yang masing-masing mengirim sampai 300–500 baris).
-- 4. Index untuk query yang sering dipakai.
-- Web versi baru tetap jalan bila file ini belum dijalankan (memakai cara lama).
-- =====================================================================

-- 1. Versi per tabel ---------------------------------------------------------
create or replace function sync_bump_table()
returns trigger language plpgsql security definer set search_path = public as $$
begin
    insert into sync_state (scope, v, ts) values (TG_TABLE_NAME, 1, now())
    on conflict (scope) do update set v = sync_state.v + 1, ts = now();
    return null;
end; $$;
revoke all on function sync_bump_table() from public, anon, authenticated;

do $$
declare tb text;
begin
    foreach tb in array array[
        'orders', 'archives', 'customer_order_labels',
        'renewal_requests', 'bot_orders', 'order_requests', 'catalog_orders', 'preorder_orders',
        'supply_orders', 'farm_sales', 'hav_sales', 'coin_topups', 'bot_queue', 'bot_batch_settings',
        'coin_ledger',
        'farm_batches', 'farm_tokens', 'hav_batches', 'hav_keys', 'supply_batches', 'supply_accounts',
        'catalog_items', 'catalog_categories', 'preorder_items',
        'price_settings', 'price_custom', 'price_item', 'price_special', 'payment_settings', 'panel_settings',
        'referral_codes', 'app_admin_settings',
        'announcements',
        'bsl_entries', 'cashflow_batches', 'cashflow_entries', 'modal_items'
    ] loop
        if to_regclass('public.' || tb) is not null then
            execute format('drop trigger if exists zz_sync_bump on public.%I', tb);
            execute format('create trigger zz_sync_bump after insert or update or delete on public.%I for each statement execute function sync_bump_table()', tb);
        end if;
    end loop;
end $$;
-- catatan: baris versi kelompok lama (requests, coin, catalog, price, announce, finance) tetap ada tapi tidak naik lagi

-- 2. Versi per pelanggan -----------------------------------------------------
create table if not exists sync_customer (
    customer_id bigint not null,
    scope text not null,
    v bigint not null default 0,
    primary key (customer_id, scope)
);
alter table sync_customer enable row level security;       -- tanpa policy: hanya lewat fungsi

create or replace function sync_bump_customer()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_new bigint; v_old bigint;
begin
    if TG_OP in ('INSERT', 'UPDATE') then v_new := NEW.customer_id; end if;
    if TG_OP in ('UPDATE', 'DELETE') then v_old := OLD.customer_id; end if;
    if v_new is not null then
        insert into sync_customer (customer_id, scope, v) values (v_new, TG_TABLE_NAME, 1)
        on conflict (customer_id, scope) do update set v = sync_customer.v + 1;
    end if;
    if v_old is not null and v_old is distinct from v_new then
        insert into sync_customer (customer_id, scope, v) values (v_old, TG_TABLE_NAME, 1)
        on conflict (customer_id, scope) do update set v = sync_customer.v + 1;
    end if;
    return null;
end; $$;
revoke all on function sync_bump_customer() from public, anon, authenticated;

do $$
declare tb text;
begin
    foreach tb in array array[
        'renewal_requests', 'bot_orders', 'order_requests', 'catalog_orders', 'preorder_orders',
        'supply_orders', 'farm_sales', 'hav_sales', 'coin_topups', 'coin_ledger', 'bot_queue'
    ] loop
        if to_regclass('public.' || tb) is not null then
            execute format('drop trigger if exists zz_sync_customer on public.%I', tb);
            execute format('create trigger zz_sync_customer after insert or update or delete on public.%I for each row execute function sync_bump_customer()', tb);
        end if;
    end loop;
end $$;

-- Pelanggan: versi global (katalog, harga, pengumuman, langganan, ...) + versi milik sendiri ("my:<tabel>")
create or replace function cu_sync_get(p_session_token uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare acc customer_accounts%rowtype;
begin
    acc := portal_session_acc(p_session_token);
    return coalesce((select jsonb_object_agg(scope, v) from sync_state), '{}'::jsonb)
        || coalesce((select jsonb_object_agg('my:' || scope, v) from sync_customer where customer_id = acc.id), '{}'::jsonb);
end; $$;
grant execute on function cu_sync_get(uuid) to anon, authenticated;

-- 3. Lencana admin dalam 1 request ---------------------------------------------
create or replace function admin_badges(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v jsonb := '{}'::jsonb;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    -- Bot / Bulk: masih terbuka = menunggu ACC, atau disetujui tapi belum dikirim (sama dengan boBadge)
    select v || jsonb_build_object(
            'bot',  count(*) filter (where dashboard <> 'BULK'),
            'bulk', count(*) filter (where dashboard = 'BULK'))
      into v from bot_orders
     where not arsip and (status = 'pending' or (status = 'approved' and dikirim_at is null));
    if to_regclass('public.coin_topups') is not null then
        v := v || jsonb_build_object('topup', (select count(*) from coin_topups where status = 'pending'));
    end if;
    if to_regclass('public.catalog_orders') is not null then
        v := v || jsonb_build_object(
            'koin',    (select count(*) from catalog_orders where status = 'pending' and kategori = 'koin'),
            'voucher', (select count(*) from catalog_orders where status = 'pending' and kategori <> 'koin'));
    end if;
    if to_regclass('public.supply_orders') is not null then
        v := v || jsonb_build_object('supply', (select count(*) from supply_orders where status = 'pending'));
    end if;
    if to_regclass('public.preorder_orders') is not null then
        v := v || jsonb_build_object('pre', (select count(*) from preorder_orders where status = 'pending'));
    end if;
    return v;
end; $$;
grant execute on function admin_badges(text) to anon, authenticated;

-- 4. Index ------------------------------------------------------------------
create index if not exists orders_dashboard_idx on orders (dashboard, id);
create index if not exists orders_check_idx on orders (last_check_utc);
do $$
begin
    if to_regclass('public.archives') is not null then
        execute 'create index if not exists archives_archived_idx on archives (archived_at desc)';
        execute 'create index if not exists archives_dash_archived_idx on archives (dashboard, archived_at desc)';
        execute 'create index if not exists archives_dash_created_idx on archives (dashboard, created_at)';
    end if;
end $$;
create index if not exists tagar_batches_id_desc_idx on tagar_batches (id desc);
create index if not exists products_kat_dash_idx on products (kategori, dashboard, id);
create index if not exists bot_orders_open_idx on bot_orders (status, dikirim_at) where not arsip;
