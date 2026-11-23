-- =====================================================================
-- MIGRASI 004 — PELANGGAN MEMBATALKAN ORDER SENDIRI (status "cancelled", data tidak dihapus)
-- Jalankan SEKALI di Supabase SQL Editor, SETELAH migrasi 001. Aman diulang.
--
-- Berlaku untuk order yang MASIH MENUNGGU (status 'pending', belum diproses/dikirim admin):
--   bot       -> bot_orders (Bot Order & Bulk Order)        koin dikembalikan
--   renewal   -> renewal_requests (Pesanan Baru / Perpanjang) koin + jatah kode referal dikembalikan
--   catalog   -> catalog_orders (Koin Hayday, Voucher, Katalog) koin dikembalikan
--   preorder  -> preorder_orders (Pre Order)                 koin dikembalikan
--   supply    -> supply_orders (Supply & Stock)              koin dikembalikan
--   topup     -> coin_topups (Top Up Koin)                   tidak ada koin yang perlu dikembalikan
-- (Request langganan / order_requests sudah memakai status 'cancelled' sejak koin-usdt-20.)
-- Pembelian Farm / HAV Token langsung terkirim otomatis saat dibayar, jadi tidak bisa dibatalkan.
--
-- Keamanan: semua tabel di atas RLS aktif tanpa policy publik. Pembatalan HANYA lewat fungsi ini;
-- customer_id diambil dari sesi login (portal_session_acc), dan UPDATE mensyaratkan
-- customer_id = pemilik AND status = 'pending' secara atomik.
-- =====================================================================

-- 1. Izinkan status 'cancelled' + kolom waktu batal --------------------------
do $$
declare spec text; tb text; allowed text; c record;
begin
    foreach spec in array array[
        'bot_orders:pending,approved,rejected,cancelled',
        'renewal_requests:pending,approved,rejected,cancelled',
        'catalog_orders:pending,done,rejected,cancelled',
        'preorder_orders:pending,done,rejected,cancelled',
        'supply_orders:pending,sent,rejected,cancelled',
        'coin_topups:pending,approved,rejected,cancelled'
    ] loop
        tb := split_part(spec, ':', 1);
        allowed := '''' || replace(split_part(spec, ':', 2), ',', ''',''') || '''';
        if to_regclass('public.' || tb) is null then continue; end if;
        -- hapus check constraint lama pada kolom status (nama bawaan bisa berbeda-beda)
        for c in select conname from pg_constraint
                  where conrelid = ('public.' || tb)::regclass and contype = 'c' and pg_get_constraintdef(oid) ilike '%status%' loop
            execute format('alter table public.%I drop constraint %I', tb, c.conname);
        end loop;
        execute format('alter table public.%I add constraint %I check (status in (%s))', tb, tb || '_status_check', allowed);
        execute format('alter table public.%I add column if not exists cancelled_at timestamptz', tb);
    end loop;
end $$;

-- supply_orders mendapat kolom processed_at di koin-usdt-22; pastikan ada untuk database lama
alter table supply_orders add column if not exists processed_at timestamptz;

-- 2. Fungsi batal utama ----------------------------------------------------
create or replace function cu_cancel_order(p_session_token uuid, p_kind text, p_id bigint)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare acc customer_accounts%rowtype; v_refund bigint := 0; v_kode text; v_ref text;
begin
    acc := portal_session_acc(p_session_token);       -- sesi tidak valid -> exception

    if p_kind = 'bot' then
        update bot_orders set status = 'cancelled', cancelled_at = now(), processed_at = now()
         where id = p_id and customer_id = acc.id and status = 'pending'
        returning koin_dipotong, case when dashboard = 'BULK' then 'Bulk Order' else 'Bot Order' end into v_refund, v_ref;
        if not found then raise exception 'Pesanan tidak ditemukan atau sudah diproses'; end if;
        -- tagar pesanan yang menunggu belum pernah masuk antrian; jaga-jaga bila ada, tandai cancelled (tidak masuk batch)
        update bot_queue set status = 'cancelled' where order_id = p_id and status = 'pending';
        if coalesce(v_refund, 0) > 0 then
            perform coin_apply(acc.id, v_refund, 'refund', v_ref || ' dibatalkan pelanggan #' || p_id, 'bot', p_id);
        end if;

    elsif p_kind = 'renewal' then
        update renewal_requests set status = 'cancelled', cancelled_at = now(), processed_at = now()
         where id = p_id and customer_id = acc.id and status = 'pending'
        returning koin_dipotong, kode_referal into v_refund, v_kode;
        if not found then raise exception 'Permintaan tidak ditemukan atau sudah diproses'; end if;
        if coalesce(v_refund, 0) > 0 then
            perform coin_apply(acc.id, v_refund, 'refund', 'Pesanan dibatalkan #' || p_id, 'renewal', p_id);
        end if;
        if v_kode is not null then           -- jatah kode referal kembali (sama seperti saat ditolak admin)
            update referral_codes set used_count = greatest(used_count - 1, 0) where upper(kode) = upper(v_kode);
            delete from referral_uses where request_id = p_id;
        end if;

    elsif p_kind = 'catalog' then
        update catalog_orders set status = 'cancelled', cancelled_at = now(), processed_at = now()
         where id = p_id and customer_id = acc.id and status = 'pending'
        returning total into v_refund;
        if not found then raise exception 'Pesanan tidak ditemukan atau sudah diproses'; end if;
        if coalesce(v_refund, 0) > 0 then
            perform coin_apply(acc.id, v_refund, 'refund', 'Pesanan dibatalkan pelanggan #' || p_id, 'catalog', p_id);
        end if;

    elsif p_kind = 'preorder' then
        update preorder_orders set status = 'cancelled', cancelled_at = now(), processed_at = now()
         where id = p_id and customer_id = acc.id and status = 'pending'
        returning total_koin into v_refund;
        if not found then raise exception 'Pesanan tidak ditemukan atau sudah diproses'; end if;
        if coalesce(v_refund, 0) > 0 then
            perform coin_apply(acc.id, v_refund, 'refund', 'Pre Order dibatalkan pelanggan #' || p_id, 'preorder', p_id);
        end if;

    elsif p_kind = 'supply' then
        update supply_orders set status = 'cancelled', cancelled_at = now(), processed_at = now()
         where id = p_id and customer_id = acc.id and status = 'pending'
        returning koin_dipotong into v_refund;
        if not found then raise exception 'Pesanan tidak ditemukan atau sudah diproses'; end if;
        if coalesce(v_refund, 0) > 0 then
            perform coin_apply(acc.id, v_refund, 'refund', 'Supply dibatalkan pelanggan #' || p_id, 'supply', p_id);
        end if;

    elsif p_kind = 'topup' then
        update coin_topups set status = 'cancelled', cancelled_at = now(), processed_at = now()
         where id = p_id and customer_id = acc.id and status = 'pending';
        if not found then raise exception 'Top up tidak ditemukan atau sudah diproses'; end if;

    else
        raise exception 'Jenis pesanan tidak dikenal';
    end if;

    return jsonb_build_object('kind', p_kind, 'id', p_id, 'refund', coalesce(v_refund, 0));
