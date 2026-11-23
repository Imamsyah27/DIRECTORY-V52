-- =====================================================================
-- MIGRASI 001 — STATUS TAGAR BATCH BOT + AKSI MASSAL BOT ORDER
-- Jalankan SEKALI di Supabase SQL Editor, SETELAH sql/koin-usdt-23-bot-batch.sql dan 23b. Aman diulang.
-- JANGAN menjalankan ulang koin-usdt-23 / 23b sesudah file ini (fungsi batch akan kembali ke versi lama).
--
-- Penyebab bug lama: bot_queue tidak punya status. Nomor batch dihitung dari SEMUA tagar pesanan yang belum
-- diarsip, termasuk yang sudah terkirim, sehingga tagar terkirim selamanya menempati Batch 1.
--
-- Sekarang tiap tagar punya status:
--   pending   -> menunggu dikirim (HANYA status ini yang dibagi ke batch)
--   sent      -> sudah dikirim, belum diarsip (keluar dari batch, slot langsung diisi tagar pending berikutnya)
--   archived  -> sudah diarsip (tagar diarsip dari tab Batch, atau pesanannya diarsip)
--   cancelled -> pesanan dibatalkan admin setelah ACC
-- =====================================================================

-- 1. Kolom status + isi data lama ---------------------------------------
alter table bot_queue add column if not exists status text not null default 'pending';
do $$
begin
    if not exists (select 1 from pg_constraint where conname = 'bot_queue_status_chk') then
        alter table bot_queue add constraint bot_queue_status_chk check (status in ('pending', 'sent', 'archived', 'cancelled'));
    end if;
end $$;

update bot_queue q set status = 'archived'
  from bot_orders o
 where o.id = q.order_id and o.arsip and q.status in ('pending', 'sent');
update bot_queue set status = 'sent' where status = 'pending' and sent_at is not null;

create index if not exists bot_queue_pending_idx on bot_queue (dashboard, id) where status = 'pending';
create index if not exists bot_queue_order_status_idx on bot_queue (order_id, status);

-- 2. Sinkron status pesanan: masih ada tagar pending -> belum dikirim; semua terkirim -> dikirim_at terisi
create or replace function bq_sync(p_order_ids bigint[])
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    update bot_orders o
       set dikirim_at = case when exists (select 1 from bot_queue q where q.order_id = o.id and q.status = 'pending')
                             then null else coalesce(o.dikirim_at, now()) end
     where o.id = any(p_order_ids) and o.status = 'approved'
       and exists (select 1 from bot_queue q where q.order_id = o.id and q.status in ('pending', 'sent', 'archived'));
end; $$;
revoke all on function bq_sync(bigint[]) from public, anon, authenticated;

-- 3. Arsip / batal arsip pesanan (dari menu Bot Order) ikut mengubah status tagarnya
create or replace function bq_on_order_arsip()
returns trigger language plpgsql security definer set search_path = public, extensions as $$
begin
    if new.arsip and not old.arsip then
        update bot_queue set status = 'archived' where order_id = new.id and status in ('pending', 'sent');
    elsif old.arsip and not new.arsip then
        update bot_queue set status = case when sent_at is not null then 'sent' else 'pending' end
         where order_id = new.id and status = 'archived';
    end if;
    return null;
end; $$;
revoke all on function bq_on_order_arsip() from public, anon, authenticated;
drop trigger if exists bq_order_arsip on bot_orders;
create trigger bq_order_arsip after update of arsip on bot_orders
    for each row when (old.arsip is distinct from new.arsip) execute function bq_on_order_arsip();

