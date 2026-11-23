-- =====================================================================
-- ADMIN MELIHAT TAMPILAN PELANGGAN (tanpa login pelanggan)
-- Jalankan SELURUH file ini SEKALI di Supabase SQL Editor.
-- Syarat: customer_portal_fixed.sql, supply.sql, perpanjang.sql sudah dijalankan.
-- Aman dijalankan ulang. Tidak mengubah data/akun/password pelanggan.
--
-- Cara kerja: admin (PIN) membuat "token lihat" sementara (8 jam) untuk satu akun
-- pelanggan. Token ini terpisah dari session pelanggan asli, jadi pelanggan yang
-- sedang login TIDAK ikut keluar dan password-nya tidak tersentuh.
-- =====================================================================

create table if not exists admin_view_tokens (
    token uuid primary key default gen_random_uuid(),
    customer_id bigint not null references customer_accounts(id) on delete cascade,
    expires_at timestamptz not null
);
alter table admin_view_tokens enable row level security;   -- tanpa policy publik

-- Admin membuka tampilan salah satu pelanggan -> mengembalikan token lihat
create or replace function admin_view_open(p_pin text, p_customer_id bigint)
returns uuid language plpgsql security definer set search_path = public, extensions as $$
declare v_token uuid;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    if not exists (select 1 from customer_accounts where id = p_customer_id) then raise exception 'Akun pelanggan tidak ditemukan'; end if;
    delete from admin_view_tokens where expires_at < now();
    insert into admin_view_tokens (customer_id, expires_at) values (p_customer_id, now() + interval '8 hours')
    returning token into v_token;
    return v_token;
end; $$;

-- Validasi sesi: session pelanggan asli ATAU token lihat dari admin
create or replace function portal_session_acc(p_token uuid)
returns customer_accounts language plpgsql security definer set search_path = public, extensions as $$
declare v customer_accounts%rowtype;
begin
    select * into v from customer_accounts where session_token = p_token and session_expires_at > now();
    if not found then
        select ca.* into v from admin_view_tokens t join customer_accounts ca on ca.id = t.customer_id
        where t.token = p_token and t.expires_at > now();
    end if;
    if not found then raise exception 'Sesi login tidak valid atau sudah habis, silakan login ulang'; end if;
    return v;
end; $$;
revoke all on function portal_session_acc(uuid) from public, anon, authenticated;

-- Dua fungsi ini sebelumnya mengecek session langsung; sekarang lewat portal_session_acc
create or replace function get_my_profile(p_session_token uuid)
returns table(username text) language plpgsql security definer set search_path = public, extensions as $$
declare v_acc customer_accounts%rowtype;
begin
    v_acc := portal_session_acc(p_session_token);
    return query select v_acc.username;
end; $$;

create or replace function get_my_orders(p_session_token uuid)
returns table(
    id bigint, dashboard text, nomor_pesanan text, tagar text, nomor_whatsapp text,
    paket_total integer, paket_terkirim integer, last_check_utc text, keterangan text,
    created_at timestamptz, inisial text
) language plpgsql security definer set search_path = public, extensions as $$
declare v_acc customer_accounts%rowtype;
begin
    v_acc := portal_session_acc(p_session_token);
    return query
    select o.id, o.dashboard, o.nomor_pesanan, o.tagar, o.nomor_whatsapp,
           o.paket_total, o.paket_terkirim, o.last_check_utc, o.keterangan, o.created_at, col.inisial
    from orders o
    left join customer_order_labels col on col.order_id = o.id
    where normalize_pelanggan_name(o.nomor_pesanan) = v_acc.match_key
    order by o.created_at asc;
end; $$;

grant execute on function admin_view_open(text, bigint), get_my_profile(uuid), get_my_orders(uuid) to anon, authenticated;
