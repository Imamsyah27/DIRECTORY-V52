-- =====================================================================
-- KOIN — BAGIAN 17: PESANAN SUPPLY & STOCK -> CATATAN UNTUK ADMIN + KONTAK (WhatsApp / profil Messenger)
-- Jalankan SETELAH koin-usdt-16. Aman diulang.
-- Pelanggan bisa menulis catatan dan mengisi nomor WhatsApp / link profil Messenger yang bisa dihubungi admin.
-- Fungsi lama TIDAK diubah: cu_place_supply_order_k memanggilnya lalu mencatat catatan + kontak (1 transaksi).
-- =====================================================================

alter table supply_orders add column if not exists catatan text;
alter table supply_orders add column if not exists kontak text;

create or replace function cu_place_supply_order_k(p_session_token uuid, p_batch_id bigint, p_qty integer, p_catatan text default null, p_kontak text default null)
returns bigint language plpgsql security definer set search_path = public, extensions as $$
declare v_id bigint; acc customer_accounts%rowtype;
begin
    acc := portal_session_acc(p_session_token);
    v_id := cu_place_supply_order(p_session_token, p_batch_id, p_qty);
    update supply_orders
       set catatan = nullif(left(trim(coalesce(p_catatan, '')), 500), ''),
           kontak = nullif(left(trim(coalesce(p_kontak, '')), 200), '')
     where id = v_id and customer_id = acc.id;
    return v_id;
end; $$;

create or replace function sp_list_orders(p_pin text, p_status text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v jsonb;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    select coalesce(jsonb_agg(jsonb_build_object(
        'id', o.id, 'username', o.username, 'qty', o.qty, 'status', o.status, 'harga_total', o.harga_total,
        'created_at', o.created_at, 'sent_at', o.sent_at,
        'batch', b.nama, 'item', b.item, 'satuan', b.satuan,
        'catatan', o.catatan, 'kontak', o.kontak
    ) order by o.created_at desc), '[]'::jsonb) into v
    from supply_orders o join supply_batches b on b.id = o.batch_id
    where p_status = 'all' or o.status = p_status;
    return v;
end; $$;

grant execute on function cu_place_supply_order_k(uuid, bigint, integer, text, text), sp_list_orders(text, text) to anon, authenticated;
