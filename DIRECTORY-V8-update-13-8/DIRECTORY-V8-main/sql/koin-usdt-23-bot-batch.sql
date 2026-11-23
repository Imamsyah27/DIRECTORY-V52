-- =====================================================================
-- KOIN — BAGIAN 23: BATCH TAGAR BOT (antrian semua tagar per paket, dibagi per batch)
-- Jalankan SETELAH koin-usdt-22. Aman diulang.
--  * Pesanan Bot/Bulk yang di-ACC: tagarnya masuk antrian (bot_queue) menurut urutan di-ACC, per paket BEM / SEM / LEM.
--  * Batch = potongan antrian berukuran bot_batch_settings.batch_size (admin bebas mengubah; batch pelanggan ikut berubah).
--  * Admin mencentang batch = tagar di dalamnya terkirim. Pesanan yang tagarnya terkirim sebagian -> pelanggan melihat "terkirim sebagian".
--  * Pelanggan hanya melihat tagar MILIKNYA ada berapa di batch berapa (tanpa isi tagar orang lain).
-- File ini: tabel, antrian, ACC otomatis masuk antrian, fungsi pelanggan. Lanjutkan dengan koin-usdt-23b-batch-admin.sql
-- =====================================================================
create table if not exists bot_batch_settings (
    id integer primary key default 1 check (id = 1),
    batch_size integer not null default 50 check (batch_size between 1 and 5000)
);
insert into bot_batch_settings (id, batch_size) values (1, 50) on conflict (id) do nothing;
alter table bot_batch_settings enable row level security;

create table if not exists bot_queue (
    id bigint generated always as identity primary key,
    order_id bigint not null references bot_orders(id) on delete cascade,
    customer_id bigint,
    username text,
    dashboard text not null check (dashboard in ('BEM', 'SEM', 'LEM')),
    pos integer not null,
    tagar text not null,
    sent_at timestamptz,
    created_at timestamptz not null default now()
);
create index if not exists bot_queue_dash_idx on bot_queue (dashboard, id);
create index if not exists bot_queue_order_idx on bot_queue (order_id);
alter table bot_queue enable row level security;       -- tanpa policy publik

-- masukkan tagar pesanan yang sudah di-ACC ke antrian (sekali per pesanan)
create or replace function bq_enqueue(p_id bigint)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare b bot_orders%rowtype;
begin
    select * into b from bot_orders where id = p_id;
    if not found or b.status <> 'approved' then return; end if;
    if exists (select 1 from bot_queue where order_id = p_id) then return; end if;
    if b.dashboard = 'BULK' then
        insert into bot_queue (order_id, customer_id, username, dashboard, pos, tagar)
        select b.id, b.customer_id, b.username, d.dash, d.ord::integer, d.tag
          from (select 'BEM'::text dash, 1 grp, t.tag, t.ord from unnest(coalesce(b.tagar_bem, '{}'::text[])) with ordinality t(tag, ord)
                union all select 'SEM', 2, t.tag, t.ord from unnest(coalesce(b.tagar_sem, '{}'::text[])) with ordinality t(tag, ord)
                union all select 'LEM', 3, t.tag, t.ord from unnest(coalesce(b.tagar_lem, '{}'::text[])) with ordinality t(tag, ord)) d
         order by d.grp, d.ord;
    else
        insert into bot_queue (order_id, customer_id, username, dashboard, pos, tagar)
        select b.id, b.customer_id, b.username, b.dashboard, t.ord::integer, t.tag
          from unnest(b.tagar_list) with ordinality t(tag, ord) order by t.ord;
    end if;
end; $$;

-- samakan status "dikirim" pesanan: semua tagar terkirim -> dikirim_at terisi; ada yang belum -> kosong
create or replace function bq_sync(p_order_ids bigint[])
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    update bot_orders o set dikirim_at = case when exists (select 1 from bot_queue q where q.order_id = o.id and q.sent_at is null) then null else coalesce(o.dikirim_at, now()) end
     where o.id = any(p_order_ids) and o.status = 'approved' and exists (select 1 from bot_queue q where q.order_id = o.id);
end; $$;
revoke all on function bq_enqueue(bigint), bq_sync(bigint[]) from public, anon, authenticated;

-- pesanan yang SUDAH di-ACC sebelum fitur ini ikut dimasukkan (yang sudah dikirim ditandai terkirim)
do $$
declare v_max bigint; r record;
begin
    select coalesce(max(id), 0) into v_max from bot_queue;
    for r in select id from bot_orders where status = 'approved' and not arsip order by processed_at nulls last, id loop
        perform bq_enqueue(r.id);
    end loop;
    update bot_queue q set sent_at = o.dikirim_at from bot_orders o where o.id = q.order_id and o.dikirim_at is not null and q.sent_at is null and q.id > v_max;
end $$;

