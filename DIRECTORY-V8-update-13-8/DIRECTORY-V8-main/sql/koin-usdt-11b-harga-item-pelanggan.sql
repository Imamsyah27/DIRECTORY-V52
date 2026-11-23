-- =====================================================================
-- KOIN — BAGIAN 11 (2/2): fungsi PELANGGAN yang memakai harga custom / harga pelanggan per item
-- Jalankan SETELAH koin-usdt-11-harga-item.sql. Aman diulang.
-- Farm, Hav Token, Katalog (Koin/Voucher/dll), Product (Supply & Stock) kini membaca & membayar dengan harga yang
-- berlaku untuk pelanggan itu (Custom Price > Harga Pelanggan > harga umum).
-- =====================================================================

create or replace function cu_farm_shop(p_session_token uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare acc customer_accounts%rowtype;
begin
    acc := portal_session_acc(p_session_token);
    return coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'nama', b.nama, 'deskripsi', b.deskripsi,
                'harga_koin', pi_final(acc.id, 'farm:' || b.id, b.harga_koin), 'harga_normal', pi_normal(acc.id, 'farm:' || b.id, b.harga_koin),
                'img_v', (select (extract(epoch from i.updated_at) * 1000)::bigint from farm_images i where i.batch_id = b.id),
                'available', (select count(*) from farm_tokens t where t.batch_id = b.id and t.status = 'available')) order by b.id)
              from farm_batches b where b.etalase and b.harga_koin > 0), '[]'::jsonb);
end; $$;

create or replace function cu_buy_farm(p_session_token uuid, p_batch_id bigint, p_qty integer)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare acc customer_accounts%rowtype; b farm_batches%rowtype; v_tokens jsonb; v_n integer; v_price bigint; v_total bigint; v_id bigint;
begin
    acc := portal_session_acc(p_session_token);
    if p_qty is null or p_qty < 1 or p_qty > 1000 then raise exception 'Jumlah pesanan tidak valid'; end if;
    select * into b from farm_batches where id = p_batch_id;
    if not found or not b.etalase or b.harga_koin <= 0 then raise exception 'Farm tidak tersedia'; end if;
    v_price := pi_final(acc.id, 'farm:' || b.id, b.harga_koin);
    v_total := v_price * p_qty;

    with pick as (select id from farm_tokens where batch_id = b.id and status = 'available' order by no limit p_qty for update skip locked),
         upd as (update farm_tokens t set status = 'taken', taken_at = now() from pick where t.id = pick.id returning t.no, t.farm_id, t.token)
    select coalesce(jsonb_agg(jsonb_build_object('no', upd.no, 'farm_id', upd.farm_id, 'token', upd.token) order by upd.no), '[]'::jsonb), count(*)
      into v_tokens, v_n from upd;
    if v_n < p_qty then raise exception 'Stok farm tidak cukup'; end if;

    insert into farm_sales (customer_id, username, batch_id, batch_nama, qty, harga_satuan, total, tokens)
    values (acc.id, acc.username, b.id, b.nama, p_qty, v_price, v_total, v_tokens) returning id into v_id;
    perform coin_apply(acc.id, -v_total, 'order', 'Farm ' || left(b.nama, 40) || ' x' || p_qty || ' · #' || v_id, 'farm', v_id);
    return jsonb_build_object('id', v_id, 'qty', p_qty, 'total', v_total, 'tokens', v_tokens);
end; $$;

create or replace function cu_hav_shop(p_session_token uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare acc customer_accounts%rowtype;
begin
    acc := portal_session_acc(p_session_token);
    return coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'nama', b.nama, 'deskripsi', b.deskripsi,
                'harga_koin', pi_final(acc.id, 'hav:' || b.id, b.harga_koin), 'harga_normal', pi_normal(acc.id, 'hav:' || b.id, b.harga_koin),
                'available', (select count(*) from hav_keys k where k.batch_id = b.id and k.status = 'available')) order by b.id)
              from hav_batches b where b.etalase and b.harga_koin > 0), '[]'::jsonb);
end; $$;