end; $$;

-- 3. Fungsi batal lama: dulu MENGHAPUS baris, sekarang memakai status 'cancelled'
create or replace function cu_cancel_renewal(p_session_token uuid, p_id bigint)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin perform cu_cancel_order(p_session_token, 'renewal', p_id); end; $$;

create or replace function cu_cancel_supply_order(p_session_token uuid, p_id bigint)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin perform cu_cancel_order(p_session_token, 'supply', p_id); end; $$;

create or replace function cu_cancel_topup(p_session_token uuid, p_id bigint)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin perform cu_cancel_order(p_session_token, 'topup', p_id); end; $$;

-- 4. Admin: order yang sudah dibatalkan tidak bisa diproses lagi -------------
-- Supply "Sudah dikirim / Batal kirim" dulu tanpa cek status (bisa menghidupkan order yang dibatalkan / ditolak)
create or replace function sp_set_order_status(p_pin text, p_id bigint, p_sent boolean)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    update supply_orders set status = case when p_sent then 'sent' else 'pending' end,
        sent_at = case when p_sent then now() else null end
     where id = p_id and status in ('pending', 'sent');
    if not found then raise exception 'Pesanan sudah dibatalkan / ditolak, tidak bisa diubah'; end if;
end; $$;

-- Bot Order: pesanan dibatalkan boleh diarsipkan admin (selain yang terkirim / ditolak)
create or replace function bot_set_arsip(p_pin text, p_id bigint, p_arsip boolean)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_status text; v_dikirim timestamptz;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    select status, dikirim_at into v_status, v_dikirim from bot_orders where id = p_id for update;
    if not found then raise exception 'Pesanan tidak ditemukan'; end if;
    if coalesce(p_arsip, false) then
        if not (v_status in ('rejected', 'cancelled') or (v_status = 'approved' and v_dikirim is not null)) then
            raise exception 'Hanya pesanan yang sudah dikirim, ditolak, atau dibatalkan yang bisa diarsipkan';
        end if;
        update bot_orders set arsip = true, arsip_at = now() where id = p_id;
    else
        update bot_orders set arsip = false, arsip_at = null where id = p_id;
    end if;
end; $$;

-- Batch: hanya tagar dari pesanan berstatus approved yang boleh masuk antrian (pengaman tambahan)
create or replace function bq_enqueue(p_id bigint)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_status text; v_dash text; v_cust bigint; v_user text; v_list text[]; v_bem text[]; v_sem text[]; v_lem text[];
begin
    select status, dashboard, customer_id, username, tagar_list, tagar_bem, tagar_sem, tagar_lem
      into v_status, v_dash, v_cust, v_user, v_list, v_bem, v_sem, v_lem from bot_orders where id = p_id;
    if not found or v_status <> 'approved' then return; end if;
    if exists (select 1 from bot_queue where order_id = p_id) then return; end if;
    if v_dash = 'BULK' then
        insert into bot_queue (order_id, customer_id, username, dashboard, pos, tagar)
        select p_id, v_cust, v_user, d.dash, d.ord::integer, d.tag
          from (select 'BEM'::text dash, 1 grp, t.tag, t.ord from unnest(coalesce(v_bem, '{}'::text[])) with ordinality t(tag, ord)
                union all select 'SEM', 2, t.tag, t.ord from unnest(coalesce(v_sem, '{}'::text[])) with ordinality t(tag, ord)
                union all select 'LEM', 3, t.tag, t.ord from unnest(coalesce(v_lem, '{}'::text[])) with ordinality t(tag, ord)) d
         order by d.grp, d.ord;
    else
        insert into bot_queue (order_id, customer_id, username, dashboard, pos, tagar)
        select p_id, v_cust, v_user, v_dash, t.ord::integer, t.tag
          from unnest(v_list) with ordinality t(tag, ord) order by t.ord;
    end if;
end; $$;
revoke all on function bq_enqueue(bigint) from public, anon, authenticated;

grant execute on function cu_cancel_order(uuid, text, bigint), cu_cancel_renewal(uuid, bigint), cu_cancel_supply_order(uuid, bigint),
    cu_cancel_topup(uuid, bigint), sp_set_order_status(text, bigint, boolean), bot_set_arsip(text, bigint, boolean) to anon, authenticated;
