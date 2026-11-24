-- =====================================================================
-- MIGRASI 009 — PROSES 1F / 2F (bagian 3): total tagar per hari (kolom 1F / 2F), BSL Profit (keterangan + modal
-- khusus proses 1F / 2F per jenis di menu Modal), notifikasi Telegram. Jalankan SEKALI SETELAH migrations/008_bot_proses_batch.sql. Aman diulang.
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

-- 11. BSL Profit: keterangan Bot Order mencantumkan proses + modal khusus proses (sama dengan koin-usdt-23 selain itu) ----
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
        -- modal: modal khusus proses + jenis (mis. bsl:bot_1f_bem) bila diisi > 0, selain itu modal BEM / SEM / LEM Bot lama
        v_m := case when b.proses is not null then nullif(md_get('bsl:bot_' || lower(b.proses) || '_' || lower(b.dashboard)), 0) end;
        v_m := coalesce(v_m, md_get('bsl:bot_' || lower(case when b.dashboard in ('BEM', 'SEM') then b.dashboard else 'LEM' end)));
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

-- 13. MODAL khusus proses 1F / 2F per jenis (menu Modal -> grup "BSL · Bot Order Proses 1F / 2F") ------------
--     Kunci: bsl:bot_1f_bem … bsl:bot_2f_lem. Bila modal kombinasi = 0 / belum diisi, dipakai modal BEM / SEM / LEM Bot lama.
do $$
declare c record;
begin
    for c in select conname from pg_constraint
              where conrelid = 'public.modal_items'::regclass and contype = 'c' and pg_get_constraintdef(oid) ilike '%item_key%' loop
        execute format('alter table modal_items drop constraint %I', c.conname);
    end loop;
    alter table modal_items add constraint modal_items_item_key_check check (
        item_key ~ '^(farm|hav|cat|pre):[0-9]+$' or item_key ~ '^sup:[0-9]+:(100|500|1000)$'
        or item_key ~ '^bsl:(bem|sem|lem|bot_bem|bot_sem|bot_lem)$' or item_key ~ '^bsl:bot_(1f|2f)_(bem|sem|lem)$');
end $$;

-- daftar barang menu Modal (sama dengan koin-usdt-14 + 6 baris modal proses 1F / 2F)
create or replace function md_all_items()
returns table (key text, grup text, ikon text, ord integer, sub text, nama text, harga bigint, satuan text)
language sql stable security definer set search_path = public, extensions as $$
    select 'bsl:bem'::text, 'BSL · Langganan Harian'::text, '📈'::text, 0, ''::text, 'BEM'::text, coalesce((select bem from price_settings where id = 1), 0)::bigint, '/ tag / hari'::text
    union all select 'bsl:sem', 'BSL · Langganan Harian', '📈', 0, '', 'SEM', coalesce((select sem from price_settings where id = 1), 0)::bigint, '/ tag / hari'
    union all select 'bsl:lem', 'BSL · Langganan Harian', '📈', 0, '', 'LEM', coalesce((select lem from price_settings where id = 1), 0)::bigint, '/ tag / hari'
    union all select 'bsl:bot_bem', 'BSL · Bot Order', '🤖', 0, '', 'BEM Bot', coalesce((select bot_bem from price_settings where id = 1), 0)::bigint, '/ tagar'
    union all select 'bsl:bot_sem', 'BSL · Bot Order', '🤖', 0, '', 'SEM Bot', coalesce((select bot_sem from price_settings where id = 1), 0)::bigint, '/ tagar'
    union all select 'bsl:bot_lem', 'BSL · Bot Order', '🤖', 0, '', 'LEM Bot', coalesce((select bot_lem from price_settings where id = 1), 0)::bigint, '/ tagar'
    union all      -- modal khusus proses pengiriman 1F / 2F per jenis (migrasi 009); 0 = pakai modal BEM/SEM/LEM Bot di atas
    select 'bsl:bot_' || lower(k.proses) || '_' || lower(d.dash), 'BSL · Bot Order Proses 1F / 2F', '📨', 0, k.proses::text,
           (k.nama || ' · ' || d.dash)::text, coalesce(bot_pkg_price(k.proses, d.dash), 0)::bigint, '/ tagar'
      from bot_packages k cross join (values ('BEM'), ('SEM'), ('LEM')) d(dash)
    union all
    select 'farm:' || b.id, 'Farm', '🌱', 1, '', b.nama::text, b.harga_koin::bigint, '/ token' from farm_batches b where b.etalase
    union all
    select 'hav:' || b.id, 'Hav Token', '🔑', 2, '', b.nama::text, b.harga_koin::bigint, '/ key' from hav_batches b where b.etalase
    union all
    select 'sup:' || b.id || ':100', 'Product (Supply & Stock)', '📦', 3, b.nama::text, (coalesce(nullif(b.item, ''), b.nama) || ' · 100 ' || b.satuan)::text, b.price_100::bigint, 'total' from supply_batches b where b.visible and b.price_100 > 0
    union all
    select 'sup:' || b.id || ':500', 'Product (Supply & Stock)', '📦', 3, b.nama::text, (coalesce(nullif(b.item, ''), b.nama) || ' · 500 ' || b.satuan)::text, b.price_500::bigint, 'total' from supply_batches b where b.visible and b.price_500 > 0
    union all
    select 'sup:' || b.id || ':1000', 'Product (Supply & Stock)', '📦', 3, b.nama::text, (coalesce(nullif(b.item, ''), b.nama) || ' · 1000 ' || b.satuan)::text, b.price_1000::bigint, 'total' from supply_batches b where b.visible and b.price_1000 > 0
    union all
    select 'pre:' || p.id, 'Pre Order', '📝', 4, '', p.nama::text, p.harga_koin::bigint, '/ 10.000 barang' from preorder_items p
    union all
    select 'cat:' || c.id, coalesce(k.nama, c.kategori)::text, coalesce(k.ikon, '🛍')::text, 10 + coalesce(k.urut, 99), c.kategori::text, c.nama::text, c.harga_koin::bigint, '/ item'
      from catalog_items c left join catalog_categories k on k.slug = c.kategori where c.kategori <> 'farm';
$$;
revoke all on function md_all_items() from public, anon, authenticated;

-- simpan modal: menerima kunci proses 1F / 2F (sama dengan koin-usdt-14 selain pola kunci)
create or replace function md_save(p_pin text, p_items jsonb)
returns integer language plpgsql security definer set search_path = public, extensions as $$
declare r record; n integer := 0;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    for r in select key, value from jsonb_each_text(coalesce(p_items, '{}'::jsonb)) loop
        if not (r.key ~ '^(farm|hav|cat|pre):[0-9]+$' or r.key ~ '^sup:[0-9]+:(100|500|1000)$' or r.key ~ '^bsl:(bem|sem|lem|bot_bem|bot_sem|bot_lem)$' or r.key ~ '^bsl:bot_(1f|2f)_(bem|sem|lem)$') then
            raise exception 'Kode barang tidak valid: %', r.key; end if;
        if not (coalesce(r.value, '') ~ '^[0-9]{1,12}$') then raise exception 'Modal untuk % harus angka bulat >= 0', r.key; end if;
        insert into modal_items (item_key, modal, updated_at) values (r.key, r.value::bigint, now())
        on conflict (item_key) do update set modal = excluded.modal, updated_at = now();
        n := n + 1;
    end loop;
    return n;
end; $$;
grant execute on function md_save(text, jsonb) to anon, authenticated;

grant execute on function bot_daily_admin(text, integer), cu_bot_daily(uuid, integer), bot_approve(text, bigint) to anon, authenticated;