create or replace function cu_buy_hav(p_session_token uuid, p_batch_id bigint, p_qty integer)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare acc customer_accounts%rowtype; b hav_batches%rowtype; v_keys jsonb; v_n integer; v_price bigint; v_total bigint; v_id bigint;
begin
    acc := portal_session_acc(p_session_token);
    if p_qty is null or p_qty < 1 or p_qty > 1000 then raise exception 'Jumlah pesanan tidak valid'; end if;
    select * into b from hav_batches where id = p_batch_id;
    if not found or not b.etalase or b.harga_koin <= 0 then raise exception 'Hav Token tidak tersedia'; end if;
    v_price := pi_final(acc.id, 'hav:' || b.id, b.harga_koin);
    v_total := v_price * p_qty;

    with pick as (select id from hav_keys where batch_id = b.id and status = 'available' order by id limit p_qty for update skip locked),
         upd as (update hav_keys k set status = 'taken', taken_at = now() from pick where k.id = pick.id returning k.id, k.key_value)
    select coalesce(jsonb_agg(to_jsonb(upd.key_value) order by upd.id), '[]'::jsonb), count(*) into v_keys, v_n from upd;
    if v_n < p_qty then raise exception 'Stok Hav Token tidak cukup'; end if;

    insert into hav_sales (customer_id, username, batch_id, batch_nama, qty, harga_satuan, total, keys)
    values (acc.id, acc.username, b.id, b.nama, p_qty, v_price, v_total, v_keys) returning id into v_id;
    perform coin_apply(acc.id, -v_total, 'order', 'Hav ' || left(b.nama, 40) || ' x' || p_qty || ' · #' || v_id, 'hav', v_id);
    return jsonb_build_object('id', v_id, 'qty', p_qty, 'total', v_total, 'keys', v_keys);
end; $$;

