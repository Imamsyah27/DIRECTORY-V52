-- =====================================================================
-- KOIN + USDT + KETERSEDIAAN — BAGIAN 1/8: Pengaturan (ketersediaan paket, USDT, harga pelanggan)
-- Jalankan BERURUTAN: bagian 1 s/d 8 (masing-masing sekali; aman diulang).
-- Dipecah karena SQL Editor Supabase memotong skrip di sekitar 20.000 karakter.
-- Isi: ON/OFF paket, kurs & harga USDT, daftar harga pelanggan tertentu.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1 & 2. Pengaturan: ketersediaan paket + kurs USDT
-- ---------------------------------------------------------------------
alter table price_settings add column if not exists avail_bem boolean not null default true;
alter table price_settings add column if not exists avail_sem boolean not null default true;
alter table price_settings add column if not exists avail_lem boolean not null default true;
alter table price_settings add column if not exists avail_bot_bem boolean not null default true;
alter table price_settings add column if not exists avail_bot_sem boolean not null default true;
alter table price_settings add column if not exists avail_bot_lem boolean not null default true;
alter table price_settings add column if not exists usdt_rate numeric(12, 2) not null default 0 check (usdt_rate >= 0);   -- Rp per 1 USDT (bar kurs)
alter table price_settings add column if not exists usdt_bem numeric(12, 4) not null default 0 check (usdt_bem >= 0);    -- harga pembanding / hari
alter table price_settings add column if not exists usdt_sem numeric(12, 4) not null default 0 check (usdt_sem >= 0);
alter table price_settings add column if not exists usdt_lem numeric(12, 4) not null default 0 check (usdt_lem >= 0);

create or replace function pr_save_avail(p_pin text, p_bem boolean, p_sem boolean, p_lem boolean,
                                         p_bot_bem boolean, p_bot_sem boolean, p_bot_lem boolean)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    update price_settings set avail_bem = coalesce(p_bem, true), avail_sem = coalesce(p_sem, true), avail_lem = coalesce(p_lem, true),
           avail_bot_bem = coalesce(p_bot_bem, true), avail_bot_sem = coalesce(p_bot_sem, true), avail_bot_lem = coalesce(p_bot_lem, true),
           updated_at = now() where id = 1;
end; $$;

-- Kurs (Rupiah per 1 USDT; 0 = bar kurs disembunyikan) + harga USDT per hari BEM/SEM/LEM (0 = tidak ditampilkan).
-- Hanya informasi pembanding: pembayaran tetap koin (Rupiah).
drop function if exists pr_save_usdt(text, numeric);   -- versi lama (hanya kurs)
create or replace function pr_save_usdt(p_pin text, p_rate numeric, p_bem numeric, p_sem numeric, p_lem numeric)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    if coalesce(p_rate, -1) < 0 or p_rate > 10000000 then raise exception 'Kurs USDT tidak valid'; end if;
    if least(coalesce(p_bem, -1), coalesce(p_sem, -1), coalesce(p_lem, -1)) < 0 or greatest(p_bem, p_sem, p_lem) > 1000000 then raise exception 'Harga USDT tidak valid'; end if;
    update price_settings set usdt_rate = p_rate, usdt_bem = p_bem, usdt_sem = p_sem, usdt_lem = p_lem, updated_at = now() where id = 1;
end; $$;

-- ---------------------------------------------------------------------
-- DAFTAR HARGA PELANGGAN TERTENTU (Rupiah + USDT). Rupiah = harga yang benar-benar dibayar (koin);
-- USDT = hanya pembanding yang tampil di Daftar Harga pelanggan itu.
-- ---------------------------------------------------------------------
alter table price_special add column if not exists usdt_bem numeric(12, 4) check (usdt_bem is null or usdt_bem >= 0);
alter table price_special add column if not exists usdt_sem numeric(12, 4) check (usdt_sem is null or usdt_sem >= 0);
alter table price_special add column if not exists usdt_lem numeric(12, 4) check (usdt_lem is null or usdt_lem >= 0);
-- harga BOT per tagar khusus pelanggan ini (kosong = ikut harga bot umum)
alter table price_special add column if not exists bot_bem integer check (bot_bem is null or bot_bem >= 0);
alter table price_special add column if not exists bot_sem integer check (bot_sem is null or bot_sem >= 0);
alter table price_special add column if not exists bot_lem integer check (bot_lem is null or bot_lem >= 0);

