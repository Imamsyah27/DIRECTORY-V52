-- =====================================================================
-- MIGRASI 009 — PROSES 1F / 2F (bagian 3): total tagar per hari (kolom 1F / 2F), keterangan BSL Profit,
-- notifikasi Telegram. Jalankan SEKALI SETELAH migrations/008_bot_proses_batch.sql. Aman diulang.
-- =====================================================================

-- 10. Total tagar per hari: tambah kolom 1F / 2F -------------------------------
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
                    'bem', coalesce(s.bem, 0), 'sem', coalesce(s.sem, 0), 'lem', coalesce(s.lem, 0),
                    '1f', coalesce(s.f1, 0), '2f', coalesce(s.f2, 0)) order by d.tgl desc)
          from (select g::date as tgl from generate_series(v_from, v_today, interval '1 day') g) d
          left join (
                select (b.created_at at time zone 'Asia/Jakarta')::date as tgl, count(*)::int as pesanan,
                       sum(case when b.dashboard = 'BEM' then b.jumlah when b.dashboard = 'BULK' then coalesce(cardinality(b.tagar_bem), 0) else 0 end)::int as bem,
                       sum(case when b.dashboard = 'SEM' then b.jumlah when b.dashboard = 'BULK' then coalesce(cardinality(b.tagar_sem), 0) else 0 end)::int as sem,
                       sum(case when b.dashboard = 'LEM' then b.jumlah when b.dashboard = 'BULK' then coalesce(cardinality(b.tagar_lem), 0) else 0 end)::int as lem,
                       sum(case when b.proses = '1F' then b.jumlah else 0 end)::int as f1,
                       sum(case when b.proses = '2F' then b.jumlah else 0 end)::int as f2
                  from bot_orders b
                 where b.status not in ('rejected', 'cancelled')
                   and b.created_at >= (v_from::timestamp at time zone 'Asia/Jakarta')
                 group by 1) s on s.tgl = d.tgl), '[]'::jsonb);
end; $$;

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
                    'p_bem', coalesce(s.p_bem, 0), 'p_sem', coalesce(s.p_sem, 0), 'p_lem', coalesce(s.p_lem, 0),
                    '1f', coalesce(s.f1, 0), '2f', coalesce(s.f2, 0), 'p_1f', coalesce(s.p_f1, 0), 'p_2f', coalesce(s.p_f2, 0)) order by d.tgl desc)
          from (select g::date as tgl from generate_series(v_from, v_today, interval '1 day') g) d
          left join (
                select x.tgl, count(*)::int as pesanan, sum(x.bem + x.sem + x.lem)::int as tagar,
                       sum(x.bem)::int as bem, sum(x.sem)::int as sem, sum(x.lem)::int as lem,
                       count(*) filter (where x.bem > 0)::int as p_bem, count(*) filter (where x.sem > 0)::int as p_sem,
                       count(*) filter (where x.lem > 0)::int as p_lem,
                       sum(case when x.proses = '1F' then x.bem + x.sem + x.lem else 0 end)::int as f1,
                       sum(case when x.proses = '2F' then x.bem + x.sem + x.lem else 0 end)::int as f2,
                       count(*) filter (where x.proses = '1F')::int as p_f1, count(*) filter (where x.proses = '2F')::int as p_f2
                  from (select (b.created_at at time zone 'Asia/Jakarta')::date as tgl, b.proses,
                               case when b.dashboard = 'BEM' then b.jumlah when b.dashboard = 'BULK' then coalesce(cardinality(b.tagar_bem), 0) else 0 end as bem,
                               case when b.dashboard = 'SEM' then b.jumlah when b.dashboard = 'BULK' then coalesce(cardinality(b.tagar_sem), 0) else 0 end as sem,
                               case when b.dashboard = 'LEM' then b.jumlah when b.dashboard = 'BULK' then coalesce(cardinality(b.tagar_lem), 0) else 0 end as lem
                          from bot_orders b
                         where b.customer_id = acc.id
                           and b.status not in ('rejected', 'cancelled')
                           and b.created_at >= (v_from::timestamp at time zone 'Asia/Jakarta')) x
                 group by x.tgl) s on s.tgl = d.tgl), '[]'::jsonb);
end; $$;

-- 11. BSL Profit: keterangan Bot Order mencantumkan proses (sama dengan koin-usdt-23 selain keterangan) ----
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
        values ((now() at time zone 'Asia/Jakarta')::date, 'bot', b.dashboard || ' Bot', b.username,
                'Bot Order #' || b.id || coalesce(' · ' || b.proses, ''), null, b.jumlah, b.harga_tagar, v_m, b.total_harga, v_modal, b.id)
        on conflict (bot_order_id) where bot_order_id is not null do nothing;
    end if;

    update bot_orders set status = 'approved', processed_at = now() where id = b.id;
    perform bq_enqueue(b.id);        -- tagar masuk antrian batch (mewarisi proses)
    return jsonb_build_object('id', b.id, 'omset', b.total_harga, 'modal', v_modal, 'profit', b.total_harga - v_modal);
end; $$;

-- 12. Notifikasi Telegram (bila koin-usdt-24b sudah dijalankan): judul menyebut proses ---------
create or replace function tg_trg_bot() returns trigger language plpgsql security definer set search_path = public, extensions as $$
begin
    begin
        perform tg_send(case when new.dashboard = 'BULK' then 'bulk' else 'bot' end, concat_ws(E'\n',
            '🔔 <b>ORDER MASUK — ' || case when new.dashboard = 'BULK' then 'Bulk Order' else 'Bot ' || new.dashboard || coalesce(' · ' || new.proses || ' Request', '') end || '</b>',
            '👤 ' || tg_esc(new.username),
            case when new.dashboard = 'BULK'
                 then '📦 BEM ' || coalesce(cardinality(new.tagar_bem), 0) || ' · SEM ' || coalesce(cardinality(new.tagar_sem), 0) || ' · LEM ' || coalesce(cardinality(new.tagar_lem), 0) || ' (' || new.jumlah || ' tagar)'
                 else '📦 ' || new.jumlah || ' tagar' end,
            '🏷 ' || tg_esc(tg_tags(new.tagar_list)),
            '💰 ' || tg_rp(new.total_harga),
            case when coalesce(new.catatan_pelanggan, '') <> '' then '📝 ' || tg_esc(left(new.catatan_pelanggan, 200)) end,
            '🕒 ' || tg_now() || ' · #' || new.id));
    exception when others then null; end;
    return null;
end; $$;

grant execute on function bot_daily_admin(text, integer), cu_bot_daily(uuid, integer), bot_approve(text, bigint) to anon, authenticated;
