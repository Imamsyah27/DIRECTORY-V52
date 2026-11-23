-- PRICE bagian 1/4: tabel + mesin hitung harga
-- Jalankan price-1 -> price-2 -> price-3 -> price-4, satu per satu (tempel, Run, lalu file berikutnya).
-- Dipecah dari price.sql karena SQL Editor bisa memotong teks yang terlalu panjang.

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
