-- CATATAN: jika SQL Editor error "unterminated dollar-quoted string" (teks terpotong), pakai price-1.sql s/d price-4.sql (isinya sama).
-- =====================================================================
-- PRICE: harga paket BEM / SEM / LEM per hari, harga pelanggan istimewa,
--        diskon semua pelanggan, dan kode referal (batas pemakaian).
--
-- Jalankan SELURUH file ini SEKALI di Supabase SQL Editor.
-- Urutan: setelah customer_portal_fixed.sql, supply.sql, perpanjang.sql,
--         katalog-pesan-baru.sql dan pesan-baru-multi-tagar.sql. Aman dijalankan ulang.
--
-- Aturan harga (dihitung di SERVER, tidak bisa diubah dari browser):
--   1. Pelanggan istimewa  -> pakai harga istimewa (jika diisi untuk paket itu), dan TIDAK kena diskon umum.
--   2. Pelanggan biasa     -> harga default, dikurangi diskon umum bila aktif.
--   3. Kode referal        -> potongan tambahan atas total (berlaku untuk semua pelanggan, paket BEM/SEM/LEM).
--   Total = harga per hari x jumlah hari x jumlah tagar - potongan referal.
-- =====================================================================

create table if not exists price_settings (
    id integer primary key default 1 check (id = 1),
    bem integer not null default 0 check (bem >= 0),
    sem integer not null default 0 check (sem >= 0),
    lem integer not null default 0 check (lem >= 0),
    diskon_aktif boolean not null default false,
    diskon_persen integer not null default 0 check (diskon_persen between 0 and 100),
    diskon_label text not null default '',
    diskon_bem boolean not null default true,
    diskon_sem boolean not null default true,
    diskon_lem boolean not null default true,
    updated_at timestamptz not null default now()
);
insert into price_settings (id) values (1) on conflict (id) do nothing;

create table if not exists price_special (
    customer_id bigint primary key references customer_accounts(id) on delete cascade,
    bem integer check (bem is null or bem >= 0),
    sem integer check (sem is null or sem >= 0),
    lem integer check (lem is null or lem >= 0),
    catatan text not null default '',
    updated_at timestamptz not null default now()
);

create table if not exists referral_codes (
    id bigint generated always as identity primary key,
    kode text not null,
    tipe text not null check (tipe in ('persen', 'nominal')),
    nilai integer not null check (nilai > 0),
    max_uses integer not null check (max_uses > 0),
    used_count integer not null default 0 check (used_count >= 0),
    aktif boolean not null default true,
    expires_at timestamptz,
    created_at timestamptz not null default now()
);
create unique index if not exists referral_codes_kode_uidx on referral_codes (upper(kode));

alter table price_settings enable row level security;
alter table price_special enable row level security;
alter table referral_codes enable row level security;     -- tanpa policy publik

-- jejak harga pada tiap permintaan (dihitung otomatis oleh trigger)
alter table renewal_requests add column if not exists tagar_list text[];
alter table renewal_requests add column if not exists catatan_pelanggan text;
alter table renewal_requests add column if not exists harga_normal_hari integer;
alter table renewal_requests add column if not exists harga_hari integer;
alter table renewal_requests add column if not exists jumlah_item integer;
alter table renewal_requests add column if not exists kode_referal text;
alter table renewal_requests add column if not exists diskon_referral integer not null default 0;
alter table renewal_requests add column if not exists total_harga integer;

