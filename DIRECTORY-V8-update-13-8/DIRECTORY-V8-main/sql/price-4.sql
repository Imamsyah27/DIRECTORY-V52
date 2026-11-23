-- PRICE bagian 4/4: perpanjangan, daftar permintaan, grant
-- Jalankan price-1 -> price-2 -> price-3 -> price-4, satu per satu (tempel, Run, lalu file berikutnya).
-- Dipecah dari price.sql karena SQL Editor bisa memotong teks yang terlalu panjang.

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
