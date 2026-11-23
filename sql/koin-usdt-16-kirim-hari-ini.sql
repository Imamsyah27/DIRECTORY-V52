-- =====================================================================
-- KOIN — BAGIAN 16: PESANAN HARIAN BEM/SEM/LEM -> "KIRIM HARI INI" atau "KIRIM BESOK"
-- Jalankan SETELAH price-4.sql / koin-usdt-1…15. Aman diulang.
-- Pelanggan mencentang "Kirim hari ini" saat memesan langganan baru / perpanjang. Di admin:
--   hari ini = MERAH BERCAHAYA, besok = BIRU. (Pesanan lama tanpa pilihan tampil seperti biasa.)
-- Fungsi lama TIDAK diubah: fungsi baru *_k memanggilnya lalu mencatat pilihan dalam 1 transaksi.
-- =====================================================================

alter table renewal_requests add column if not exists kirim_waktu text check (kirim_waktu in ('hari_ini', 'besok'));

create or replace function cu_request_new_order_k(p_session_token uuid, p_dashboard text, p_hari integer, p_tagar_list text[],
                                                  p_catatan text default null, p_kode text default null, p_hari_ini boolean default false)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare r jsonb; acc customer_accounts%rowtype;
begin
    acc := portal_session_acc(p_session_token);
    r := cu_request_new_order(p_session_token, p_dashboard, p_hari, p_tagar_list, p_catatan, p_kode);
    update renewal_requests set kirim_waktu = case when coalesce(p_hari_ini, false) then 'hari_ini' else 'besok' end
     where id = (r->>'id')::bigint and customer_id = acc.id;
    return r;
end; $$;

create or replace function cu_request_renewal_k(p_session_token uuid, p_source text, p_source_id bigint, p_dashboard text, p_hari integer,
                                                p_tagar_baru text default null, p_kode text default null, p_hari_ini boolean default false)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare r jsonb; acc customer_accounts%rowtype;
begin
    acc := portal_session_acc(p_session_token);
    r := cu_request_renewal(p_session_token, p_source, p_source_id, p_dashboard, p_hari, p_tagar_baru, p_kode);
    update renewal_requests set kirim_waktu = case when coalesce(p_hari_ini, false) then 'hari_ini' else 'besok' end
     where id = (r->>'id')::bigint and customer_id = acc.id;
    return r;
end; $$;

-- daftar admin: ikut membawa kirim_waktu
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
                 status, catatan_admin, result_order_id, created_at, processed_at, kirim_waktu
            from renewal_requests order by created_at desc limit 300) r;
    return v;
end; $$;

-- riwayat pelanggan: ikut membawa kirim_waktu
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
        'status', r.status, 'catatan_admin', r.catatan_admin, 'kirim_waktu', r.kirim_waktu,
        'created_at', r.created_at, 'processed_at', r.processed_at
    ) order by r.created_at desc), '[]'::jsonb) into v
    from (select * from renewal_requests where customer_id = acc.id order by created_at desc limit 50) r;
    return v;
end; $$;

grant execute on function
    cu_request_new_order_k(uuid, text, integer, text[], text, text, boolean),
    cu_request_renewal_k(uuid, text, bigint, text, integer, text, text, boolean),
    rn_list(text), cu_my_renewals(uuid)
to anon, authenticated;
