-- =====================================================================
-- PORTAL MONITORING PELANGGAN — Tambahan Database
-- Jalankan seluruh file ini SATU KALI di Supabase SQL Editor
-- (project yang sama dengan dashboard admin Anda / config.js Anda)
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- 1) PIN ADMIN — melindungi menu "Akun Pelanggan" & aksi admin lainnya
--    supaya tidak sembarang orang yang punya anon key bisa bikin/hapus
--    akun pelanggan. GANTI PIN default di bawah setelah setup pertama!
-- ---------------------------------------------------------------------
create table if not exists app_admin_settings (
    id boolean primary key default true,
    admin_pin_hash text not null,
    constraint single_row check (id)
);

insert into app_admin_settings (id, admin_pin_hash)
values (true, crypt('123456', gen_salt('bf')))
on conflict (id) do nothing;

alter table app_admin_settings enable row level security;
-- sengaja TIDAK ada policy select/insert/update publik -> hanya bisa
-- diakses lewat function security definer di bawah.

create or replace function admin_verify_pin(p_pin text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
    v_hash text;
begin
    select admin_pin_hash into v_hash from app_admin_settings where id = true;
    if v_hash is null then
        return false;
    end if;
    return v_hash = crypt(coalesce(p_pin, ''), v_hash);
end;
$$;

create or replace function admin_change_pin(p_old_pin text, p_new_pin text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
    if not admin_verify_pin(p_old_pin) then
        return false;
    end if;
    if p_new_pin is null or length(p_new_pin) < 4 then
        raise exception 'PIN baru minimal 4 karakter';
    end if;
    update app_admin_settings set admin_pin_hash = crypt(p_new_pin, gen_salt('bf')) where id = true;
    return true;
end;
$$;

-- ---------------------------------------------------------------------
-- 2) Normalisasi nama pelanggan, supaya "Pelanggan 88" == "88"
-- ---------------------------------------------------------------------
create or replace function normalize_pelanggan_name(p_name text)
returns text
language sql
immutable
as $$
    select trim(
        regexp_replace(
            regexp_replace(lower(coalesce(p_name, '')), 'pelanggan', '', 'gi'),
            '\s+', ' ', 'g'
        )
    )
$$;

-- ---------------------------------------------------------------------
-- 3) Tabel akun pelanggan
-- ---------------------------------------------------------------------
create table if not exists customer_accounts (
    id bigint generated always as identity primary key,

    username text not null,              -- ditampilkan apa adanya, cth "Pelanggan 88"
    match_key text not null,             -- hasil normalize_pelanggan_name, dipakai mencocokkan ke orders.nomor_pesanan
    whatsapp text,                       -- untuk verifikasi lupa password

    password_hash text not null,

    failed_attempts int not null default 0,
    locked_until timestamptz,

    session_token uuid,
    session_expires_at timestamptz,

    created_at timestamptz default now()
);

create unique index if not exists customer_accounts_username_lower_idx
    on customer_accounts (lower(username));

alter table customer_accounts enable row level security;
-- Tidak ada policy publik sama sekali di tabel ini: password_hash & session_token
-- TIDAK BOLEH bisa dibaca langsung lewat anon key. Semua akses wajib lewat
-- function security definer di bawah ini.

-- ---------------------------------------------------------------------
-- 4) ADMIN: buat / kelola akun pelanggan (perlu PIN admin)
-- ---------------------------------------------------------------------
create or replace function admin_create_customer_account(
    p_admin_pin text,
    p_username text,
    p_password text,
    p_match_source text,     -- nama pemesan dari database dashboard aktif, cth "Pelanggan 88" atau "88"
    p_whatsapp text default null
)
returns table(id bigint, username text)
language plpgsql
security definer
set search_path = public
as $$
declare
    v_id bigint;
begin
    if not admin_verify_pin(p_admin_pin) then
        raise exception 'PIN admin salah';
    end if;

    if p_username is null or trim(p_username) = '' then
        raise exception 'Username tidak boleh kosong';
    end if;
    if p_password is null or length(p_password) < 6 then
        raise exception 'Password minimal 6 karakter';
    end if;
    if exists (select 1 from customer_accounts where lower(username) = lower(trim(p_username))) then
        raise exception 'Username sudah dipakai';
    end if;

    insert into customer_accounts (username, match_key, whatsapp, password_hash)
    values (
        trim(p_username),
        normalize_pelanggan_name(p_match_source),
        nullif(trim(coalesce(p_whatsapp, '')), ''),
        crypt(p_password, gen_salt('bf'))
    )
    returning customer_accounts.id into v_id;

    return query select v_id, trim(p_username);