drop function if exists pr_special_save(text, bigint, integer, integer, integer, text);
drop function if exists pr_special_save(text, bigint, integer, integer, integer, text, numeric, numeric, numeric);
create or replace function pr_special_save(p_pin text, p_customer_id bigint, p_bem integer, p_sem integer, p_lem integer, p_catatan text,
                                           p_usdt_bem numeric default null, p_usdt_sem numeric default null, p_usdt_lem numeric default null,
                                           p_bot_bem integer default null, p_bot_sem integer default null, p_bot_lem integer default null)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    if not exists (select 1 from customer_accounts where id = p_customer_id) then raise exception 'Akun pelanggan tidak ditemukan'; end if;
    if greatest(coalesce(p_bem, 0), coalesce(p_sem, 0), coalesce(p_lem, 0)) > 100000000 or least(coalesce(p_bem, 0), coalesce(p_sem, 0), coalesce(p_lem, 0)) < 0 then raise exception 'Harga tidak valid'; end if;
    if greatest(coalesce(p_usdt_bem, 0), coalesce(p_usdt_sem, 0), coalesce(p_usdt_lem, 0)) > 1000000 or least(coalesce(p_usdt_bem, 0), coalesce(p_usdt_sem, 0), coalesce(p_usdt_lem, 0)) < 0 then raise exception 'Harga USDT tidak valid'; end if;
    if greatest(coalesce(p_bot_bem, 0), coalesce(p_bot_sem, 0), coalesce(p_bot_lem, 0)) > 100000000 or least(coalesce(p_bot_bem, 0), coalesce(p_bot_sem, 0), coalesce(p_bot_lem, 0)) < 0 then raise exception 'Harga bot tidak valid'; end if;
    insert into price_special (customer_id, bem, sem, lem, usdt_bem, usdt_sem, usdt_lem, bot_bem, bot_sem, bot_lem, catatan, updated_at)
    values (p_customer_id, nullif(p_bem, 0), nullif(p_sem, 0), nullif(p_lem, 0), nullif(p_usdt_bem, 0), nullif(p_usdt_sem, 0), nullif(p_usdt_lem, 0),
            nullif(p_bot_bem, 0), nullif(p_bot_sem, 0), nullif(p_bot_lem, 0), left(trim(coalesce(p_catatan, '')), 200), now())
    on conflict (customer_id) do update set bem = excluded.bem, sem = excluded.sem, lem = excluded.lem,
        usdt_bem = excluded.usdt_bem, usdt_sem = excluded.usdt_sem, usdt_lem = excluded.usdt_lem,
        bot_bem = excluded.bot_bem, bot_sem = excluded.bot_sem, bot_lem = excluded.bot_lem, catatan = excluded.catatan, updated_at = now();
end; $$;

