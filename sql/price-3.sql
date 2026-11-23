-- PRICE bagian 3/4: fungsi pelanggan (harga & pesan baru)
-- Jalankan price-1 -> price-2 -> price-3 -> price-4, satu per satu (tempel, Run, lalu file berikutnya).
-- Dipecah dari price.sql karena SQL Editor bisa memotong teks yang terlalu panjang.

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