end;
$$;

create or replace function admin_list_customer_accounts(p_admin_pin text)
returns table(
    id bigint,
    username text,
    match_key text,
    whatsapp text,
    created_at timestamptz,
    jumlah_pesanan_aktif bigint
)
language plpgsql
security definer
set search_path = public
as $$
begin
    if not admin_verify_pin(p_admin_pin) then
        raise exception 'PIN admin salah';
    end if;

    return query
    select
        ca.id,
        ca.username,
        ca.match_key,
        ca.whatsapp,
        ca.created_at,
        (select count(*) from orders o where normalize_pelanggan_name(o.nomor_pesanan) = ca.match_key) as jumlah_pesanan_aktif
    from customer_accounts ca
    order by ca.created_at desc;
end;
$$;

create or replace function admin_delete_customer_account(p_admin_pin text, p_id bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
    if not admin_verify_pin(p_admin_pin) then
        raise exception 'PIN admin salah';
    end if;
    delete from customer_accounts where id = p_id;
end;
$$;

create or replace function admin_reset_customer_password(p_admin_pin text, p_id bigint, p_new_password text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
    if not admin_verify_pin(p_admin_pin) then
        raise exception 'PIN admin salah';
    end if;
    if p_new_password is null or length(p_new_password) < 6 then
        raise exception 'Password minimal 6 karakter';
    end if;
    update customer_accounts
        set password_hash = crypt(p_new_password, gen_salt('bf')),
            failed_attempts = 0,
            locked_until = null,
            session_token = null,
            session_expires_at = null
        where id = p_id;
end;
$$;

-- Bantuan buat dropdown admin: daftar nama pemesan unik dari orders yang
-- BELUM punya akun pelanggan.
create or replace function admin_list_unlinked_customers(p_admin_pin text)
returns table(nomor_pesanan text, match_key text, dashboard text, nomor_whatsapp text)
language plpgsql
security definer
set search_path = public
as $$
begin
    if not admin_verify_pin(p_admin_pin) then
        raise exception 'PIN admin salah';
    end if;

    return query
    select distinct on (normalize_pelanggan_name(o.nomor_pesanan))
        o.nomor_pesanan,
        normalize_pelanggan_name(o.nomor_pesanan) as match_key,
        o.dashboard,
        o.nomor_whatsapp
    from orders o
    where normalize_pelanggan_name(o.nomor_pesanan) not in (
        select match_key from customer_accounts
    )
    order by normalize_pelanggan_name(o.nomor_pesanan), o.created_at desc;
end;
$$;

-- ---------------------------------------------------------------------
-- 5) PELANGGAN: login, sesi, ganti password, lupa password
-- ---------------------------------------------------------------------
create or replace function customer_login(p_username text, p_password text)
returns table(username text, session_token uuid)
language plpgsql
security definer
set search_path = public
as $$
declare
    v_acc customer_accounts%rowtype;
    v_token uuid;
begin
    select * into v_acc from customer_accounts where lower(username) = lower(trim(coalesce(p_username, '')));

    if not found then
        -- samakan waktu respon agar tidak bocor info username ada/tidak
        perform pg_sleep(0.3);
        raise exception 'Username atau password salah';
    end if;

    if v_acc.locked_until is not null and v_acc.locked_until > now() then
        raise exception 'Akun terkunci sementara karena terlalu banyak percobaan gagal. Coba lagi nanti.';
    end if;

    if v_acc.password_hash = crypt(p_password, v_acc.password_hash) then
        v_token := gen_random_uuid();
        update customer_accounts
            set session_token = v_token,
                session_expires_at = now() + interval '7 days',
                failed_attempts = 0,
                locked_until = null
            where id = v_acc.id;

        return query select v_acc.username, v_token;
    else
        update customer_accounts
            set failed_attempts = failed_attempts + 1,
                locked_until = case when failed_attempts + 1 >= 5 then now() + interval '15 minutes' else locked_until end
            where id = v_acc.id;

        raise exception 'Username atau password salah';
    end if;
end;
$$;

create or replace function customer_logout(p_session_token uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
    update customer_accounts
        set session_token = null, session_expires_at = null
        where session_token = p_session_token;
end;
$$;

-- Mengambil profil singkat pemilik sesi (untuk sapaan "Halo, ..." di dashboard)
create or replace function get_my_profile(p_session_token uuid)
returns table(username text)
language plpgsql
security definer
set search_path = public
as $$
declare
    v_acc customer_accounts%rowtype;
begin
    select * into v_acc from customer_accounts
        where session_token = p_session_token and session_expires_at > now();
    if not found then
        return;
    end if;
    return query select v_acc.username;
end;
$$;

-- Data monitoring pelanggan: HANYA baris orders miliknya sendiri
create or replace function get_my_orders(p_session_token uuid)
returns setof orders
language plpgsql
security definer
set search_path = public
as $$
declare
    v_acc customer_accounts%rowtype;
begin
    select * into v_acc from customer_accounts
        where session_token = p_session_token and session_expires_at > now();

    if not found then
        raise exception 'Sesi login tidak valid atau sudah habis, silakan login ulang';
    end if;

    return query
    select o.*
    from orders o
    where normalize_pelanggan_name(o.nomor_pesanan) = v_acc.match_key
    order by o.created_at asc;
end;
$$;

create or replace function customer_change_password(p_session_token uuid, p_old_password text, p_new_password text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    v_acc customer_accounts%rowtype;
begin
    select * into v_acc from customer_accounts
        where session_token = p_session_token and session_expires_at > now();

    if not found then
        raise exception 'Sesi login tidak valid atau sudah habis, silakan login ulang';
    end if;

    if v_acc.password_hash <> crypt(p_old_password, v_acc.password_hash) then
        raise exception 'Password lama salah';
    end if;

    if p_new_password is null or length(p_new_password) < 6 then
        raise exception 'Password baru minimal 6 karakter';
    end if;

    update customer_accounts
        set password_hash = crypt(p_new_password, gen_salt('bf'))
        where id = v_acc.id;
end;
$$;

-- Lupa password: verifikasi pakai nomor WhatsApp yang terdaftar di akun
create or replace function customer_reset_password(p_username text, p_whatsapp text, p_new_password text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    v_acc customer_accounts%rowtype;
begin
    select * into v_acc from customer_accounts where lower(username) = lower(trim(coalesce(p_username, '')));

    if not found then
        raise exception 'Username tidak ditemukan';
    end if;

    if v_acc.whatsapp is null or trim(v_acc.whatsapp) = '' then
        raise exception 'Akun ini belum punya nomor WhatsApp terdaftar, hubungi admin untuk reset password';
    end if;

    if regexp_replace(v_acc.whatsapp, '[^0-9]', '', 'g') <> regexp_replace(coalesce(p_whatsapp, ''), '[^0-9]', '', 'g') then
        raise exception 'Nomor WhatsApp tidak cocok dengan data terdaftar';
    end if;

    if p_new_password is null or length(p_new_password) < 6 then
        raise exception 'Password baru minimal 6 karakter';
    end if;

    update customer_accounts
        set password_hash = crypt(p_new_password, gen_salt('bf')),
            failed_attempts = 0,
            locked_until = null,
            session_token = null,
            session_expires_at = null
        where id = v_acc.id;
end;
$$;

-- ---------------------------------------------------------------------
-- 6) Izin eksekusi (anon key dipakai frontend, jadi wajib di-grant)
-- ---------------------------------------------------------------------
grant execute on function
    admin_verify_pin(text),
    admin_change_pin(text, text),
    admin_create_customer_account(text, text, text, text, text),
    admin_list_customer_accounts(text),
    admin_delete_customer_account(text, bigint),
    admin_reset_customer_password(text, bigint, text),
    admin_list_unlinked_customers(text),
    customer_login(text, text),
    customer_logout(uuid),
    get_my_profile(uuid),
    get_my_orders(uuid),
    customer_change_password(uuid, text, text),
    customer_reset_password(text, text, text)
to anon, authenticated;

-- =====================================================================
-- SELESAI. Catatan penting:
-- 1. PIN admin default = 123456. GANTI lewat menu "Akun Pelanggan" > Ganti
--    PIN Admin setelah deploy, atau jalankan:
--    select admin_change_pin('123456', 'PIN_BARU_ANDA');
-- 2. Tabel customer_accounts tidak punya policy SELECT publik, jadi
--    password_hash tidak akan pernah terbaca lewat anon key secara
--    langsung — hanya lewat function-function di atas.
-- 3. Fungsi admin_* masih bisa dipanggil siapa pun yang tahu anon key +
--    PIN. Ini konsisten dengan tabel `orders` Anda yang saat ini juga
--    terbuka lewat anon key. Jaga kerahasiaan PIN admin dan jangan
--    sebarkan URL menu admin ke pelanggan.
-- =====================================================================
