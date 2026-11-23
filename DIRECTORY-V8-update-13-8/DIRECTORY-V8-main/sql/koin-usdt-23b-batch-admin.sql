-- =====================================================================
-- KOIN — BAGIAN 23b: BATCH TAGAR BOT — FUNGSI ADMIN (Order -> tab Batch Tagar)
-- Jalankan SETELAH koin-usdt-23-bot-batch.sql. Aman diulang.
-- =====================================================================
create or replace function bq_get(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_size integer;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    select batch_size into v_size from bot_batch_settings where id = 1;
    return jsonb_build_object(
        'size', v_size,
        'pending', (select count(*) from bot_orders where status = 'pending' and not arsip),
        'entries', coalesce((
            select jsonb_agg(jsonb_build_object('id', x.id, 'order_id', x.order_id, 'username', x.username, 'dashboard', x.dashboard,
                                                'tagar', x.tagar, 'sent', x.sent_at is not null, 'batch', ((x.rn - 1) / v_size) + 1) order by x.dashboard, x.id)
              from (select q.id, q.order_id, q.username, q.dashboard, q.tagar, q.sent_at,
                           row_number() over (partition by q.dashboard order by q.id) as rn
                      from bot_queue q join bot_orders o on o.id = q.order_id and not o.arsip) x), '[]'::jsonb),
        'orders', coalesce((
            select jsonb_agg(jsonb_build_object('id', o.id, 'username', o.username, 'dashboard', o.dashboard, 'jumlah', o.jumlah, 'total_harga', o.total_harga,
                                                'koin', o.koin_dipotong, 'n_total', c.n, 'n_sent', c.s, 'processed_at', o.processed_at, 'created_at', o.created_at) order by o.processed_at, o.id)
              from bot_orders o
              join (select order_id, count(*)::int as n, count(sent_at)::int as s from bot_queue group by order_id) c on c.order_id = o.id
             where o.status = 'approved' and not o.arsip and c.s < c.n), '[]'::jsonb));
end; $$;

create or replace function bq_set_size(p_pin text, p_size integer)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    if p_size is null or p_size < 1 or p_size > 5000 then raise exception 'Isi per batch harus 1 – 5000 tagar'; end if;
    update bot_batch_settings set batch_size = p_size where id = 1;
end; $$;

-- centang / lepas centang sebuah batch: p_ids = id tagar yang ada di batch itu (persis seperti yang dilihat admin)
create or replace function bq_mark(p_pin text, p_ids bigint[], p_sent boolean)
returns integer language plpgsql security definer set search_path = public, extensions as $$
declare n integer; v_orders bigint[];
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    select coalesce(array_agg(distinct order_id), '{}') into v_orders from bot_queue where id = any(coalesce(p_ids, '{}'));
    update bot_queue set sent_at = case when coalesce(p_sent, false) then coalesce(sent_at, now()) else null end where id = any(coalesce(p_ids, '{}'));
    get diagnostics n = row_count;
    perform bq_sync(v_orders);
    return n;
end; $$;

-- batalkan pesanan yang sudah di-ACC tapi BELUM dikirim: tagar keluar dari antrian, catatan BSL dihapus, koin kembali
create or replace function bot_cancel_approved(p_pin text, p_id bigint, p_catatan text default null)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare b bot_orders%rowtype;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    select * into b from bot_orders where id = p_id for update;
    if not found then raise exception 'Pesanan tidak ditemukan'; end if;
    if b.status <> 'approved' or b.arsip then raise exception 'Hanya pesanan yang sudah di-ACC dan belum diarsipkan yang bisa dibatalkan'; end if;
    if b.dikirim_at is not null or exists (select 1 from bot_queue where order_id = p_id and sent_at is not null) then
        raise exception 'Sebagian / seluruh tagar pesanan ini sudah dikirim, tidak bisa dibatalkan'; end if;
    delete from bot_queue where order_id = p_id;
    delete from bsl_entries where bot_order_id = p_id;
    update bot_orders set status = 'rejected', processed_at = now(), dikirim_at = null,
           catatan_admin = coalesce(nullif(left(trim(coalesce(p_catatan, '')), 300), ''), 'Dibatalkan admin setelah disetujui') where id = p_id;
    if b.koin_dipotong > 0 then
        perform coin_apply(b.customer_id, b.koin_dipotong, 'refund', 'Bot Order dibatalkan #' || b.id, 'bot', b.id);
    end if;
end; $$;

grant execute on function bq_get(text), bq_set_size(text, integer), bq_mark(text, bigint[], boolean), bot_cancel_approved(text, bigint, text) to anon, authenticated;
