-- =====================================================================
-- MIGRASI 008 — PROSES 1F / 2F (bagian 2): batch per jenis + proses, daftar order, search.
-- Jalankan SEKALI SETELAH migrations/007_bot_proses_1f_2f.sql, lalu lanjutkan dengan 009. Aman diulang.
-- (Dipisah dari 007 karena SQL Editor Supabase memotong skrip di sekitar 20.000 karakter.)
-- =====================================================================

-- 7. Antrian batch: tagar mewarisi proses pesanannya -------------------------
create or replace function bq_enqueue(p_id bigint)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_status text; v_dash text; v_pro text; v_cust bigint; v_user text; v_list text[]; v_bem text[]; v_sem text[]; v_lem text[];
begin
    select status, dashboard, proses, customer_id, username, tagar_list, tagar_bem, tagar_sem, tagar_lem
      into v_status, v_dash, v_pro, v_cust, v_user, v_list, v_bem, v_sem, v_lem from bot_orders where id = p_id;
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
        insert into bot_queue (order_id, customer_id, username, dashboard, proses, pos, tagar)
        select p_id, v_cust, v_user, v_dash, v_pro, t.ord::integer, t.tag
          from unnest(v_list) with ordinality t(tag, ord) order by t.ord;
    end if;
end; $$;
revoke all on function bq_enqueue(bigint) from public, anon, authenticated;

-- ADMIN: data tab Batch Tagar (sama dengan migrasi 001 + proses per tagar; batch dikelompokkan di browser per jenis + proses)
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
            select jsonb_agg(jsonb_build_object('id', q.id, 'order_id', q.order_id, 'username', q.username, 'dashboard', q.dashboard, 'proses', q.proses, 'tagar', q.tagar) order by q.dashboard, q.id)
              from bot_queue q where q.status = 'pending'), '[]'::jsonb),
        'sent', coalesce((
            select jsonb_agg(jsonb_build_object('id', q.id, 'order_id', q.order_id, 'username', q.username, 'dashboard', q.dashboard, 'proses', q.proses, 'tagar', q.tagar, 'sent_at', q.sent_at) order by q.sent_at desc, q.id)
              from bot_queue q where q.status = 'sent'), '[]'::jsonb),
        'orders', coalesce((
            select jsonb_agg(jsonb_build_object('id', o.id, 'username', o.username, 'dashboard', o.dashboard, 'proses', o.proses, 'jumlah', o.jumlah, 'total_harga', o.total_harga,
                                                'koin', o.koin_dipotong, 'n_total', c.n, 'n_sent', c.s, 'processed_at', o.processed_at) order by o.processed_at, o.id)
              from bot_orders o
              join (select order_id, count(*)::int as n, count(*) filter (where status <> 'pending')::int as s
                      from bot_queue where status in ('pending', 'sent', 'archived') group by order_id) c on c.order_id = o.id
             where o.status = 'approved' and not o.arsip and c.s < c.n), '[]'::jsonb));
end; $$;

