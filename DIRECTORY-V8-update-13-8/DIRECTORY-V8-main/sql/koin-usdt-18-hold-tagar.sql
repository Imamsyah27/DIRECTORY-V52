-- =====================================================================
-- KOIN — BAGIAN 18: TUNDA (HOLD) LANGGANAN HARIAN BEM/SEM/LEM
-- Jalankan SETELAH koin-usdt-17. Aman diulang.
-- Admin mencentang langganan di daftar lalu "Tunda": langganan pindah ke halaman TUNDA (tidak ikut
-- hitungan aktif, tidak ikut "Ceklis Semua", tidak masuk "Belum dicentang hari ini"). "Aktifkan" mengembalikannya.
-- Dashboard pelanggan menampilkan yang ditunda di tab terpisah (tabel dan kartu).
-- =====================================================================
alter table orders add column if not exists hold boolean not null default false;
alter table orders add column if not exists hold_at timestamptz;

drop function if exists get_my_orders(uuid);
create or replace function get_my_orders(p_session_token uuid)
returns table(
    id bigint, dashboard text, nomor_pesanan text, tagar text, nomor_whatsapp text,
    paket_total integer, paket_terkirim integer, last_check_utc text, keterangan text,
    created_at timestamptz, inisial text, hold boolean, hold_at timestamptz
) language plpgsql security definer set search_path = public, extensions as $$
declare v_acc customer_accounts%rowtype;
begin
    v_acc := portal_session_acc(p_session_token);
    return query
    select o.id, o.dashboard, o.nomor_pesanan, o.tagar, o.nomor_whatsapp,
           o.paket_total, o.paket_terkirim, o.last_check_utc, o.keterangan, o.created_at, col.inisial, o.hold, o.hold_at
    from orders o
    left join customer_order_labels col on col.order_id = o.id
    where normalize_pelanggan_name(o.nomor_pesanan) = v_acc.match_key
    order by o.created_at asc;
end; $$;

grant execute on function get_my_orders(uuid) to anon, authenticated;