-- Katalog (Koin, Voucher, kategori lain)
create or replace function cu_catalog(p_session_token uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare acc customer_accounts%rowtype; v jsonb;
begin
    acc := portal_session_acc(p_session_token);
    select coalesce(jsonb_agg(jsonb_build_object(
        'id', c.id, 'kategori', c.kategori, 'nama', c.nama, 'deskripsi', c.deskripsi, 'harga', c.harga, 'ready', c.ready,
        'harga_koin', pi_final(acc.id, 'cat:' || c.id, c.harga_koin), 'harga_normal', pi_normal(acc.id, 'cat:' || c.id, c.harga_koin),
        'img_v', (select (extract(epoch from i.updated_at) * 1000)::bigint from catalog_images i where i.item_id = c.id)
    ) order by c.kategori, c.ready desc, c.urut, c.id), '[]'::jsonb) into v from catalog_items c;
    return v;
end; $$;

create or replace function cu_order_catalog(p_session_token uuid, p_item_id bigint, p_qty integer, p_catatan text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare acc customer_accounts%rowtype; it catalog_items%rowtype; v_price bigint; v_total bigint; v_id bigint;
begin
    acc := portal_session_acc(p_session_token);
    if p_qty is null or p_qty < 1 or p_qty > 1000 then raise exception 'Jumlah pesanan tidak valid'; end if;
    select * into it from catalog_items where id = p_item_id;
    if not found or it.kategori = 'farm' then raise exception 'Item tidak tersedia'; end if;
    if not it.ready then raise exception 'Item sedang tidak ready'; end if;
    if it.harga_koin <= 0 then raise exception 'Harga koin item belum diatur admin'; end if;
    if (select count(*) from catalog_orders where customer_id = acc.id and status = 'pending') >= 20 then
        raise exception 'Terlalu banyak pesanan yang masih menunggu'; end if;
    v_price := pi_final(acc.id, 'cat:' || it.id, it.harga_koin);
    v_total := v_price * p_qty;
    insert into catalog_orders (customer_id, username, item_id, item_nama, kategori, qty, harga_satuan, total, catatan)
    values (acc.id, acc.username, it.id, it.nama, it.kategori, p_qty, v_price, v_total, nullif(left(trim(coalesce(p_catatan, '')), 300), ''))
    returning id into v_id;
    perform coin_apply(acc.id, -v_total, 'order', left(it.nama, 60) || ' x' || p_qty || ' · order #' || v_id, 'catalog', v_id);
    return jsonb_build_object('id', v_id, 'total', v_total, 'status', 'pending');
end; $$;

-- Product (Supply & Stock): tiap tier 100 / 500 / 1000 bisa punya harga custom
create or replace function supply_price_c(p_customer bigint, p_batch_id bigint, p_qty integer)
returns bigint language plpgsql security definer set search_path = public, extensions as $$
declare b supply_batches%rowtype; tq integer; tp bigint; a bigint; c bigint; d bigint;
begin
    select * into b from supply_batches where id = p_batch_id;
    if not found then return 0; end if;
    a := case when b.price_100 > 0 then pi_final(p_customer, 'sup:' || b.id || ':100', b.price_100) else 0 end;
    c := case when b.price_500 > 0 then pi_final(p_customer, 'sup:' || b.id || ':500', b.price_500) else 0 end;
    d := case when b.price_1000 > 0 then pi_final(p_customer, 'sup:' || b.id || ':1000', b.price_1000) else 0 end;
    if p_qty >= 1000 and d > 0 then tq := 1000; tp := d;
    elsif p_qty >= 500 and c > 0 then tq := 500; tp := c;
    elsif p_qty >= 100 and a > 0 then tq := 100; tp := a;
    elsif a > 0 then tq := 100; tp := a;
    elsif c > 0 then tq := 500; tp := c;
    elsif d > 0 then tq := 1000; tp := d;
    else return 0; end if;
    return ceil(p_qty::numeric * tp / tq)::bigint;
end; $$;
revoke all on function supply_price_c(bigint, bigint, integer) from public, anon, authenticated;

create or replace function cu_supply(p_session_token uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare acc customer_accounts%rowtype; v jsonb;
begin
    acc := portal_session_acc(p_session_token);
    select coalesce(jsonb_agg(jsonb_build_object(
        'id', b.id, 'nama', b.nama, 'item', b.item, 'satuan', b.satuan,
        'p100', case when b.price_100 > 0 then pi_final(acc.id, 'sup:' || b.id || ':100', b.price_100) else 0 end,
        'p500', case when b.price_500 > 0 then pi_final(acc.id, 'sup:' || b.id || ':500', b.price_500) else 0 end,
        'p1000', case when b.price_1000 > 0 then pi_final(acc.id, 'sup:' || b.id || ':1000', b.price_1000) else 0 end,
        'n100', pi_normal(acc.id, 'sup:' || b.id || ':100', b.price_100), 'n500', pi_normal(acc.id, 'sup:' || b.id || ':500', b.price_500),
        'n1000', pi_normal(acc.id, 'sup:' || b.id || ':1000', b.price_1000),
        'img_v', (select (extract(epoch from i.updated_at) * 1000)::bigint from supply_images i where i.batch_id = b.id),
        'total', (select coalesce(sum(a.stok), 0) from supply_accounts a where a.batch_id = b.id),
        'updated_at', (select max(a.updated_at) from supply_accounts a where a.batch_id = b.id)
    ) order by b.id), '[]'::jsonb) into v from supply_batches b where b.visible;
    return v;
end; $$;

create or replace function cu_place_supply_order(p_session_token uuid, p_batch_id bigint, p_qty integer)
returns bigint language plpgsql security definer set search_path = public, extensions as $$
declare acc customer_accounts%rowtype; v_total integer; v_id bigint; v_harga bigint;
begin
    acc := portal_session_acc(p_session_token);
    if p_qty is null or p_qty < 1 then raise exception 'Jumlah pesanan minimal 1'; end if;
    if not exists (select 1 from supply_batches where id = p_batch_id and visible) then raise exception 'Item tidak tersedia'; end if;
    select coalesce(sum(stok), 0) into v_total from supply_accounts where batch_id = p_batch_id;
    if p_qty > v_total then raise exception 'Jumlah melebihi stok tersedia'; end if;
    if (select count(*) from supply_orders where customer_id = acc.id and status = 'pending') >= 20 then
        raise exception 'Terlalu banyak pesanan yang masih menunggu'; end if;
    v_harga := supply_price_c(acc.id, p_batch_id, p_qty);
    if v_harga <= 0 then raise exception 'Harga item belum diatur admin'; end if;
    insert into supply_orders (batch_id, customer_id, username, qty, harga_total, koin_dipotong)
    values (p_batch_id, acc.id, acc.username, p_qty, v_harga, v_harga) returning id into v_id;
    perform coin_apply(acc.id, -v_harga, 'order', 'Supply ' || p_qty || ' pcs · order #' || v_id, 'supply', v_id);
    return v_id;
end; $$;

grant execute on function
    cu_farm_shop(uuid), cu_buy_farm(uuid, bigint, integer), cu_hav_shop(uuid), cu_buy_hav(uuid, bigint, integer),
    cu_catalog(uuid), cu_order_catalog(uuid, bigint, integer, text), cu_supply(uuid), cu_place_supply_order(uuid, bigint, integer)
to anon, authenticated;
