-- =====================================================================
-- PERBAIKAN: "PIN admin salah" padahal PIN sudah benar (123456)
-- =====================================================================
-- PENYEBAB:
-- Di Supabase, ekstensi pgcrypto terpasang di schema `extensions`,
-- bukan `public`. Karena fungsi-fungsi saya memakai
-- `set search_path = public`, fungsi crypt() dan gen_salt() jadi tidak
-- ditemukan -> fungsi error -> frontend menampilkannya sebagai
-- "PIN admin salah".
--
-- SOLUSI: search_path diubah jadi `public, extensions`.
--
-- CARA PAKAI:
-- Jalankan SELURUH isi file `customer_portal_fixed.sql` di Supabase
-- SQL Editor. File itu aman dijalankan ulang (create table if not
-- exists / create or replace function / insert on conflict do nothing),
-- jadi data yang sudah ada TIDAK akan hilang atau berubah.
--
-- File ini sendiri berisi query DIAGNOSA untuk memastikan masalahnya.
-- =====================================================================


-- ---------------------------------------------------------------------
-- LANGKAH 1 — Cek di schema mana pgcrypto terpasang
-- ---------------------------------------------------------------------
-- Kalau hasilnya "extensions", berarti dugaan di atas benar.
select
    e.extname                as nama_ekstensi,
    n.nspname                as schema_terpasang
from pg_extension e
join pg_namespace n on n.oid = e.extnamespace
where e.extname = 'pgcrypto';


-- ---------------------------------------------------------------------
-- LANGKAH 2 — Cek apakah tabel PIN admin sudah terbuat & terisi
-- ---------------------------------------------------------------------
-- Harusnya keluar 1 baris. Kalau 0 baris, berarti SQL awal gagal total
-- dan Anda cukup jalankan customer_portal_fixed.sql dari nol.
select
    id,
    left(admin_pin_hash, 10) || '...' as hash_pin_terpotong
from app_admin_settings;


-- ---------------------------------------------------------------------
-- LANGKAH 3 — Uji langsung fungsi verifikasi PIN
-- ---------------------------------------------------------------------
-- Jalankan SETELAH customer_portal_fixed.sql dijalankan.
-- Hasil yang benar: true
select admin_verify_pin('123456') as pin_benar;


-- ---------------------------------------------------------------------
-- LANGKAH 4 (opsional) — Paksa reset PIN admin kembali ke 123456
-- ---------------------------------------------------------------------
-- Pakai ini HANYA jika Anda pernah mengganti PIN lalu lupa.
-- Hapus dua tanda minus di awal baris untuk mengaktifkannya.
--
-- update app_admin_settings
--     set admin_pin_hash = extensions.crypt('123456', extensions.gen_salt('bf'))
--     where id = true;


-- ---------------------------------------------------------------------
-- LANGKAH 5 (opsional) — Reset password seorang pelanggan dari SQL
-- ---------------------------------------------------------------------
-- Ganti 'Pelanggan 88' dan 'passwordbaru' sesuai kebutuhan.
--
-- update customer_accounts
--     set password_hash = extensions.crypt('passwordbaru', extensions.gen_salt('bf')),
--         failed_attempts = 0,
--         locked_until = null,
--         session_token = null
--     where lower(username) = lower('Pelanggan 88');
