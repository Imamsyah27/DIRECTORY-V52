-- =====================================================================
-- MIGRASI 007 — PROSES PENGIRIMAN BOT ORDER: 1F REQUEST / 2F REQUEST
-- Jalankan SEKALI di Supabase SQL Editor, SETELAH migrasi 001–006, lalu lanjutkan dengan 008. Aman diulang.
-- (bagian 1: kolom, pengaturan proses, harga custom, pemesanan)
--
-- 1 pesanan Bot Order = 1 proses (1F / 2F) + 1 jenis (BEM / SEM / LEM). Tidak bisa dicampur (dikunci di cu_request_bot_order).
--   * bot_orders.proses / bot_queue.proses : '1F' | '2F' | null (null = order lama sebelum fitur ini & Bulk Order)
--   * bot_packages : pengaturan proses (nama, notes/rules, aktif) + per kombinasi 1F/2F × BEM/SEM/LEM:
--                    harga per tagar dan saklar DIBUKA / DITUTUP (harga_bem + buka_bem, dst.)
--   * harga custom per pelanggan memakai price_item (cara koin-usdt-11/11b), kunci 'bot:1F:BEM' … 'bot:2F:LEM'
--   * batch tagar dihitung per kombinasi jenis + proses (BEM-1F, BEM-2F, …); order lama punya antrian sendiri per jenis
-- Data order lama TIDAK diubah (proses tetap kosong). Bulk Order tidak disentuh.
-- =====================================================================

-- 1. Kolom proses ----------------------------------------------------------
alter table bot_orders add column if not exists proses text;
alter table bot_queue  add column if not exists proses text;
do $$
begin
    if not exists (select 1 from pg_constraint where conname = 'bot_orders_proses_chk') then
        alter table bot_orders add constraint bot_orders_proses_chk check (proses is null or proses in ('1F', '2F'));
    end if;
    if not exists (select 1 from pg_constraint where conname = 'bot_queue_proses_chk') then
        alter table bot_queue add constraint bot_queue_proses_chk check (proses is null or proses in ('1F', '2F'));
    end if;
end $$;
create index if not exists bot_queue_pending_proses_idx on bot_queue (dashboard, proses, id) where status = 'pending';

-- 2. Pengaturan proses -----------------------------------------------------
create table if not exists bot_packages (
    proses text primary key check (proses in ('1F', '2F')),
    nama text not null,
    notes text not null default '',
    aktif boolean not null default false,
    harga_bem integer not null default 0 check (harga_bem between 0 and 100000000),
    harga_sem integer not null default 0 check (harga_sem between 0 and 100000000),
    harga_lem integer not null default 0 check (harga_lem between 0 and 100000000),
    buka_bem boolean not null default true,      -- pemesanan kombinasi proses + jenis dibuka / ditutup
    buka_sem boolean not null default true,
    buka_lem boolean not null default true,
    updated_at timestamptz not null default now()
);
alter table bot_packages add column if not exists buka_bem boolean not null default true;
alter table bot_packages add column if not exists buka_sem boolean not null default true;
alter table bot_packages add column if not exists buka_lem boolean not null default true;
insert into bot_packages (proses, nama) values ('1F', '1F Request'), ('2F', '2F Request') on conflict (proses) do nothing;
alter table bot_packages enable row level security;       -- tanpa policy publik: hanya lewat fungsi
do $$
begin
    if to_regproc('sync_bump_table()') is not null then      -- auto-refresh (migrasi 005): cache paket di browser diperbarui
        execute 'drop trigger if exists zz_sync_bump on public.bot_packages';
        execute 'create trigger zz_sync_bump after insert or update or delete on public.bot_packages for each statement execute function sync_bump_table()';
    end if;
end $$;

-- harga per kombinasi (tanpa harga custom)
create or replace function bot_pkg_price(p_proses text, p_dash text)
returns integer language sql stable security definer set search_path = public, extensions as $$
    select case upper(p_dash) when 'BEM' then harga_bem when 'SEM' then harga_sem when 'LEM' then harga_lem end
      from bot_packages where proses = upper(p_proses);
