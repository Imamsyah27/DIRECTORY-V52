-- =====================================================================
-- PESAN LANGGANAN BARU: banyak tagar dalam 1 pesanan + catatan pelanggan
-- Jalankan SEKALI di Supabase SQL Editor, SETELAH sql/katalog-pesan-baru.sql
-- (dan setelah admin-view.sql bila dipakai). Aman dijalankan ulang.
--
-- Pelanggan memasukkan beberapa tagar (mis. 4 tagar untuk 10 hari). Saat admin SETUJUI,
-- tiap tagar menjadi 1 data langganan sendiri di Dashboard Aktif, dengan jumlah hari yang sama.
-- =====================================================================

alter table renewal_requests add column if not exists tagar_list text[];
alter table renewal_requests add column if not exists catatan_pelanggan text;

-- versi lama (4 parameter) diganti versi baru agar tidak ada dua fungsi bernama sama
drop function if exists cu_request_new_order(uuid, text, integer, text);

create or replace function cu_request_new_order(
    p_session_token uuid, p_dashboard text, p_hari integer, p_tagar_list text[], p_catatan text default null
) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
    acc customer_accounts%rowtype;
    v_dash text := upper(trim(coalesce(p_dashboard, '')));
    v_list text[] := '{}';
    v_norm text[] := '{}';
    x text; n text;
    v_note text := nullif(left(trim(coalesce(p_catatan, '')), 500), '');
    v_id bigint;
begin
    acc := portal_session_acc(p_session_token);
    if v_dash not in ('BEM', 'SEM', 'LEM') then raise exception 'Paket tidak valid'; end if;
    if p_hari is null or p_hari < 1 or p_hari > 365 then raise exception 'Jumlah hari harus antara 1 dan 365'; end if;

    foreach x in array coalesce(p_tagar_list, '{}') loop
        x := trim(x);
        continue when x = '';
        if length(x) > 100 then raise exception 'Tagar maksimal 100 karakter'; end if;
        n := lower(replace(x, '#', ''));
        if not (n = any(v_norm)) then v_list := v_list || x; v_norm := v_norm || n; end if;   -- tagar kembar diabaikan
    end loop;
    if cardinality(v_list) = 0 then raise exception 'Tagar wajib diisi'; end if;
    if cardinality(v_list) > 20 then raise exception 'Maksimal 20 tagar per pesanan'; end if;

    if exists (select 1 from renewal_requests r
                where r.customer_id = acc.id and r.source = 'new' and r.status = 'pending'
                  and exists (select 1 from unnest(coalesce(r.tagar_list, array[r.tagar_baru])) t(tg) where lower(replace(tg, '#', '')) = any(v_norm))) then
        raise exception 'Pesanan dengan tagar ini masih menunggu konfirmasi';
    end if;

    insert into renewal_requests (
        customer_id, username, source, source_id, nomor_pesanan, nomor_whatsapp,
        dashboard_lama, tagar_lama, dashboard_baru, tagar_baru, tagar_diganti, hari, tagar_list, catatan_pelanggan
    ) values (
        acc.id, acc.username, 'new', null, acc.username, nullif(trim(coalesce(acc.whatsapp, '')), ''),
        null, '', v_dash, v_list[1], false, p_hari, v_list, v_note
    ) returning id into v_id;

    return jsonb_build_object('id', v_id, 'status', 'pending', 'jumlah_tagar', cardinality(v_list));
end; $$;

-- Admin SETUJUI: 1 tagar = 1 data langganan (hari sama). Perpanjangan biasa tidak berubah.
create or replace function rn_approve(p_pin text, p_id bigint)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
    r renewal_requests%rowtype;
    o orders%rowtype;
    v_wa_digits text;
    v_ket text;
    v_new_id bigint;
    v_first_id bigint;
    v_archived boolean := false;
    v_tags text[];
    v_tag text;
    v_count int := 0;
    v_note text;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;

    select * into r from renewal_requests where id = p_id for update;
    if not found then raise exception 'Permintaan tidak ditemukan'; end if;
    if r.status <> 'pending' then raise exception 'Permintaan ini sudah diproses'; end if;

    v_wa_digits := regexp_replace(coalesce(r.nomor_whatsapp, ''), '[^0-9]', '', 'g');
    v_tags := case when r.source = 'new' and r.tagar_list is not null and cardinality(r.tagar_list) > 0
                   then r.tagar_list else array[r.tagar_baru] end;
    v_note := nullif(regexp_replace(trim(coalesce(r.catatan_pelanggan, '')), '\s+', ' ', 'g'), '');

    foreach v_tag in array v_tags loop
        v_ket := r.dashboard_baru || ' H0/H' || r.hari || ' | ' || v_tag || ' | ' ||
                 case when v_wa_digits <> '' then 'https://wa.me/' || v_wa_digits else '' end ||
                 case when v_note is not null then ' | Catatan: ' || v_note else '' end;
        insert into orders (dashboard, nomor_pesanan, tagar, nomor_whatsapp, paket_total, paket_terkirim, last_check_utc, keterangan)
        values (r.dashboard_baru, r.nomor_pesanan, v_tag, coalesce(r.nomor_whatsapp, ''), r.hari, 0, '', v_ket)
        returning id into v_new_id;
        if v_count = 0 then v_first_id := v_new_id; end if;
        v_count := v_count + 1;
    end loop;
    v_new_id := v_first_id;

    -- langganan lama (sudah limit) di Dashboard Aktif -> pindah ke Arsip
    if r.source = 'order' and r.source_id is not null then
        select * into o from orders where id = r.source_id;
        if found and o.paket_terkirim >= o.paket_total then
            insert into archives (order_id, dashboard, nomor_pesanan, tagar, nomor_whatsapp, paket_total, paket_terkirim, keterangan, created_at)
            values (o.id, o.dashboard, o.nomor_pesanan, o.tagar, coalesce(o.nomor_whatsapp, ''), o.paket_total, o.paket_terkirim, coalesce(o.keterangan, ''), o.created_at);

            insert into customer_order_labels (order_id, inisial, updated_at)
            select v_new_id, l.inisial, now() from customer_order_labels l where l.order_id = o.id
            on conflict (order_id) do nothing;
            delete from customer_order_labels where order_id = o.id;

            delete from orders where id = o.id;
            v_archived := true;
        end if;
    end if;

    update renewal_requests set status = 'approved', processed_at = now(), result_order_id = v_new_id where id = r.id;

    return jsonb_build_object('order_id', v_new_id, 'dashboard', r.dashboard_baru, 'archived_old', v_archived, 'jumlah', v_count);
end; $$;

-- Daftar permintaan: tambah tagar_list & catatan_pelanggan
create or replace function rn_list(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v jsonb;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    select coalesce(jsonb_agg(to_jsonb(r) order by r.created_at desc), '[]'::jsonb) into v
    from (select id, username, source, source_id, nomor_pesanan, nomor_whatsapp,
                 dashboard_lama, tagar_lama, dashboard_baru, tagar_baru, tagar_diganti, hari,
                 tagar_list, catatan_pelanggan,
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
        'hari', r.hari, 'status', r.status, 'catatan_admin', r.catatan_admin,
        'created_at', r.created_at, 'processed_at', r.processed_at
    ) order by r.created_at desc), '[]'::jsonb) into v
    from (select * from renewal_requests where customer_id = acc.id order by created_at desc limit 50) r;
    return v;
end; $$;

grant execute on function
    cu_request_new_order(uuid, text, integer, text[], text), rn_approve(text, bigint), rn_list(text), cu_my_renewals(uuid)
to anon, authenticated;
