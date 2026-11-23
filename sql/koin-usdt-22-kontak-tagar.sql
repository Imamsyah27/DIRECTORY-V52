-- =====================================================================
-- KOIN — BAGIAN 22: KONTAK + TAGAR WAJIB (Koin Hayday, Voucher, Supply & Stock) + SUPPLY MASUK MENU ORDER
-- Jalankan SETELAH koin-usdt-17-supply-kontak.sql (dan 20/21). Aman diulang.
--  * Saat memesan Koin Hayday / Voucher / Supply & Stock pelanggan WAJIB mengisi:
--      - kontak: nomor WhatsApp ATAU link profil Messenger/Facebook (divalidasi),
--      - tagar akun yang akan dikirim (kolom terpisah).
--  * Pesanan Supply sekarang punya status Menunggu / Terkirim / Ditolak (koin kembali) + catatan admin,
--    sehingga bisa dikelola di menu Order -> tab Supply seperti pesanan lain.
-- =====================================================================
alter table supply_orders add column if not exists tagar text;
alter table supply_orders add column if not exists catatan_admin text;
alter table supply_orders add column if not exists processed_at timestamptz;
alter table supply_orders drop constraint if exists supply_orders_status_check;
alter table supply_orders add constraint supply_orders_status_check check (status in ('pending', 'sent', 'rejected'));
alter table catalog_orders add column if not exists kontak text;
alter table catalog_orders add column if not exists tagar text;

-- nomor WhatsApp (8–15 digit, boleh +, spasi, tanda hubung) ATAU link profil Messenger / Facebook
create or replace function valid_kontak(p text)
returns boolean language sql immutable as $$
    select p is not null and (
        regexp_replace(p, '[\s().+-]', '', 'g') ~ '^[0-9]{8,15}$'
        or trim(p) ~* '^(https?://)?(www\.|m\.|web\.|mbasic\.)?(facebook\.com|fb\.com|fb\.me|m\.me|messenger\.com)/[A-Za-z0-9._/?=&%~+-]{2,}$'
    );
$$;

-- ---------------- PELANGGAN ----------------
drop function if exists cu_place_supply_order_k(uuid, bigint, integer, text, text);
create or replace function cu_place_supply_order_k(p_session_token uuid, p_batch_id bigint, p_qty integer, p_catatan text default null,
                                                   p_kontak text default null, p_tagar text default null)
returns bigint language plpgsql security definer set search_path = public, extensions as $$
declare v_id bigint; acc customer_accounts%rowtype; v_kontak text := trim(coalesce(p_kontak, '')); v_tagar text := trim(coalesce(p_tagar, ''));
begin
    acc := portal_session_acc(p_session_token);
    if not valid_kontak(v_kontak) then raise exception 'Kontak wajib diisi: nomor WhatsApp atau link profil Messenger yang valid'; end if;
    if v_tagar = '' then raise exception 'Tagar akun yang akan dikirim wajib diisi'; end if;
    v_id := cu_place_supply_order(p_session_token, p_batch_id, p_qty);
    update supply_orders set catatan = nullif(left(trim(coalesce(p_catatan, '')), 500), ''), kontak = left(v_kontak, 200), tagar = left(v_tagar, 200)
     where id = v_id and customer_id = acc.id;
    return v_id;
end; $$;

create or replace function cu_order_catalog_k(p_session_token uuid, p_item_id bigint, p_qty integer, p_catatan text default null,
                                              p_kontak text default null, p_tagar text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare r jsonb; acc customer_accounts%rowtype; v_kontak text := trim(coalesce(p_kontak, '')); v_tagar text := trim(coalesce(p_tagar, ''));
begin
    acc := portal_session_acc(p_session_token);
    if not valid_kontak(v_kontak) then raise exception 'Kontak wajib diisi: nomor WhatsApp atau link profil Messenger yang valid'; end if;
    if v_tagar = '' then raise exception 'Tagar akun yang akan dikirim wajib diisi'; end if;
    r := cu_order_catalog(p_session_token, p_item_id, p_qty, p_catatan);
    update catalog_orders set kontak = left(v_kontak, 200), tagar = left(v_tagar, 200) where id = (r->>'id')::bigint and customer_id = acc.id;
    return r;
end; $$;

-- ---------------- ADMIN ----------------
create or replace function co_list(p_pin text, p_kind text default 'all')
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    return coalesce((select jsonb_agg(to_jsonb(r) order by r.created_at desc)
        from (select o.id, o.username, o.item_nama, o.kategori, o.qty, o.harga_satuan, o.total, o.catatan, o.status, o.catatan_admin,
                     o.created_at, o.processed_at, o.kontak, o.tagar, ca.whatsapp
                from catalog_orders o join customer_accounts ca on ca.id = o.customer_id
               where p_kind = 'all' or (p_kind = 'koin' and o.kategori = 'koin') or (p_kind = 'voucher' and o.kategori <> 'koin')
               order by o.created_at desc limit 300) r), '[]'::jsonb);
end; $$;

create or replace function sp_list_orders(p_pin text, p_status text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v jsonb;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    select coalesce(jsonb_agg(jsonb_build_object(
        'id', o.id, 'username', o.username, 'qty', o.qty, 'status', o.status, 'harga_total', o.harga_total,
        'created_at', o.created_at, 'sent_at', o.sent_at, 'processed_at', o.processed_at,
        'batch', b.nama, 'item', b.item, 'satuan', b.satuan,
        'catatan', o.catatan, 'kontak', o.kontak, 'tagar', o.tagar, 'catatan_admin', o.catatan_admin,
        'whatsapp', (select ca.whatsapp from customer_accounts ca where ca.id = o.customer_id)
    ) order by o.created_at desc), '[]'::jsonb) into v
    from supply_orders o join supply_batches b on b.id = o.batch_id
    where p_status = 'all' or o.status = p_status;
    return v;
end; $$;

-- tolak pesanan Supply: koin yang dipotong dikembalikan
create or replace function sp_reject_order(p_pin text, p_id bigint, p_catatan text default null)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare o supply_orders%rowtype;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    select * into o from supply_orders where id = p_id and status = 'pending' for update;
    if not found then raise exception 'Pesanan tidak ditemukan atau sudah diproses'; end if;
    update supply_orders set status = 'rejected', processed_at = now(), catatan_admin = nullif(left(trim(coalesce(p_catatan, '')), 300), '') where id = p_id;
    if coalesce(o.koin_dipotong, 0) > 0 then
        perform coin_apply(o.customer_id, o.koin_dipotong, 'refund', 'Pesanan Supply ditolak #' || o.id, 'supply', o.id);
    end if;
end; $$;

grant execute on function valid_kontak(text), cu_place_supply_order_k(uuid, bigint, integer, text, text, text),
    cu_order_catalog_k(uuid, bigint, integer, text, text, text), co_list(text, text), sp_list_orders(text, text), sp_reject_order(text, bigint, text)
to anon, authenticated;