-- ---------------------------------------------------------------------
-- Mesin hitung harga (internal, tidak dibuka ke publik)
-- ---------------------------------------------------------------------
create or replace function price_calc(p_customer_id bigint, p_dashboard text, p_hari integer, p_jumlah integer, p_kode text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
    s price_settings%rowtype; sp price_special%rowtype; rc referral_codes%rowtype;
    v_dash text := upper(coalesce(p_dashboard, ''));
    v_istimewa boolean; v_normal integer; v_hari_price integer; v_special integer; v_jenis text;
    v_sub bigint; v_ref bigint := 0; v_kode text := nullif(upper(trim(coalesce(p_kode, ''))), '');
    v_kode_ok boolean; v_msg text; v_pakai_diskon boolean;
begin
    select * into s from price_settings where id = 1;
    v_normal := case v_dash when 'BEM' then s.bem when 'SEM' then s.sem else s.lem end;
    v_hari_price := v_normal;

    select * into sp from price_special where customer_id = p_customer_id;
    v_istimewa := found;

    if v_istimewa then
        v_special := case v_dash when 'BEM' then sp.bem when 'SEM' then sp.sem else sp.lem end;
        if v_special is not null then v_hari_price := v_special; v_jenis := 'istimewa'; end if;
        -- pelanggan istimewa TIDAK mendapat diskon umum
    else
        v_pakai_diskon := s.diskon_aktif and s.diskon_persen > 0
                          and (case v_dash when 'BEM' then s.diskon_bem when 'SEM' then s.diskon_sem else s.diskon_lem end);
        if v_pakai_diskon then
            v_hari_price := round(v_normal * (100 - s.diskon_persen) / 100.0)::integer;
            v_jenis := 'diskon';
        end if;
    end if;

    v_sub := v_hari_price::bigint * greatest(coalesce(p_hari, 0), 0) * greatest(coalesce(p_jumlah, 1), 1);

    if v_kode is not null then
        select * into rc from referral_codes where upper(kode) = v_kode;
        if not found then v_kode_ok := false; v_msg := 'Kode referal tidak ditemukan';
        elsif not rc.aktif then v_kode_ok := false; v_msg := 'Kode referal tidak aktif';
        elsif rc.expires_at is not null and rc.expires_at < now() then v_kode_ok := false; v_msg := 'Kode referal sudah kedaluwarsa';
        elsif rc.used_count >= rc.max_uses then v_kode_ok := false; v_msg := 'Kode referal sudah habis dipakai';
        else
            v_kode_ok := true;
            v_ref := case rc.tipe when 'persen' then floor(v_sub * rc.nilai / 100.0) else least(rc.nilai::bigint, v_sub) end;
        end if;
    end if;

    return jsonb_build_object(
        'dashboard', v_dash, 'hari', p_hari, 'jumlah', p_jumlah,
        'normal_hari', v_normal, 'harga_hari', v_hari_price, 'jenis', v_jenis, 'istimewa', v_istimewa,
        'diskon_label', case when v_jenis = 'diskon' then s.diskon_label end, 'diskon_persen', case when v_jenis = 'diskon' then s.diskon_persen end,
        'subtotal', v_sub, 'referral', v_ref, 'kode', v_kode, 'kode_ok', v_kode_ok, 'kode_pesan', v_msg,
        'kode_tipe', rc.tipe, 'kode_nilai', rc.nilai,
        'total', greatest(v_sub - v_ref, 0)
    );
end; $$;
revoke all on function price_calc(bigint, text, integer, integer, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Trigger: harga & pemakaian kode referal tercatat otomatis saat permintaan dibuat
-- ---------------------------------------------------------------------
create or replace function renewal_price_fill()
returns trigger language plpgsql security definer set search_path = public, extensions as $$
declare q jsonb; v_jumlah integer; v_kode text := nullif(upper(trim(coalesce(new.kode_referal, ''))), '');
begin
    v_jumlah := coalesce(cardinality(new.tagar_list), 1);
    q := price_calc(new.customer_id, new.dashboard_baru, new.hari, v_jumlah, v_kode);
    if v_kode is not null then
        if not coalesce((q->>'kode_ok')::boolean, false) then raise exception '%', coalesce(q->>'kode_pesan', 'Kode referal tidak valid'); end if;
        update referral_codes set used_count = used_count + 1
         where upper(kode) = v_kode and aktif and used_count < max_uses and (expires_at is null or expires_at >= now());
        if not found then raise exception 'Kode referal sudah habis dipakai'; end if;
    end if;
    new.harga_normal_hari := (q->>'normal_hari')::integer;
    new.harga_hari := (q->>'harga_hari')::integer;
    new.jumlah_item := v_jumlah;
    new.kode_referal := v_kode;
    new.diskon_referral := (q->>'referral')::integer;
    new.total_harga := (q->>'total')::integer;
    return new;
end; $$;
drop trigger if exists renewal_price_fill_trg on renewal_requests;
create trigger renewal_price_fill_trg before insert on renewal_requests for each row execute function renewal_price_fill();

-- Permintaan dibatalkan pelanggan / ditolak admin -> jatah kode referal dikembalikan
create or replace function renewal_referral_release()
returns trigger language plpgsql security definer set search_path = public, extensions as $$
begin
    if tg_op = 'DELETE' then
        if old.status = 'pending' and old.kode_referal is not null then
            update referral_codes set used_count = greatest(used_count - 1, 0) where upper(kode) = upper(old.kode_referal);
        end if;
        return old;
    end if;
    if old.status = 'pending' and new.status = 'rejected' and old.kode_referal is not null then
        update referral_codes set used_count = greatest(used_count - 1, 0) where upper(kode) = upper(old.kode_referal);
    end if;
    return new;
end; $$;
drop trigger if exists renewal_referral_release_del on renewal_requests;
create trigger renewal_referral_release_del after delete on renewal_requests for each row execute function renewal_referral_release();
drop trigger if exists renewal_referral_release_upd on renewal_requests;
create trigger renewal_referral_release_upd after update of status on renewal_requests for each row execute function renewal_referral_release();

-- ---------------------------------------------------------------------
-- ADMIN (PIN)
-- ---------------------------------------------------------------------
create or replace function pr_get(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    return jsonb_build_object(
        'settings', (select to_jsonb(s) from price_settings s where s.id = 1),
        'special', coalesce((select jsonb_agg(jsonb_build_object('customer_id', sp.customer_id, 'username', ca.username,
                        'bem', sp.bem, 'sem', sp.sem, 'lem', sp.lem, 'catatan', sp.catatan) order by ca.username)
                      from price_special sp join customer_accounts ca on ca.id = sp.customer_id), '[]'::jsonb),
        'codes', coalesce((select jsonb_agg(to_jsonb(c) order by c.id desc) from referral_codes c), '[]'::jsonb)
    );
end; $$;

create or replace function pr_save_default(p_pin text, p_bem integer, p_sem integer, p_lem integer)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    if least(coalesce(p_bem, -1), coalesce(p_sem, -1), coalesce(p_lem, -1)) < 0 then raise exception 'Harga tidak boleh kosong atau negatif'; end if;
    if greatest(p_bem, p_sem, p_lem) > 100000000 then raise exception 'Harga terlalu besar'; end if;
    update price_settings set bem = p_bem, sem = p_sem, lem = p_lem, updated_at = now() where id = 1;
end; $$;

create or replace function pr_save_diskon(p_pin text, p_aktif boolean, p_persen integer, p_label text, p_bem boolean, p_sem boolean, p_lem boolean)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    if p_persen is null or p_persen < 0 or p_persen > 100 then raise exception 'Persen diskon harus 0 sampai 100'; end if;
    update price_settings set diskon_aktif = coalesce(p_aktif, false), diskon_persen = p_persen, diskon_label = left(trim(coalesce(p_label, '')), 60),
           diskon_bem = coalesce(p_bem, true), diskon_sem = coalesce(p_sem, true), diskon_lem = coalesce(p_lem, true), updated_at = now() where id = 1;
end; $$;

-- harga kosong / 0 = pakai harga default untuk paket itu (tetap tercatat sebagai pelanggan istimewa)
create or replace function pr_special_save(p_pin text, p_customer_id bigint, p_bem integer, p_sem integer, p_lem integer, p_catatan text)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    if not exists (select 1 from customer_accounts where id = p_customer_id) then raise exception 'Akun pelanggan tidak ditemukan'; end if;
    if greatest(coalesce(p_bem, 0), coalesce(p_sem, 0), coalesce(p_lem, 0)) > 100000000 or least(coalesce(p_bem, 0), coalesce(p_sem, 0), coalesce(p_lem, 0)) < 0 then raise exception 'Harga tidak valid'; end if;
    insert into price_special (customer_id, bem, sem, lem, catatan, updated_at)
    values (p_customer_id, nullif(p_bem, 0), nullif(p_sem, 0), nullif(p_lem, 0), left(trim(coalesce(p_catatan, '')), 200), now())
    on conflict (customer_id) do update set bem = excluded.bem, sem = excluded.sem, lem = excluded.lem, catatan = excluded.catatan, updated_at = now();
end; $$;

create or replace function pr_special_delete(p_pin text, p_customer_id bigint)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    delete from price_special where customer_id = p_customer_id;
end; $$;

create or replace function pr_code_save(p_pin text, p_id bigint, p_kode text, p_tipe text, p_nilai integer, p_max_uses integer, p_aktif boolean, p_expires timestamptz)
returns bigint language plpgsql security definer set search_path = public, extensions as $$
declare v_kode text := upper(trim(coalesce(p_kode, ''))); v_id bigint;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    if v_kode !~ '^[A-Z0-9_-]{3,32}$' then raise exception 'Kode referal 3-32 karakter: huruf, angka, - atau _'; end if;
    if p_tipe not in ('persen', 'nominal') then raise exception 'Jenis potongan tidak valid'; end if;
    if p_nilai is null or p_nilai < 1 then raise exception 'Nilai potongan minimal 1'; end if;
    if p_tipe = 'persen' and p_nilai > 100 then raise exception 'Potongan persen maksimal 100'; end if;
    if p_max_uses is null or p_max_uses < 1 then raise exception 'Batas pemakaian minimal 1 kali'; end if;
    if exists (select 1 from referral_codes where upper(kode) = v_kode and id is distinct from p_id) then raise exception 'Kode referal sudah ada'; end if;
    if p_id is null then
        insert into referral_codes (kode, tipe, nilai, max_uses, aktif, expires_at)
        values (v_kode, p_tipe, p_nilai, p_max_uses, coalesce(p_aktif, true), p_expires) returning id into v_id;
    else
        update referral_codes set kode = v_kode, tipe = p_tipe, nilai = p_nilai, max_uses = p_max_uses, aktif = coalesce(p_aktif, aktif), expires_at = p_expires
         where id = p_id returning id into v_id;
        if v_id is null then raise exception 'Kode referal tidak ditemukan'; end if;
    end if;
    return v_id;
end; $$;

create or replace function pr_code_delete(p_pin text, p_id bigint)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    delete from referral_codes where id = p_id;
end; $$;

-- ---------------------------------------------------------------------
-- PELANGGAN (session_token)
-- ---------------------------------------------------------------------
-- Harga per hari yang berlaku untuk pelanggan ini (normal dicoret bila ada harga istimewa / diskon)
create or replace function cu_price_info(p_session_token uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare acc customer_accounts%rowtype; v jsonb := '{}'::jsonb; p text; q jsonb;
begin
    acc := portal_session_acc(p_session_token);
    foreach p in array array['BEM', 'SEM', 'LEM'] loop
        q := price_calc(acc.id, p, 1, 1, null);
        v := v || jsonb_build_object(p, jsonb_build_object('normal', q->'normal_hari', 'final', q->'harga_hari', 'jenis', q->'jenis',
                                                            'label', q->'diskon_label', 'persen', q->'diskon_persen'));
    end loop;
    return v || jsonb_build_object('istimewa', exists (select 1 from price_special where customer_id = acc.id));
end; $$;

-- Hitung total (dan periksa kode referal tanpa memakainya)
create or replace function cu_price_quote(p_session_token uuid, p_dashboard text, p_hari integer, p_jumlah integer, p_kode text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare acc customer_accounts%rowtype;
begin
    acc := portal_session_acc(p_session_token);
    if upper(coalesce(p_dashboard, '')) not in ('BEM', 'SEM', 'LEM') then raise exception 'Paket tidak valid'; end if;
    if p_hari is null or p_hari < 1 or p_hari > 365 then raise exception 'Jumlah hari harus antara 1 dan 365'; end if;
    return price_calc(acc.id, p_dashboard, p_hari, least(greatest(coalesce(p_jumlah, 1), 1), 20), p_kode);
end; $$;

-- Pesan langganan baru: + kode referal (versi lama 5 parameter diganti)
drop function if exists cu_request_new_order(uuid, text, integer, text[], text);
create or replace function cu_request_new_order(
    p_session_token uuid, p_dashboard text, p_hari integer, p_tagar_list text[], p_catatan text default null, p_kode text default null
) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
    acc customer_accounts%rowtype;
    v_dash text := upper(trim(coalesce(p_dashboard, '')));
    v_list text[] := '{}'; v_norm text[] := '{}'; x text; n text;
    v_note text := nullif(left(trim(coalesce(p_catatan, '')), 500), '');
    v_kode text := nullif(upper(trim(coalesce(p_kode, ''))), '');
    v_id bigint; q jsonb;
begin
    acc := portal_session_acc(p_session_token);
    if v_dash not in ('BEM', 'SEM', 'LEM') then raise exception 'Paket tidak valid'; end if;
    if p_hari is null or p_hari < 1 or p_hari > 365 then raise exception 'Jumlah hari harus antara 1 dan 365'; end if;

    foreach x in array coalesce(p_tagar_list, '{}') loop
        x := trim(x);
        continue when x = '';
        if length(x) > 100 then raise exception 'Tagar maksimal 100 karakter'; end if;
        n := lower(replace(x, '#', ''));
        if not (n = any(v_norm)) then v_list := v_list || x; v_norm := v_norm || n; end if;
    end loop;
    if cardinality(v_list) = 0 then raise exception 'Tagar wajib diisi'; end if;
    if cardinality(v_list) > 20 then raise exception 'Maksimal 20 tagar per pesanan'; end if;

    if exists (select 1 from renewal_requests r
                where r.customer_id = acc.id and r.source = 'new' and r.status = 'pending'
                  and exists (select 1 from unnest(coalesce(r.tagar_list, array[r.tagar_baru])) t(tg) where lower(replace(tg, '#', '')) = any(v_norm))) then
        raise exception 'Pesanan dengan tagar ini masih menunggu konfirmasi';
    end if;

    if v_kode is not null then
        q := price_calc(acc.id, v_dash, p_hari, cardinality(v_list), v_kode);
        if not coalesce((q->>'kode_ok')::boolean, false) then raise exception '%', coalesce(q->>'kode_pesan', 'Kode referal tidak valid'); end if;
    end if;

    insert into renewal_requests (
        customer_id, username, source, source_id, nomor_pesanan, nomor_whatsapp,
        dashboard_lama, tagar_lama, dashboard_baru, tagar_baru, tagar_diganti, hari, tagar_list, catatan_pelanggan, kode_referal
    ) values (
        acc.id, acc.username, 'new', null, acc.username, nullif(trim(coalesce(acc.whatsapp, '')), ''),
        null, '', v_dash, v_list[1], false, p_hari, v_list, v_note, v_kode
    ) returning id into v_id;     -- harga & pemakaian kode dicatat otomatis oleh trigger

    return jsonb_build_object('id', v_id, 'status', 'pending', 'jumlah_tagar', cardinality(v_list),
                              'total', (select total_harga from renewal_requests where id = v_id));
end; $$;

-- Perpanjangan: + kode referal (versi lama 6 parameter diganti)
drop function if exists cu_request_renewal(uuid, text, bigint, text, integer, text);
create or replace function cu_request_renewal(
    p_session_token uuid, p_source text, p_source_id bigint, p_dashboard text, p_hari integer,
    p_tagar_baru text default null, p_kode text default null
) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
    acc customer_accounts%rowtype;
    v_dash text := upper(trim(coalesce(p_dashboard, '')));
    v_nama text; v_wa text; v_dash_lama text; v_tagar_lama text;
    v_total int; v_kirim int;
    v_tagar_baru text := nullif(trim(coalesce(p_tagar_baru, '')), '');
    v_kode text := nullif(upper(trim(coalesce(p_kode, ''))), '');
    v_diganti boolean := false;
    v_id bigint; q jsonb;
begin
    acc := portal_session_acc(p_session_token);
    if v_dash not in ('BEM', 'SEM', 'LEM') then raise exception 'Paket tidak valid'; end if;
    if p_hari is null or p_hari < 1 or p_hari > 365 then raise exception 'Jumlah hari harus antara 1 dan 365'; end if;
    if p_source not in ('order', 'archive') then raise exception 'Sumber langganan tidak valid'; end if;

    if p_source = 'order' then
        select o.nomor_pesanan, o.nomor_whatsapp, o.dashboard, o.tagar, o.paket_total, o.paket_terkirim
          into v_nama, v_wa, v_dash_lama, v_tagar_lama, v_total, v_kirim
          from orders o where o.id = p_source_id and normalize_pelanggan_name(o.nomor_pesanan) = acc.match_key;
    else
        select a.nomor_pesanan, a.nomor_whatsapp, a.dashboard, a.tagar, a.paket_total, a.paket_terkirim
          into v_nama, v_wa, v_dash_lama, v_tagar_lama, v_total, v_kirim
          from archives a where a.id = p_source_id and normalize_pelanggan_name(a.nomor_pesanan) = acc.match_key;
    end if;

    if v_tagar_lama is null then raise exception 'Langganan tidak ditemukan'; end if;
    if coalesce(v_kirim, 0) < coalesce(v_total, 0) then raise exception 'Perpanjangan hanya bisa diajukan untuk langganan yang sudah limit'; end if;

    if v_tagar_baru is not null then
        if length(v_tagar_baru) > 100 then raise exception 'Tagar maksimal 100 karakter'; end if;
        v_diganti := lower(replace(v_tagar_baru, '#', '')) <> lower(replace(v_tagar_lama, '#', ''));
    end if;

    if exists (select 1 from renewal_requests r where r.source = p_source and r.source_id = p_source_id and r.status = 'pending') then
        raise exception 'Permintaan perpanjangan untuk langganan ini masih menunggu konfirmasi';
    end if;

    if v_kode is not null then
        q := price_calc(acc.id, v_dash, p_hari, 1, v_kode);
        if not coalesce((q->>'kode_ok')::boolean, false) then raise exception '%', coalesce(q->>'kode_pesan', 'Kode referal tidak valid'); end if;
    end if;

    insert into renewal_requests (
        customer_id, username, source, source_id, nomor_pesanan, nomor_whatsapp,
        dashboard_lama, tagar_lama, dashboard_baru, tagar_baru, tagar_diganti, hari, kode_referal
    ) values (
        acc.id, acc.username, p_source, p_source_id, v_nama,
        coalesce(nullif(trim(coalesce(v_wa, '')), ''), acc.whatsapp),
        v_dash_lama, v_tagar_lama, v_dash,
        case when v_diganti then v_tagar_baru else v_tagar_lama end,
        v_diganti, p_hari, v_kode
    ) returning id into v_id;

    return jsonb_build_object('id', v_id, 'status', 'pending', 'total', (select total_harga from renewal_requests where id = v_id));
end; $$;

-- Daftar permintaan: + harga
create or replace function rn_list(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v jsonb;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    select coalesce(jsonb_agg(to_jsonb(r) order by r.created_at desc), '[]'::jsonb) into v
    from (select id, username, source, source_id, nomor_pesanan, nomor_whatsapp,
                 dashboard_lama, tagar_lama, dashboard_baru, tagar_baru, tagar_diganti, hari,
                 tagar_list, catatan_pelanggan,
                 harga_normal_hari, harga_hari, jumlah_item, kode_referal, diskon_referral, total_harga,
                 status, catatan_admin, result_order_id, created_at, processed_at
            from renewal_requests order by created_at desc limit 300) r;
    return v;
end; $$;

create or replace function cu_my_renewals(p_session_token uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare acc customer_accounts%rowtype; v jsonb;
begin
    acc := portal_session_acc(p_session_token);
    select coalesce(jsonb_agg(jsonb_build_object(
        'id', r.id, 'source', r.source, 'source_id', r.source_id,
        'dashboard_lama', r.dashboard_lama, 'dashboard_baru', r.dashboard_baru,
        'tagar_lama', r.tagar_lama, 'tagar_baru', r.tagar_baru, 'tagar_diganti', r.tagar_diganti,
        'tagar_list', r.tagar_list, 'catatan_pelanggan', r.catatan_pelanggan,
        'hari', r.hari, 'total_harga', r.total_harga, 'kode_referal', r.kode_referal, 'diskon_referral', r.diskon_referral,
        'status', r.status, 'catatan_admin', r.catatan_admin,
        'created_at', r.created_at, 'processed_at', r.processed_at
    ) order by r.created_at desc), '[]'::jsonb) into v
    from (select * from renewal_requests where customer_id = acc.id order by created_at desc limit 50) r;
    return v;
end; $$;

grant execute on function
    pr_get(text), pr_save_default(text, integer, integer, integer), pr_save_diskon(text, boolean, integer, text, boolean, boolean, boolean),
    pr_special_save(text, bigint, integer, integer, integer, text), pr_special_delete(text, bigint),
    pr_code_save(text, bigint, text, text, integer, integer, boolean, timestamptz), pr_code_delete(text, bigint),
    cu_price_info(uuid), cu_price_quote(uuid, text, integer, integer, text),
    cu_request_new_order(uuid, text, integer, text[], text, text), cu_request_renewal(uuid, text, bigint, text, integer, text, text),
    rn_list(text), cu_my_renewals(uuid)
to anon, authenticated;
