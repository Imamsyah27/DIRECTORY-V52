-- =====================================================================
-- KOIN — BAGIAN 21: AUTO-REFRESH (web admin & web pelanggan)
-- Jalankan SETELAH koin-usdt-20. Aman diulang.
-- Setiap perubahan data (dari web admin, web pelanggan, atau SQL Editor) menaikkan "versi" per kelompok di tabel sync_state.
-- Web admin & pelanggan memeriksa versi tiap ±12 detik dan memuat ulang data HANYA bila versinya berubah
-- (ditunda sementara bila pengguna sedang membuka kotak dialog / mengetik).
-- Kelompok: orders, requests, coin, catalog, price, announce, finance.
-- =====================================================================
create table if not exists sync_state (
    scope text primary key,
    v bigint not null default 0,
    ts timestamptz not null default now()
);
alter table sync_state enable row level security;       -- tanpa policy: hanya lewat fungsi di bawah

create or replace function sync_bump()
returns trigger language plpgsql security definer set search_path = public as $$
begin
    insert into sync_state (scope, v, ts) values (TG_ARGV[0], 1, now())
    on conflict (scope) do update set v = sync_state.v + 1, ts = now();
    return null;
end; $$;
revoke all on function sync_bump() from public, anon, authenticated;

do $$
declare spec text; sc text; tb text;
begin
    foreach spec in array array[
        'orders:orders', 'orders:archives', 'orders:customer_order_labels',
        'requests:renewal_requests', 'requests:bot_orders', 'requests:order_requests', 'requests:catalog_orders', 'requests:preorder_orders',
        'requests:supply_orders', 'requests:farm_sales', 'requests:hav_sales', 'requests:coin_topups',
        'coin:coin_ledger',
        'catalog:farm_batches', 'catalog:farm_tokens', 'catalog:hav_batches', 'catalog:hav_keys', 'catalog:supply_batches', 'catalog:supply_accounts',
        'catalog:catalog_items', 'catalog:catalog_categories', 'catalog:preorder_items',
        'price:price_settings', 'price:price_custom', 'price:price_item', 'price:price_special', 'price:payment_settings', 'price:panel_settings',
        'price:referral_codes', 'price:app_admin_settings',
        'announce:announcements',
        'finance:bsl_entries', 'finance:cashflow_batches', 'finance:cashflow_entries', 'finance:modal_items'
    ] loop
        sc := split_part(spec, ':', 1); tb := split_part(spec, ':', 2);
        if to_regclass('public.' || tb) is not null then
            execute format('drop trigger if exists zz_sync_bump on public.%I', tb);
            execute format('create trigger zz_sync_bump after insert or update or delete on public.%I for each statement execute function sync_bump(%L)', tb, sc);
        end if;
    end loop;
end $$;

create or replace function sync_get()
returns jsonb language sql stable security definer set search_path = public as $$
    select coalesce(jsonb_object_agg(scope, v), '{}'::jsonb) from sync_state;
$$;
grant execute on function sync_get() to anon, authenticated;