create or replace function pr_special_list(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    return jsonb_build_object(
        'settings', (select to_jsonb(s) from price_settings s where s.id = 1),
        'special', coalesce((select jsonb_agg(jsonb_build_object('customer_id', sp.customer_id, 'username', ca.username,
                        'bem', sp.bem, 'sem', sp.sem, 'lem', sp.lem, 'usdt_bem', sp.usdt_bem, 'usdt_sem', sp.usdt_sem, 'usdt_lem', sp.usdt_lem,
                        'bot_bem', sp.bot_bem, 'bot_sem', sp.bot_sem, 'bot_lem', sp.bot_lem, 'catatan', sp.catatan) order by ca.username)
                      from price_special sp join customer_accounts ca on ca.id = sp.customer_id), '[]'::jsonb));
end; $$;

-- Penjaga di server: pesanan ke paket yang OFF ditolak (berlaku untuk pesan baru & perpanjang)
create or replace function renewal_avail_guard()
returns trigger language plpgsql security definer set search_path = public, extensions as $$
declare s price_settings%rowtype; v text := upper(coalesce(new.dashboard_baru, ''));
begin
    select * into s from price_settings where id = 1;
    if not (case v when 'BEM' then s.avail_bem when 'SEM' then s.avail_sem else s.avail_lem end) then
        raise exception 'Paket % sedang tidak tersedia', v;
    end if;
    return new;
end; $$;
drop trigger if exists renewal_avail_guard_trg on renewal_requests;
create trigger renewal_avail_guard_trg before insert on renewal_requests for each row execute function renewal_avail_guard();

-- cu_price_info: harga yang DILIHAT pelanggan. Urutan prioritas tiap paket:
--   Custom Price (tersembunyi, tampil sebagai harga biasa) > Harga Pelanggan/istimewa (normal dicoret) > harga umum.
-- Untuk paket yang kena Custom Price, harga pembanding USDT umum DISEMBUNYIKAN (supaya harga asli tidak terlihat).
create or replace function cu_price_info(p_session_token uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare acc customer_accounts%rowtype; v jsonb := '{}'::jsonb; p text; q jsonb; s price_settings%rowtype;
        sp price_special%rowtype; cp price_custom%rowtype;
begin
    acc := portal_session_acc(p_session_token);
    select * into sp from price_special where customer_id = acc.id;
    select * into cp from price_custom where customer_id = acc.id;
    foreach p in array array['BEM', 'SEM', 'LEM'] loop
        q := price_calc(acc.id, p, 1, 1, null);
        v := v || jsonb_build_object(p, jsonb_build_object('normal', q->'normal_hari', 'final', q->'harga_hari', 'jenis', q->'jenis',
                                                            'label', q->'diskon_label', 'persen', q->'diskon_persen'));
    end loop;
    select * into s from price_settings where id = 1;
    return v || jsonb_build_object(
        'istimewa', exists (select 1 from price_special where customer_id = acc.id),
        'bot', jsonb_build_object(
            'BEM', coalesce(nullif(cp.bot_bem, 0), nullif(sp.bot_bem, 0), s.bot_bem),
            'SEM', coalesce(nullif(cp.bot_sem, 0), nullif(sp.bot_sem, 0), s.bot_sem),
            'LEM', coalesce(nullif(cp.bot_lem, 0), nullif(sp.bot_lem, 0), s.bot_lem)),
        'bot_normal', jsonb_build_object(
            'BEM', coalesce(nullif(cp.bot_bem, 0), s.bot_bem), 'SEM', coalesce(nullif(cp.bot_sem, 0), s.bot_sem), 'LEM', coalesce(nullif(cp.bot_lem, 0), s.bot_lem)),
        'avail', jsonb_build_object('BEM', s.avail_bem, 'SEM', s.avail_sem, 'LEM', s.avail_lem,
                                    'BOT_BEM', s.avail_bot_bem, 'BOT_SEM', s.avail_bot_sem, 'BOT_LEM', s.avail_bot_lem),
        'usdt_rate', s.usdt_rate,
        'usdt', jsonb_build_object(
            'BEM', case when nullif(cp.bem, 0) is not null then coalesce(nullif(cp.usdt_bem, 0), 0) else coalesce(nullif(sp.usdt_bem, 0), s.usdt_bem) end,
            'SEM', case when nullif(cp.sem, 0) is not null then coalesce(nullif(cp.usdt_sem, 0), 0) else coalesce(nullif(sp.usdt_sem, 0), s.usdt_sem) end,
            'LEM', case when nullif(cp.lem, 0) is not null then coalesce(nullif(cp.usdt_lem, 0), 0) else coalesce(nullif(sp.usdt_lem, 0), s.usdt_lem) end));
end; $$;

-- ---------------------------------------------------------------------
-- CUSTOM PRICE (menu SETTING): harga TERSEMBUNYI per akun, biasanya lebih mahal dari harga umum.
-- Pelanggan melihatnya sebagai harga biasa (tidak ada coretan / label). Beda dengan "Harga Pelanggan"
-- (harga istimewa yang tampil dengan harga normal dicoret). Custom Price menang atas semuanya.
-- ---------------------------------------------------------------------
create table if not exists price_custom (
    customer_id bigint primary key references customer_accounts(id) on delete cascade,
    bem integer check (bem is null or bem >= 0), sem integer check (sem is null or sem >= 0), lem integer check (lem is null or lem >= 0),
    bot_bem integer check (bot_bem is null or bot_bem >= 0), bot_sem integer check (bot_sem is null or bot_sem >= 0), bot_lem integer check (bot_lem is null or bot_lem >= 0),
    usdt_bem numeric(12, 4) check (usdt_bem is null or usdt_bem >= 0), usdt_sem numeric(12, 4) check (usdt_sem is null or usdt_sem >= 0), usdt_lem numeric(12, 4) check (usdt_lem is null or usdt_lem >= 0),
    catatan text not null default '',
    updated_at timestamptz not null default now()
);
alter table price_custom enable row level security;      -- tanpa policy publik: pelanggan tidak bisa membaca tabel ini

create or replace function cp_save(p_pin text, p_customer_id bigint,
    p_bem integer, p_sem integer, p_lem integer, p_bot_bem integer, p_bot_sem integer, p_bot_lem integer,
    p_usdt_bem numeric, p_usdt_sem numeric, p_usdt_lem numeric, p_catatan text default null)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    if not exists (select 1 from customer_accounts where id = p_customer_id) then raise exception 'Akun pelanggan tidak ditemukan'; end if;
    if least(coalesce(p_bem, 0), coalesce(p_sem, 0), coalesce(p_lem, 0), coalesce(p_bot_bem, 0), coalesce(p_bot_sem, 0), coalesce(p_bot_lem, 0)) < 0
       or greatest(coalesce(p_bem, 0), coalesce(p_sem, 0), coalesce(p_lem, 0), coalesce(p_bot_bem, 0), coalesce(p_bot_sem, 0), coalesce(p_bot_lem, 0)) > 100000000 then
        raise exception 'Harga tidak valid'; end if;
    if least(coalesce(p_usdt_bem, 0), coalesce(p_usdt_sem, 0), coalesce(p_usdt_lem, 0)) < 0
       or greatest(coalesce(p_usdt_bem, 0), coalesce(p_usdt_sem, 0), coalesce(p_usdt_lem, 0)) > 1000000 then
        raise exception 'Harga USDT tidak valid'; end if;
    if coalesce(p_bem, 0) + coalesce(p_sem, 0) + coalesce(p_lem, 0) + coalesce(p_bot_bem, 0) + coalesce(p_bot_sem, 0) + coalesce(p_bot_lem, 0) = 0 then
        delete from price_custom where customer_id = p_customer_id; return;       -- semua kosong = hapus custom price akun ini
    end if;
    insert into price_custom (customer_id, bem, sem, lem, bot_bem, bot_sem, bot_lem, usdt_bem, usdt_sem, usdt_lem, catatan, updated_at)
    values (p_customer_id, nullif(p_bem, 0), nullif(p_sem, 0), nullif(p_lem, 0), nullif(p_bot_bem, 0), nullif(p_bot_sem, 0), nullif(p_bot_lem, 0),
            nullif(p_usdt_bem, 0), nullif(p_usdt_sem, 0), nullif(p_usdt_lem, 0), left(trim(coalesce(p_catatan, '')), 200), now())
    on conflict (customer_id) do update set bem = excluded.bem, sem = excluded.sem, lem = excluded.lem,
        bot_bem = excluded.bot_bem, bot_sem = excluded.bot_sem, bot_lem = excluded.bot_lem,
        usdt_bem = excluded.usdt_bem, usdt_sem = excluded.usdt_sem, usdt_lem = excluded.usdt_lem, catatan = excluded.catatan, updated_at = now();
end; $$;

create or replace function cp_list(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    return jsonb_build_object(
        'settings', (select to_jsonb(s) from price_settings s where s.id = 1),
        'custom', coalesce((select jsonb_agg(jsonb_build_object('customer_id', c.customer_id, 'username', ca.username,
                        'bem', c.bem, 'sem', c.sem, 'lem', c.lem, 'bot_bem', c.bot_bem, 'bot_sem', c.bot_sem, 'bot_lem', c.bot_lem,
                        'usdt_bem', c.usdt_bem, 'usdt_sem', c.usdt_sem, 'usdt_lem', c.usdt_lem, 'catatan', c.catatan) order by ca.username)
                      from price_custom c join customer_accounts ca on ca.id = c.customer_id), '[]'::jsonb));
end; $$;

create or replace function cp_delete(p_pin text, p_customer_id bigint)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    delete from price_custom where customer_id = p_customer_id;
end; $$;

grant execute on function
    pr_save_avail(text, boolean, boolean, boolean, boolean, boolean, boolean), pr_save_usdt(text, numeric, numeric, numeric, numeric),
    pr_special_save(text, bigint, integer, integer, integer, text, numeric, numeric, numeric, integer, integer, integer), pr_special_list(text), cu_price_info(uuid),
    cp_save(text, bigint, integer, integer, integer, integer, integer, integer, numeric, numeric, numeric, text), cp_list(text), cp_delete(text, bigint)
to anon, authenticated;