-- PELANGGAN: batch milik sendiri — nomor batch per kombinasi jenis + proses (sama dengan admin)
create or replace function cu_my_bot_batches(p_session_token uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare acc customer_accounts%rowtype; v_size integer;
begin
    acc := portal_session_acc(p_session_token);
    select batch_size into v_size from bot_batch_settings where id = 1;
    return coalesce((
        select jsonb_agg(jsonb_build_object('order_id', g.order_id, 'total', g.total, 'sent', g.sent, 'batches', g.batches))
          from (select r.order_id, sum(r.n)::int as total, sum(r.s)::int as sent,
                       jsonb_agg(jsonb_build_object('dashboard', r.dashboard, 'proses', r.proses, 'batch', r.batch, 'n', r.n, 'sent', r.s) order by r.dashboard, r.batch nulls first) as batches
                  from (select x.order_id, x.dashboard, x.proses, x.batch, count(*)::int as n, count(*) filter (where x.status <> 'pending')::int as s
                          from (select q.order_id, q.customer_id, q.dashboard, q.proses, q.status,
                                       case when q.status = 'pending'
                                            then ((row_number() over (partition by q.dashboard, coalesce(q.proses, ''), (q.status = 'pending') order by q.id) - 1) / v_size) + 1 end as batch
                                  from bot_queue q join bot_orders o on o.id = q.order_id and not o.arsip
                                 where q.status in ('pending', 'sent')) x
                         where x.customer_id = acc.id
                         group by x.order_id, x.dashboard, x.proses, x.batch) r
                 group by r.order_id) g), '[]'::jsonb);
end; $$;

-- 8. Daftar pesanan ikut membawa proses ----------------------------------------
create or replace function bot_list(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v jsonb;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    select coalesce(jsonb_agg(to_jsonb(r) order by r.created_at desc), '[]'::jsonb) into v
    from (select b.id, b.username, b.dashboard, b.proses, b.jumlah, b.tagar_list[1] as tagar_pertama, b.catatan_pelanggan,
                 b.harga_tagar, b.total_harga, b.status, b.catatan_admin, b.created_at, b.processed_at,
                 b.dikirim_at, b.arsip, b.arsip_at, b.bulk_tier,
                 coalesce(cardinality(b.tagar_bem), 0) as n_bem, coalesce(cardinality(b.tagar_sem), 0) as n_sem, coalesce(cardinality(b.tagar_lem), 0) as n_lem,
                 q.q_total, q.q_bem, q.q_sem, q.q_lem,
                 (select ca.whatsapp from customer_accounts ca where ca.id = b.customer_id) as whatsapp
            from bot_orders b
            left join lateral (
                select count(*)::int as q_total,
                       count(*) filter (where qq.dashboard = 'BEM' and qq.status = 'pending')::int as q_bem,
                       count(*) filter (where qq.dashboard = 'SEM' and qq.status = 'pending')::int as q_sem,
                       count(*) filter (where qq.dashboard = 'LEM' and qq.status = 'pending')::int as q_lem
                  from bot_queue qq where qq.order_id = b.id and qq.status in ('pending', 'sent', 'archived')) q on true
           order by b.created_at desc limit 500) r;
    return v;
end; $$;

create or replace function cu_my_bot_orders(p_session_token uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare acc customer_accounts%rowtype; v jsonb;
begin
    acc := portal_session_acc(p_session_token);
    select coalesce(jsonb_agg(jsonb_build_object(
        'id', b.id, 'dashboard', b.dashboard, 'proses', b.proses, 'jumlah', b.jumlah, 'tagar_pertama', b.tagar_list[1],
        'harga_tagar', b.harga_tagar, 'total_harga', b.total_harga, 'status', b.status,
        'catatan_admin', b.catatan_admin, 'created_at', b.created_at, 'processed_at', b.processed_at,
        'dikirim_at', b.dikirim_at, 'arsip', b.arsip, 'bulk_tier', b.bulk_tier,
        'n_bem', coalesce(cardinality(b.tagar_bem), 0), 'n_sem', coalesce(cardinality(b.tagar_sem), 0), 'n_lem', coalesce(cardinality(b.tagar_lem), 0)
    ) order by b.created_at desc), '[]'::jsonb) into v
    from (select id, dashboard, proses, jumlah, tagar_list, harga_tagar, total_harga, status, catatan_admin, created_at, processed_at,
                 dikirim_at, arsip, bulk_tier, tagar_bem, tagar_sem, tagar_lem
            from bot_orders where customer_id = acc.id order by created_at desc limit 100) b;
    return v;
end; $$;

-- 9. ADMIN: pencarian tagar — bisa dibatasi jenis DAN proses ------------------
drop function if exists bot_search_tags(text, text, boolean, text);
create or replace function bot_search_tags(p_pin text, p_q text, p_bulk boolean default null, p_dashboard text default null, p_proses text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_q text; v_dash text := nullif(upper(trim(coalesce(p_dashboard, ''))), ''); v_pro text := nullif(upper(trim(coalesce(p_proses, ''))), ''); v jsonb;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    v_q := left(ltrim(trim(coalesce(p_q, '')), '#'), 60);
    if length(v_q) < 2 then return '[]'::jsonb; end if;
    v_q := '%' || replace(replace(replace(v_q, '\', '\\'), '%', '\%'), '_', '\_') || '%';
    select coalesce(jsonb_agg(jsonb_build_object('id', h.id, 'tagar', h.tagar) order by h.created_at desc), '[]'::jsonb) into v
      from (select r.id, r.created_at, r.tagar
              from (select b.id, b.created_at,
                           (select t from unnest(
                                case when b.dashboard <> 'BULK' then (case when v_dash is null or b.dashboard = v_dash then coalesce(b.tagar_list, '{}') else '{}' end)
                                     when v_dash = 'BEM' then coalesce(b.tagar_bem, '{}')
                                     when v_dash = 'SEM' then coalesce(b.tagar_sem, '{}')
                                     when v_dash = 'LEM' then coalesce(b.tagar_lem, '{}')
                                     else coalesce(b.tagar_bem, '{}') || coalesce(b.tagar_sem, '{}') || coalesce(b.tagar_lem, '{}') end) t
                             where t ilike v_q escape '\' limit 1) as tagar
                      from bot_orders b
                     where (p_bulk is null or (b.dashboard = 'BULK') = p_bulk)
                       and (v_dash is null or b.dashboard in (v_dash, 'BULK'))
                       and (v_pro is null or b.proses = v_pro)) r
             where r.tagar is not null
             order by r.created_at desc
             limit 50) h;
    return v;
end; $$;

grant execute on function bq_get(text), cu_my_bot_batches(uuid), bot_list(text), cu_my_bot_orders(uuid),
    bot_search_tags(text, text, boolean, text, text) to anon, authenticated;
-- Lanjutkan dengan migrations/009_bot_proses_total_bsl.sql
