-- =====================================================================
-- KOIN + USDT — BAGIAN 5/8: SUPPLY & STOCK memakai KOIN + HARGA BERTINGKAT
-- Jalankan SETELAH bagian 1-4 (butuh coin_apply) dan supply.sql + supply-gambar.sql. Aman diulang.
--
-- Harga per item diisi admin untuk 100 / 500 / 1000 pcs. Total pesanan = harga tier terbesar
-- yang <= jumlah pesanan, dihitung proporsional (dibulatkan ke atas):
--   100 pcs = 1.000  ->  200 pcs = 2.000      |      500 pcs = 4.500  ->  600 pcs = 5.400
-- Jumlah di bawah tier terkecil yang diisi memakai harga satuan tier terkecil.
-- Koin dipotong saat memesan; dikembalikan bila pesanan (masih menunggu) dibatalkan / dihapus.
-- =====================================================================

alter table supply_batches add column if not exists price_100 integer not null default 0 check (price_100 >= 0);
alter table supply_batches add column if not exists price_500 integer not null default 0 check (price_500 >= 0);
alter table supply_batches add column if not exists price_1000 integer not null default 0 check (price_1000 >= 0);
alter table supply_orders add column if not exists harga_total bigint not null default 0;
alter table supply_orders add column if not exists koin_dipotong bigint not null default 0;

-- Fungsi internal: total harga untuk qty (0 = harga belum diatur)
create or replace function supply_price(p_batch_id bigint, p_qty integer)
returns bigint language plpgsql security definer set search_path = public, extensions as $$
declare b supply_batches%rowtype; tq integer; tp integer;
begin
    select * into b from supply_batches where id = p_batch_id;
    if not found then return 0; end if;
    if p_qty >= 1000 and b.price_1000 > 0 then tq := 1000; tp := b.price_1000;
    elsif p_qty >= 500 and b.price_500 > 0 then tq := 500; tp := b.price_500;
    elsif p_qty >= 100 and b.price_100 > 0 then tq := 100; tp := b.price_100;
    elsif b.price_100 > 0 then tq := 100; tp := b.price_100;
    elsif b.price_500 > 0 then tq := 500; tp := b.price_500;
    elsif b.price_1000 > 0 then tq := 1000; tp := b.price_1000;
    else return 0; end if;
    return ceil(p_qty::numeric * tp / tq)::bigint;
end; $$;
revoke all on function supply_price(bigint, integer) from public, anon, authenticated;

create or replace function sp_set_batch_price(p_pin text, p_id bigint, p_100 integer, p_500 integer, p_1000 integer)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    if least(coalesce(p_100, -1), coalesce(p_500, -1), coalesce(p_1000, -1)) < 0 or greatest(p_100, p_500, p_1000) > 1000000000 then raise exception 'Harga tidak valid'; end if;
    update supply_batches set price_100 = p_100, price_500 = p_500, price_1000 = p_1000 where id = p_id;
end; $$;

create or replace function sp_list_batches(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v jsonb;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    select coalesce(jsonb_agg(jsonb_build_object(
        'id', b.id, 'nama', b.nama, 'item', b.item, 'satuan', b.satuan, 'visible', b.visible, 'created_at', b.created_at,
        'p100', b.price_100, 'p500', b.price_500, 'p1000', b.price_1000,
        'img_v', (select (extract(epoch from i.updated_at) * 1000)::bigint from supply_images i where i.batch_id = b.id),
        'total', (select coalesce(sum(a.stok), 0) from supply_accounts a where a.batch_id = b.id),
        'accounts', (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'nama', a.nama, 'stok', a.stok, 'updated_at', a.updated_at) order by a.urut, a.id), '[]'::jsonb)
                     from supply_accounts a where a.batch_id = b.id)
    ) order by b.id), '[]'::jsonb) into v from supply_batches b;
    return v;
end; $$;

create or replace function cu_supply(p_session_token uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v jsonb;
begin
    perform portal_session_acc(p_session_token);
    select coalesce(jsonb_agg(jsonb_build_object(
        'id', b.id, 'nama', b.nama, 'item', b.item, 'satuan', b.satuan,
        'p100', b.price_100, 'p500', b.price_500, 'p1000', b.price_1000,
        'img_v', (select (extract(epoch from i.updated_at) * 1000)::bigint from supply_images i where i.batch_id = b.id),
        'total', (select coalesce(sum(a.stok), 0) from supply_accounts a where a.batch_id = b.id),
        'updated_at', (select max(a.updated_at) from supply_accounts a where a.batch_id = b.id)
    ) order by b.id), '[]'::jsonb) into v from supply_batches b where b.visible;
    return v;
end; $$;

-- Pesan supply: hitung harga, potong koin (saldo kurang = ditolak)
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
    v_harga := supply_price(p_batch_id, p_qty);
    if v_harga <= 0 then raise exception 'Harga item belum diatur admin'; end if;
    insert into supply_orders (batch_id, customer_id, username, qty, harga_total, koin_dipotong)
    values (p_batch_id, acc.id, acc.username, p_qty, v_harga, v_harga) returning id into v_id;
    perform coin_apply(acc.id, -v_harga, 'order', 'Supply ' || p_qty || ' pcs · order #' || v_id, 'supply', v_id);
    return v_id;
end; $$;

-- Dibatalkan pelanggan / dihapus admin saat masih menunggu -> koin kembali
create or replace function supply_order_refund()
returns trigger language plpgsql security definer set search_path = public, extensions as $$
begin
    if old.status = 'pending' and old.koin_dipotong > 0 then
        perform coin_apply(old.customer_id, old.koin_dipotong, 'refund', 'Supply dibatalkan #' || old.id, 'supply', old.id);
    end if;
    return old;
end; $$;
drop trigger if exists supply_order_refund_del on supply_orders;
create trigger supply_order_refund_del after delete on supply_orders for each row execute function supply_order_refund();

create or replace function cu_my_supply_orders(p_session_token uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare acc customer_accounts%rowtype; v jsonb;
begin
    acc := portal_session_acc(p_session_token);
    select coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'qty', o.qty, 'status', o.status, 'created_at', o.created_at, 'sent_at', o.sent_at,
        'harga_total', o.harga_total, 'item', b.item, 'nama', b.nama, 'satuan', b.satuan) order by o.created_at desc), '[]'::jsonb) into v
    from supply_orders o join supply_batches b on b.id = o.batch_id where o.customer_id = acc.id;
    return v;
end; $$;

create or replace function sp_list_orders(p_pin text, p_status text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v jsonb;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    select coalesce(jsonb_agg(jsonb_build_object(
        'id', o.id, 'username', o.username, 'qty', o.qty, 'status', o.status, 'harga_total', o.harga_total,
        'created_at', o.created_at, 'sent_at', o.sent_at,
        'batch', b.nama, 'item', b.item, 'satuan', b.satuan
    ) order by o.created_at desc), '[]'::jsonb) into v
    from supply_orders o join supply_batches b on b.id = o.batch_id
    where p_status = 'all' or o.status = p_status;
    return v;
end; $$;

grant execute on function
    sp_set_batch_price(text, bigint, integer, integer, integer), sp_list_batches(text), cu_supply(uuid),
    cu_place_supply_order(uuid, bigint, integer), cu_my_supply_orders(uuid), sp_list_orders(text, text)
to anon, authenticated;
