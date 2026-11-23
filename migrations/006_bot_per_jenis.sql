-- =====================================================================
-- MIGRASI 006 — BOT ORDER PER JENIS (BEM / SEM / LEM) + SEARCH TAGAR PELANGGAN
-- Jalankan SEKALI di Supabase SQL Editor, SETELAH migrasi 001–005. Aman diulang.
--
-- TIDAK ADA kolom / tabel baru. Jenis pesanan sudah tersimpan:
--   bot_orders.dashboard  = 'BEM' | 'SEM' | 'LEM' (Bot Order) atau 'BULK' (tagar per jenis di tagar_bem / tagar_sem / tagar_lem)
--   bot_queue.dashboard   = jenis setiap tagar di antrian batch (tagar bulk sudah dipecah per jenis saat di-ACC)
-- Kolom dashboard wajib diisi (not null + check), jadi semua data lama otomatis masuk jenis yang benar.
-- File ini hanya menambah / memperbarui FUNGSI.
-- =====================================================================

-- 1. ADMIN: daftar Bot Order + jumlah tagar yang MASIH menunggu dikirim per jenis
--    (dipakai sub-tab BEM / SEM / LEM di tab Bulk Order). Kolom lain sama dengan versi koin-usdt-15.
create or replace function bot_list(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v jsonb;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    select coalesce(jsonb_agg(to_jsonb(r) order by r.created_at desc), '[]'::jsonb) into v
    from (select b.id, b.username, b.dashboard, b.jumlah, b.tagar_list[1] as tagar_pertama, b.catatan_pelanggan,
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

-- 2. ADMIN: tandai dikirim / batal kirim HANYA tagar satu jenis (mis. tagar BEM dari pesanan bulk).
--    Pesanan baru berstatus Terkirim setelah semua jenisnya terkirim (bq_sync).
create or replace function bot_set_dikirim_pkg(p_pin text, p_ids bigint[], p_dashboard text, p_dikirim boolean default true)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_dash text := upper(trim(coalesce(p_dashboard, ''))); v_id bigint; v_ok bigint[] := '{}'; v_fail jsonb := '[]'::jsonb;
        v_status text; v_arsip boolean; v_n integer;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    if v_dash not in ('BEM', 'SEM', 'LEM') then raise exception 'Jenis harus BEM, SEM, atau LEM'; end if;
    if coalesce(cardinality(p_ids), 0) = 0 then raise exception 'Tidak ada pesanan yang dipilih'; end if;
    if cardinality(p_ids) > 500 then raise exception 'Maksimal 500 pesanan sekali proses'; end if;
    foreach v_id in array p_ids loop
        begin
            select status, arsip into v_status, v_arsip from bot_orders where id = v_id for update;
            if not found then raise exception 'Pesanan tidak ditemukan'; end if;
            if v_status <> 'approved' then raise exception 'Hanya pesanan yang sudah disetujui'; end if;
            if v_arsip then raise exception 'Pesanan sudah diarsipkan'; end if;
            if coalesce(p_dikirim, true) then
                update bot_queue set status = 'sent', sent_at = now() where order_id = v_id and dashboard = v_dash and status = 'pending';
            else
                update bot_queue set status = 'pending', sent_at = null where order_id = v_id and dashboard = v_dash and status = 'sent';
            end if;
            get diagnostics v_n = row_count;
            if v_n = 0 then raise exception 'Tidak ada tagar % yang bisa diubah', v_dash; end if;
            perform bq_sync(array[v_id]);
            v_ok := v_ok || v_id;
        exception when others then
            v_fail := v_fail || jsonb_build_object('id', v_id, 'error', sqlerrm);
        end;
    end loop;
    return jsonb_build_object('ok', to_jsonb(v_ok), 'fail', v_fail);
end; $$;

-- 3. ADMIN: pencarian tagar, bisa dibatasi satu jenis (p_dashboard). Versi lama (3 parameter) dihapus
--    supaya tidak bentrok dengan versi baru.
drop function if exists bot_search_tags(text, text, boolean);
create or replace function bot_search_tags(p_pin text, p_q text, p_bulk boolean default null, p_dashboard text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_q text; v_dash text := nullif(upper(trim(coalesce(p_dashboard, ''))), ''); v jsonb;
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
                       and (v_dash is null or b.dashboard in (v_dash, 'BULK'))) r
             where r.tagar is not null
             order by r.created_at desc
             limit 50) h;
    return v;
end; $$;

-- 4. ADMIN: total tagar per hari per jenis (semua pelanggan). Pesanan ditolak / dibatalkan tidak dihitung.
create or replace function bot_daily_admin(p_pin text, p_days integer default 7)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_days integer; v_today date; v_from date;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    v_days := least(greatest(coalesce(p_days, 7), 1), 90);
    v_today := (now() at time zone 'Asia/Jakarta')::date;
    v_from := v_today - (v_days - 1);
    return coalesce((
        select jsonb_agg(jsonb_build_object('tanggal', d.tgl, 'pesanan', coalesce(s.pesanan, 0),
                    'bem', coalesce(s.bem, 0), 'sem', coalesce(s.sem, 0), 'lem', coalesce(s.lem, 0)) order by d.tgl desc)
          from (select g::date as tgl from generate_series(v_from, v_today, interval '1 day') g) d
          left join (
                select (b.created_at at time zone 'Asia/Jakarta')::date as tgl, count(*)::int as pesanan,
                       sum(case when b.dashboard = 'BEM' then b.jumlah when b.dashboard = 'BULK' then coalesce(cardinality(b.tagar_bem), 0) else 0 end)::int as bem,
                       sum(case when b.dashboard = 'SEM' then b.jumlah when b.dashboard = 'BULK' then coalesce(cardinality(b.tagar_sem), 0) else 0 end)::int as sem,
                       sum(case when b.dashboard = 'LEM' then b.jumlah when b.dashboard = 'BULK' then coalesce(cardinality(b.tagar_lem), 0) else 0 end)::int as lem
                  from bot_orders b
                 where b.status not in ('rejected', 'cancelled')
                   and b.created_at >= (v_from::timestamp at time zone 'Asia/Jakarta')
                 group by 1) s on s.tgl = d.tgl), '[]'::jsonb);
end; $$;
create index if not exists bot_orders_created_idx on bot_orders (created_at desc);

-- 5. PELANGGAN: total tagar per hari — kini juga per jenis (bem / sem / lem). Kolom lama (tagar, pesanan) tetap ada.
create or replace function cu_bot_daily(p_session_token uuid, p_days integer default 7)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare acc customer_accounts%rowtype; v_days integer; v_today date; v_from date;
begin
    acc := portal_session_acc(p_session_token);
    v_days := least(greatest(coalesce(p_days, 7), 1), 90);
    v_today := (now() at time zone 'Asia/Jakarta')::date;
    v_from := v_today - (v_days - 1);
    return coalesce((
        select jsonb_agg(jsonb_build_object('tanggal', d.tgl, 'pesanan', coalesce(s.pesanan, 0), 'tagar', coalesce(s.tagar, 0),
                    'bem', coalesce(s.bem, 0), 'sem', coalesce(s.sem, 0), 'lem', coalesce(s.lem, 0),
                    'p_bem', coalesce(s.p_bem, 0), 'p_sem', coalesce(s.p_sem, 0), 'p_lem', coalesce(s.p_lem, 0)) order by d.tgl desc)
          from (select g::date as tgl from generate_series(v_from, v_today, interval '1 day') g) d
          left join (
                select x.tgl, count(*)::int as pesanan, sum(x.bem + x.sem + x.lem)::int as tagar,
                       sum(x.bem)::int as bem, sum(x.sem)::int as sem, sum(x.lem)::int as lem,
                       count(*) filter (where x.bem > 0)::int as p_bem, count(*) filter (where x.sem > 0)::int as p_sem,
                       count(*) filter (where x.lem > 0)::int as p_lem
                  from (select (b.created_at at time zone 'Asia/Jakarta')::date as tgl,
                               case when b.dashboard = 'BEM' then b.jumlah when b.dashboard = 'BULK' then coalesce(cardinality(b.tagar_bem), 0) else 0 end as bem,
                               case when b.dashboard = 'SEM' then b.jumlah when b.dashboard = 'BULK' then coalesce(cardinality(b.tagar_sem), 0) else 0 end as sem,
                               case when b.dashboard = 'LEM' then b.jumlah when b.dashboard = 'BULK' then coalesce(cardinality(b.tagar_lem), 0) else 0 end as lem
                          from bot_orders b
                         where b.customer_id = acc.id
                           and b.status not in ('rejected', 'cancelled')
                           and b.created_at >= (v_from::timestamp at time zone 'Asia/Jakarta')) x
                 group by x.tgl) s on s.tgl = d.tgl), '[]'::jsonb);
end; $$;

-- 6. PELANGGAN: semua tagar MILIK SENDIRI untuk pencarian di browser (diambil 1x saat mulai mencari).
--    Sama dengan daftar Bot Order pelanggan: 100 pesanan terbaru. Hanya id + tagar per jenis.
create or replace function cu_my_bot_tags_all(p_session_token uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare acc customer_accounts%rowtype;
begin
    acc := portal_session_acc(p_session_token);
    return coalesce((
        select jsonb_agg(jsonb_build_object('id', b.id,
                    'bem', case when b.dashboard = 'BEM' then b.tagar_list when b.dashboard = 'BULK' then coalesce(b.tagar_bem, '{}') else '{}' end,
                    'sem', case when b.dashboard = 'SEM' then b.tagar_list when b.dashboard = 'BULK' then coalesce(b.tagar_sem, '{}') else '{}' end,
                    'lem', case when b.dashboard = 'LEM' then b.tagar_list when b.dashboard = 'BULK' then coalesce(b.tagar_lem, '{}') else '{}' end))
          from (select id, dashboard, tagar_list, tagar_bem, tagar_sem, tagar_lem
                  from bot_orders where customer_id = acc.id order by created_at desc limit 100) b), '[]'::jsonb);
end; $$;

grant execute on function bot_list(text), bot_set_dikirim_pkg(text, bigint[], text, boolean),
    bot_search_tags(text, text, boolean, text), bot_daily_admin(text, integer),
    cu_bot_daily(uuid, integer), cu_my_bot_tags_all(uuid) to anon, authenticated;