-- 4. ADMIN: data tab Batch Tagar ------------------------------------------
-- pending: semua tagar pending (dibagi ke batch di browser, urut id = urut ACC)
-- sent: tagar terkirim yang belum diarsip (panel "Sudah dikirim")
create or replace function bq_get(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_size integer;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    select batch_size into v_size from bot_batch_settings where id = 1;
    return jsonb_build_object(
        'size', v_size,
        'pending', (select count(*) from bot_orders where status = 'pending' and not arsip),
        'archived', (select count(*) from bot_queue where status = 'archived'),
        'entries', coalesce((
            select jsonb_agg(jsonb_build_object('id', q.id, 'order_id', q.order_id, 'username', q.username, 'dashboard', q.dashboard, 'tagar', q.tagar) order by q.dashboard, q.id)
              from bot_queue q where q.status = 'pending'), '[]'::jsonb),
        'sent', coalesce((
            select jsonb_agg(jsonb_build_object('id', q.id, 'order_id', q.order_id, 'username', q.username, 'dashboard', q.dashboard, 'tagar', q.tagar, 'sent_at', q.sent_at) order by q.sent_at desc, q.id)
              from bot_queue q where q.status = 'sent'), '[]'::jsonb),
        'orders', coalesce((
            select jsonb_agg(jsonb_build_object('id', o.id, 'username', o.username, 'dashboard', o.dashboard, 'jumlah', o.jumlah, 'total_harga', o.total_harga,
                                                'koin', o.koin_dipotong, 'n_total', c.n, 'n_sent', c.s, 'processed_at', o.processed_at) order by o.processed_at, o.id)
              from bot_orders o
              join (select order_id, count(*)::int as n, count(*) filter (where status <> 'pending')::int as s
                      from bot_queue where status in ('pending', 'sent', 'archived') group by order_id) c on c.order_id = o.id
             where o.status = 'approved' and not o.arsip and c.s < c.n), '[]'::jsonb));
end; $$;

-- tandai tagar terkirim (p_sent = true: pending -> sent) atau batalkan (false: sent -> pending).
-- Mengembalikan jumlah tagar yang berubah; 0 = error (data sudah berubah di tempat lain).
create or replace function bq_mark(p_pin text, p_ids bigint[], p_sent boolean)
returns integer language plpgsql security definer set search_path = public, extensions as $$
declare n integer; v_orders bigint[];
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    if coalesce(cardinality(p_ids), 0) = 0 then raise exception 'Tidak ada tagar yang dipilih'; end if;
    with upd as (
        update bot_queue
           set status = case when coalesce(p_sent, false) then 'sent' else 'pending' end,
               sent_at = case when coalesce(p_sent, false) then now() else null end
         where id = any(p_ids) and status = case when coalesce(p_sent, false) then 'pending' else 'sent' end
        returning order_id)
    select count(*)::int, coalesce(array_agg(distinct order_id), '{}') into n, v_orders from upd;
    if n = 0 then raise exception 'Tagar ini sudah berubah status (mungkin diubah admin lain). Muat ulang halaman.'; end if;
    perform bq_sync(v_orders);
    return n;
end; $$;

-- arsipkan tagar terkirim (semua, atau satu paket). Pesanan yang semua tagarnya sudah terkirim & diarsip ikut diarsip.
create or replace function bq_archive_sent(p_pin text, p_dashboard text default null)
returns integer language plpgsql security definer set search_path = public, extensions as $$
declare n integer; v_orders bigint[];
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    with upd as (
        update bot_queue set status = 'archived'
         where status = 'sent' and (p_dashboard is null or dashboard = p_dashboard)
        returning order_id)
    select count(*)::int, coalesce(array_agg(distinct order_id), '{}') into n, v_orders from upd;
    update bot_orders o set arsip = true, arsip_at = now()
     where o.id = any(v_orders) and o.status = 'approved' and not o.arsip and o.dikirim_at is not null
       and not exists (select 1 from bot_queue q where q.order_id = o.id and q.status in ('pending', 'sent'));
    return n;
end; $$;

-- 5. Centang "Dikirim" per pesanan (alur lama) --------------------------------
create or replace function bot_set_dikirim(p_pin text, p_id bigint, p_dikirim boolean)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_status text; v_arsip boolean;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    select status, arsip into v_status, v_arsip from bot_orders where id = p_id for update;
    if not found then raise exception 'Pesanan tidak ditemukan'; end if;
    if v_status <> 'approved' then raise exception 'Hanya pesanan yang sudah disetujui yang bisa ditandai dikirim'; end if;
    if v_arsip then raise exception 'Pesanan sudah diarsipkan'; end if;
    if exists (select 1 from bot_queue where order_id = p_id) then
        if coalesce(p_dikirim, false) then
            update bot_queue set status = 'sent', sent_at = coalesce(sent_at, now()) where order_id = p_id and status = 'pending';
        else
            update bot_queue set status = 'pending', sent_at = null where order_id = p_id and status = 'sent';
        end if;
        perform bq_sync(array[p_id]);
    else
        update bot_orders set dikirim_at = case when coalesce(p_dikirim, false) then now() else null end where id = p_id;
    end if;
    return jsonb_build_object('id', p_id, 'dikirim', coalesce(p_dikirim, false));
end; $$;

-- 6. Batalkan pesanan setelah ACC: tagar berstatus cancelled (tidak dihapus), BSL dihapus, koin kembali
create or replace function bot_cancel_approved(p_pin text, p_id bigint, p_catatan text default null)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_status text; v_arsip boolean; v_dikirim timestamptz; v_cust bigint; v_koin bigint;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    select status, arsip, dikirim_at, customer_id, koin_dipotong into v_status, v_arsip, v_dikirim, v_cust, v_koin
      from bot_orders where id = p_id for update;
    if not found then raise exception 'Pesanan tidak ditemukan'; end if;
    if v_status <> 'approved' or v_arsip then raise exception 'Hanya pesanan yang sudah di-ACC dan belum diarsipkan yang bisa dibatalkan'; end if;
    if v_dikirim is not null or exists (select 1 from bot_queue where order_id = p_id and status in ('sent', 'archived')) then
        raise exception 'Sebagian / seluruh tagar pesanan ini sudah dikirim, tidak bisa dibatalkan'; end if;
    update bot_queue set status = 'cancelled' where order_id = p_id and status = 'pending';
    delete from bsl_entries where bot_order_id = p_id;
    update bot_orders set status = 'rejected', processed_at = now(), dikirim_at = null,
           catatan_admin = coalesce(nullif(left(trim(coalesce(p_catatan, '')), 300), ''), 'Dibatalkan admin setelah disetujui') where id = p_id;
    if coalesce(v_koin, 0) > 0 then
        perform coin_apply(v_cust, v_koin, 'refund', 'Bot Order dibatalkan #' || p_id, 'bot', p_id);
    end if;
end; $$;

-- 7. AKSI MASSAL (1 request untuk banyak pesanan) --------------------------------
-- Terima semua: menjalankan bot_approve (BSL Profit + antrian batch) untuk tiap id
create or replace function bot_approve_many(p_pin text, p_ids bigint[])
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_id bigint; v_ok bigint[] := '{}'; v_fail jsonb := '[]'::jsonb;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    if coalesce(cardinality(p_ids), 0) = 0 then raise exception 'Tidak ada pesanan yang dipilih'; end if;
    if cardinality(p_ids) > 500 then raise exception 'Maksimal 500 pesanan sekali proses'; end if;
    foreach v_id in array p_ids loop
        begin
            perform bot_approve(p_pin, v_id);
            v_ok := v_ok || v_id;
        exception when others then
            v_fail := v_fail || jsonb_build_object('id', v_id, 'error', sqlerrm);
        end;
    end loop;
    return jsonb_build_object('ok', to_jsonb(v_ok), 'fail', v_fail);
end; $$;

-- Tandai semua sudah dikirim: semua tagar pesanan -> sent (keluar dari batch), dikirim_at terisi
create or replace function bot_set_dikirim_many(p_pin text, p_ids bigint[])
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_id bigint; v_ok bigint[] := '{}'; v_fail jsonb := '[]'::jsonb;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    if coalesce(cardinality(p_ids), 0) = 0 then raise exception 'Tidak ada pesanan yang dipilih'; end if;
    if cardinality(p_ids) > 500 then raise exception 'Maksimal 500 pesanan sekali proses'; end if;
    foreach v_id in array p_ids loop
        begin
            perform bot_set_dikirim(p_pin, v_id, true);
            v_ok := v_ok || v_id;
        exception when others then
            v_fail := v_fail || jsonb_build_object('id', v_id, 'error', sqlerrm);
        end;
    end loop;
    return jsonb_build_object('ok', to_jsonb(v_ok), 'fail', v_fail);
end; $$;

-- 8. PELANGGAN: batch milik sendiri, nomor batch = posisi di antrian PENDING (sama dengan admin)
-- tagar terkirim tampil sebagai entri dengan batch = null
create or replace function cu_my_bot_batches(p_session_token uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare acc customer_accounts%rowtype; v_size integer;
begin
    acc := portal_session_acc(p_session_token);
    select batch_size into v_size from bot_batch_settings where id = 1;
    return coalesce((
        select jsonb_agg(jsonb_build_object('order_id', g.order_id, 'total', g.total, 'sent', g.sent, 'batches', g.batches))
          from (select r.order_id, sum(r.n)::int as total, sum(r.s)::int as sent,
                       jsonb_agg(jsonb_build_object('dashboard', r.dashboard, 'batch', r.batch, 'n', r.n, 'sent', r.s) order by r.dashboard, r.batch nulls first) as batches
                  from (select x.order_id, x.dashboard, x.batch, count(*)::int as n, count(*) filter (where x.status <> 'pending')::int as s
                          from (select q.order_id, q.customer_id, q.dashboard, q.status,
                                       case when q.status = 'pending'
                                            then ((row_number() over (partition by q.dashboard, (q.status = 'pending') order by q.id) - 1) / v_size) + 1 end as batch
                                  from bot_queue q join bot_orders o on o.id = q.order_id and not o.arsip
                                 where q.status in ('pending', 'sent')) x
                         where x.customer_id = acc.id
                         group by x.order_id, x.dashboard, x.batch) r
                 group by r.order_id) g), '[]'::jsonb);
end; $$;

grant execute on function bq_get(text), bq_mark(text, bigint[], boolean), bq_archive_sent(text, text),
    bot_set_dikirim(text, bigint, boolean), bot_cancel_approved(text, bigint, text),
    bot_approve_many(text, bigint[]), bot_set_dikirim_many(text, bigint[]), cu_my_bot_batches(uuid) to anon, authenticated;