$$;
-- kombinasi bisa dipesan = proses aktif + kombinasi dibuka (+ harga > 0, dicek terpisah)
create or replace function bot_pkg_open(p_proses text, p_dash text)
returns boolean language sql stable security definer set search_path = public, extensions as $$
    select coalesce((select aktif and (case upper(p_dash) when 'BEM' then buka_bem when 'SEM' then buka_sem when 'LEM' then buka_lem else false end)
                       from bot_packages where proses = upper(p_proses)), false);
$$;
revoke all on function bot_pkg_price(text, text), bot_pkg_open(text, text) from public, anon, authenticated;

-- 3. Harga custom per pelanggan (price_item) ---------------------------------
do $$
declare c record;
begin
    for c in select conname from pg_constraint
              where conrelid = 'public.price_item'::regclass and contype = 'c' and pg_get_constraintdef(oid) ilike '%item_key%' loop
        execute format('alter table price_item drop constraint %I', c.conname);
    end loop;
    alter table price_item add constraint price_item_item_key_check check (
        item_key ~ '^(farm|hav|cat|pre):[0-9]+$' or item_key ~ '^sup:[0-9]+:(100|500|1000)$' or item_key ~ '^bot:(1F|2F):(BEM|SEM|LEM)$');
end $$;

-- daftar item di menu Custom Price / Harga Pelanggan (sama dengan koin-usdt-13 + Bot Order per proses)
create or replace function pi_catalog(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    return coalesce((select jsonb_agg(to_jsonb(r) order by r.ord, r.sub, r.nama) from (
        select ('bot:' || k.proses || ':' || d.dash)::text as key, 'Bot Order · Proses'::text as grup, '🤖'::text as ikon, 0 as ord, k.proses::text as sub,
               (k.nama || ' · ' || d.dash)::text as nama, bot_pkg_price(k.proses, d.dash)::bigint as harga, '/ tagar'::text as satuan
          from bot_packages k cross join (values ('BEM'), ('SEM'), ('LEM')) d(dash)
         where bot_pkg_price(k.proses, d.dash) > 0
        union all
        select ('farm:' || b.id)::text, 'Farm'::text, '🌱'::text, 1, ''::text, b.nama::text, b.harga_koin, '/ token'::text
          from farm_batches b where b.etalase and b.harga_koin > 0
        union all
        select 'hav:' || b.id, 'Hav Token', '🔑', 2, '', b.nama, b.harga_koin, '/ key' from hav_batches b where b.etalase and b.harga_koin > 0
        union all
        select 'sup:' || b.id || ':100', 'Product (Supply & Stock)', '📦', 3, b.nama, coalesce(nullif(b.item, ''), b.nama) || ' · 100 ' || b.satuan, b.price_100::bigint, 'total' from supply_batches b where b.visible and b.price_100 > 0
        union all
        select 'sup:' || b.id || ':500', 'Product (Supply & Stock)', '📦', 3, b.nama, coalesce(nullif(b.item, ''), b.nama) || ' · 500 ' || b.satuan, b.price_500::bigint, 'total' from supply_batches b where b.visible and b.price_500 > 0
        union all
        select 'sup:' || b.id || ':1000', 'Product (Supply & Stock)', '📦', 3, b.nama, coalesce(nullif(b.item, ''), b.nama) || ' · 1000 ' || b.satuan, b.price_1000::bigint, 'total' from supply_batches b where b.visible and b.price_1000 > 0
        union all
        select 'pre:' || p.id, 'Pre Order', '📝', 4, '', p.nama, p.harga_koin, '/ 10.000 barang' from preorder_items p where p.harga_koin > 0
        union all
        select 'cat:' || c.id, coalesce(k.nama, c.kategori), coalesce(k.ikon, '🛍'), 10 + coalesce(k.urut, 99), c.kategori, c.nama, c.harga_koin, '/ item'
          from catalog_items c left join catalog_categories k on k.slug = c.kategori where c.kategori <> 'farm' and c.harga_koin > 0
    ) r), '[]'::jsonb);
end; $$;

-- 4. ADMIN: pengaturan proses -----------------------------------------------
create or replace function bot_pkg_list(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    return coalesce((select jsonb_agg(jsonb_build_object('proses', proses, 'nama', nama, 'notes', notes, 'aktif', aktif,
                        'harga_bem', harga_bem, 'harga_sem', harga_sem, 'harga_lem', harga_lem,
                        'buka_bem', buka_bem, 'buka_sem', buka_sem, 'buka_lem', buka_lem, 'updated_at', updated_at) order by proses)
                       from bot_packages), '[]'::jsonb);
end; $$;

drop function if exists bot_pkg_save(text, text, text, text, boolean, integer, integer, integer);
create or replace function bot_pkg_save(p_pin text, p_proses text, p_nama text, p_notes text, p_aktif boolean,
                                        p_harga_bem integer, p_harga_sem integer, p_harga_lem integer,
                                        p_buka_bem boolean default true, p_buka_sem boolean default true, p_buka_lem boolean default true)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_pro text := upper(trim(coalesce(p_proses, ''))); v_nama text := left(trim(coalesce(p_nama, '')), 60);
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    if v_pro not in ('1F', '2F') then raise exception 'Proses harus 1F atau 2F'; end if;
    if v_nama = '' then raise exception 'Nama proses wajib diisi'; end if;
    if least(coalesce(p_harga_bem, 0), coalesce(p_harga_sem, 0), coalesce(p_harga_lem, 0)) < 0
       or greatest(coalesce(p_harga_bem, 0), coalesce(p_harga_sem, 0), coalesce(p_harga_lem, 0)) > 100000000 then
        raise exception 'Harga harus 0 – 100.000.000'; end if;
    if coalesce(p_aktif, false) and not (
           (coalesce(p_buka_bem, true) and coalesce(p_harga_bem, 0) > 0) or (coalesce(p_buka_sem, true) and coalesce(p_harga_sem, 0) > 0)
        or (coalesce(p_buka_lem, true) and coalesce(p_harga_lem, 0) > 0)) then
        raise exception 'Buka minimal satu jenis (BEM / SEM / LEM) dengan harga sebelum mengaktifkan proses'; end if;
    -- kombinasi yang dibuka tapi harganya 0 tetap tidak bisa dipesan (dianggap tutup)
    insert into bot_packages (proses, nama, notes, aktif, harga_bem, harga_sem, harga_lem, buka_bem, buka_sem, buka_lem, updated_at)
    values (v_pro, v_nama, left(coalesce(p_notes, ''), 2000), coalesce(p_aktif, false),
            coalesce(p_harga_bem, 0), coalesce(p_harga_sem, 0), coalesce(p_harga_lem, 0),
            coalesce(p_buka_bem, true), coalesce(p_buka_sem, true), coalesce(p_buka_lem, true), now())
    on conflict (proses) do update set nama = excluded.nama, notes = excluded.notes, aktif = excluded.aktif,
        harga_bem = excluded.harga_bem, harga_sem = excluded.harga_sem, harga_lem = excluded.harga_lem,
        buka_bem = excluded.buka_bem, buka_sem = excluded.buka_sem, buka_lem = excluded.buka_lem, updated_at = now();
end; $$;

-- 5. PELANGGAN: proses yang aktif + harga untuk pelanggan ini (Custom Price -> Harga Pelanggan -> harga proses)
create or replace function cu_bot_packages(p_session_token uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare acc customer_accounts%rowtype;
begin
    acc := portal_session_acc(p_session_token);
    return coalesce((select jsonb_agg(jsonb_build_object('proses', k.proses, 'nama', k.nama, 'notes', k.notes,
                        'harga', (select coalesce(jsonb_object_agg(d.dash, pi_final(acc.id, 'bot:' || k.proses || ':' || d.dash, bot_pkg_price(k.proses, d.dash))), '{}'::jsonb)
                                    from (values ('BEM'), ('SEM'), ('LEM')) d(dash) where bot_pkg_price(k.proses, d.dash) > 0 and bot_pkg_open(k.proses, d.dash)),
                        'normal', (select coalesce(jsonb_object_agg(d.dash, pi_normal(acc.id, 'bot:' || k.proses || ':' || d.dash, bot_pkg_price(k.proses, d.dash))), '{}'::jsonb)
                                    from (values ('BEM'), ('SEM'), ('LEM')) d(dash) where bot_pkg_price(k.proses, d.dash) > 0 and bot_pkg_open(k.proses, d.dash)))
                        order by k.proses)
                       from bot_packages k where k.aktif), '[]'::jsonb);
end; $$;

-- 6. PELANGGAN: pesan Bot Order = 1 proses + 1 jenis (versi lama tanpa proses dihapus) --------
drop function if exists cu_request_bot_order(uuid, text, text[], text);
create or replace function cu_request_bot_order(p_session_token uuid, p_dashboard text, p_tagar_list text[], p_catatan text default null, p_proses text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
    acc customer_accounts%rowtype; v_avail boolean; v_aktif boolean; v_nama text;
    v_dash text := upper(trim(coalesce(p_dashboard, '')));
    v_pro text := upper(trim(coalesce(p_proses, '')));
    v_list text[] := '{}'; v_norm text[] := '{}'; x text; n text;
    v_note text := nullif(left(trim(coalesce(p_catatan, '')), 500), '');
    v_harga bigint; v_id bigint; v_total bigint;
begin
    acc := portal_session_acc(p_session_token);
    if v_pro = '' then raise exception 'Pilih proses pengiriman'; end if;
    if v_pro not in ('1F', '2F') then raise exception 'Proses pengiriman tidak valid'; end if;
    if v_dash not in ('BEM', 'SEM', 'LEM') then raise exception 'Paket tidak valid'; end if;
    foreach x in array coalesce(p_tagar_list, '{}') loop
        x := trim(x);
        continue when x = '';
        if length(x) > 100 then raise exception 'Tagar maksimal 100 karakter'; end if;
        n := lower(replace(x, '#', ''));
        if not (n = any(v_norm)) then v_list := v_list || x; v_norm := v_norm || n; end if;
    end loop;
    if cardinality(v_list) = 0 then raise exception 'Tagar wajib diisi'; end if;
    if cardinality(v_list) > 500 then raise exception 'Maksimal 500 tagar per pesanan'; end if;

    select case v_dash when 'BEM' then avail_bot_bem when 'SEM' then avail_bot_sem else avail_bot_lem end into v_avail from price_settings where id = 1;
    if not coalesce(v_avail, true) then raise exception 'Bot Order % sedang tidak tersedia', v_dash; end if;
    select aktif, nama into v_aktif, v_nama from bot_packages where proses = v_pro;
    if not coalesce(v_aktif, false) then raise exception 'Proses pengiriman ini sedang tidak tersedia'; end if;
    if not bot_pkg_open(v_pro, v_dash) then raise exception 'Pemesanan proses dan jenis ini sedang ditutup'; end if;
    -- harga dihitung di server: Custom Price -> Harga Pelanggan -> harga proses (harga dari browser tidak dipakai)
    v_harga := pi_final(acc.id, 'bot:' || v_pro || ':' || v_dash, bot_pkg_price(v_pro, v_dash));
    if coalesce(v_harga, 0) <= 0 then raise exception 'Harga Bot Order belum diatur admin'; end if;
    v_total := v_harga * cardinality(v_list);

    insert into bot_orders (customer_id, username, dashboard, proses, tagar_list, jumlah, catatan_pelanggan, harga_tagar, total_harga, koin_dipotong)
    values (acc.id, acc.username, v_dash, v_pro, v_list, cardinality(v_list), v_note, v_harga, v_total, v_total)
    returning id into v_id;
    perform coin_apply(acc.id, -v_total, 'order', 'Bot Order ' || v_dash || ' · ' || v_nama || ' · ' || cardinality(v_list) || ' tagar', 'bot', v_id);
    return jsonb_build_object('id', v_id, 'status', 'pending', 'jumlah', cardinality(v_list), 'harga_tagar', v_harga, 'total', v_total, 'proses', v_pro);
end; $$;

grant execute on function bot_pkg_list(text), bot_pkg_save(text, text, text, text, boolean, integer, integer, integer, boolean, boolean, boolean),
    cu_bot_packages(uuid), cu_request_bot_order(uuid, text, text[], text, text), pi_catalog(text) to anon, authenticated;
-- Lanjutkan dengan migrations/008_bot_proses_batch.sql