create or replace function bot_approve(p_pin text, p_id bigint)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare b bot_orders%rowtype; v_m integer; v_modal bigint; v_ket text;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    select * into b from bot_orders where id = p_id for update;
    if not found then raise exception 'Pesanan tidak ditemukan'; end if;
    if b.status <> 'pending' then raise exception 'Pesanan ini sudah diproses'; end if;

    if b.dashboard = 'BULK' then
        v_modal := coalesce(cardinality(b.tagar_bem), 0)::bigint * md_get('bsl:bot_bem')
                 + coalesce(cardinality(b.tagar_sem), 0)::bigint * md_get('bsl:bot_sem')
                 + coalesce(cardinality(b.tagar_lem), 0)::bigint * md_get('bsl:bot_lem');
        v_ket := 'Bulk Order #' || b.id || ' · BEM ' || coalesce(cardinality(b.tagar_bem), 0) || ' / SEM ' || coalesce(cardinality(b.tagar_sem), 0)
                 || ' / LEM ' || coalesce(cardinality(b.tagar_lem), 0);
        insert into bsl_entries (tanggal, jenis, kategori, pelanggan, keterangan, hari, jumlah_tagar, harga_hari, modal_hari, omset, modal, bot_order_id)
        values ((now() at time zone 'Asia/Jakarta')::date, 'bot', 'BULK Bot', b.username, v_ket, null, b.jumlah, b.harga_tagar,
                greatest((v_modal + b.jumlah - 1) / b.jumlah, 0), b.total_harga, v_modal, b.id)
        on conflict (bot_order_id) where bot_order_id is not null do nothing;
    else
        v_m := md_get('bsl:bot_' || lower(case when b.dashboard in ('BEM', 'SEM') then b.dashboard else 'LEM' end));
        v_modal := v_m::bigint * b.jumlah;
        insert into bsl_entries (tanggal, jenis, kategori, pelanggan, keterangan, hari, jumlah_tagar, harga_hari, modal_hari, omset, modal, bot_order_id)
        values ((now() at time zone 'Asia/Jakarta')::date, 'bot', b.dashboard || ' Bot', b.username, 'Bot Order #' || b.id,
                null, b.jumlah, b.harga_tagar, v_m, b.total_harga, v_modal, b.id)
        on conflict (bot_order_id) where bot_order_id is not null do nothing;
    end if;

    update bot_orders set status = 'approved', processed_at = now() where id = b.id;
    perform bq_enqueue(b.id);        -- tagar masuk antrian batch
    return jsonb_build_object('id', b.id, 'omset', b.total_harga, 'modal', v_modal, 'profit', b.total_harga - v_modal);
end; $$;

-- centang "dikirim" per pesanan (alur lama) ikut menandai tagar di antrian
create or replace function bot_set_dikirim(p_pin text, p_id bigint, p_dikirim boolean)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare b bot_orders%rowtype;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    select * into b from bot_orders where id = p_id for update;
    if not found then raise exception 'Pesanan tidak ditemukan'; end if;
    if b.status <> 'approved' then raise exception 'Hanya pesanan yang sudah disetujui yang bisa ditandai dikirim'; end if;
    if b.arsip then raise exception 'Pesanan sudah diarsipkan'; end if;
    if exists (select 1 from bot_queue where order_id = p_id) then
        update bot_queue set sent_at = case when coalesce(p_dikirim, false) then coalesce(sent_at, now()) else null end where order_id = p_id;
        perform bq_sync(array[p_id]);
    else
        update bot_orders set dikirim_at = case when coalesce(p_dikirim, false) then now() else null end where id = p_id;
    end if;
    return jsonb_build_object('id', p_id, 'dikirim', coalesce(p_dikirim, false));
end; $$;

-- PELANGGAN: tagar MILIK SENDIRI ada berapa di batch berapa (tanpa isi tagar orang lain)
create or replace function cu_my_bot_batches(p_session_token uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare acc customer_accounts%rowtype; v_size integer;
begin
    acc := portal_session_acc(p_session_token);
    select batch_size into v_size from bot_batch_settings where id = 1;
    return coalesce((
        select jsonb_agg(jsonb_build_object('order_id', g.order_id, 'total', g.total, 'sent', g.sent, 'batches', g.batches))
          from (select r.order_id, sum(r.n)::int as total, sum(r.s)::int as sent,
                       jsonb_agg(jsonb_build_object('dashboard', r.dashboard, 'batch', r.batch, 'n', r.n, 'sent', r.s) order by r.dashboard, r.batch) as batches
                  from (select x.order_id, x.dashboard, ((x.rn - 1) / v_size) + 1 as batch, count(*)::int as n, count(x.sent_at)::int as s
                          from (select q.id, q.order_id, q.customer_id, q.dashboard, q.sent_at,
                                       row_number() over (partition by q.dashboard order by q.id) as rn
                                  from bot_queue q join bot_orders o on o.id = q.order_id and not o.arsip) x
                         where x.customer_id = acc.id
                         group by x.order_id, x.dashboard, ((x.rn - 1) / v_size) + 1) r
                 group by r.order_id) g), '[]'::jsonb);
end; $$;

-- auto-refresh (bila SQL 21 sudah dijalankan)
do $$
begin
    if to_regproc('sync_bump()') is not null then
        execute 'drop trigger if exists zz_sync_bump on public.bot_queue';
        execute 'create trigger zz_sync_bump after insert or update or delete on public.bot_queue for each statement execute function sync_bump(''requests'')';
        execute 'drop trigger if exists zz_sync_bump on public.bot_batch_settings';
        execute 'create trigger zz_sync_bump after insert or update or delete on public.bot_batch_settings for each statement execute function sync_bump(''requests'')';
    end if;
end $$;

grant execute on function bot_approve(text, bigint), bot_set_dikirim(text, bigint, boolean), cu_my_bot_batches(uuid) to anon, authenticated;
