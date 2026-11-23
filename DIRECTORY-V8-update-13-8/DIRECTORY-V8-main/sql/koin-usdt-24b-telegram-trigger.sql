-- =====================================================================
-- KOIN — BAGIAN 24b: NOTIFIKASI TELEGRAM — TRIGGER ORDER MASUK + PEMBUNGKUS (kirim hari ini, kontak, tagar)
-- Jalankan SETELAH koin-usdt-24-telegram.sql (dan 16, 22). Aman diulang.
-- Setiap order baru (langganan, bot/bulk, koin, voucher, supply, pre order, top up, request pelanggan, farm/hav) -> pesan ke admin.
-- Kegagalan Telegram TIDAK mempengaruhi pesanan pelanggan.
-- =====================================================================
create or replace function tg_trg_renewal() returns trigger language plpgsql security definer set search_path = public, extensions as $$
declare k text := nullif(current_setting('app.kirim_waktu', true), '');
begin
    begin
        perform tg_send('langganan', concat_ws(E'\n',
            '🔔 <b>ORDER MASUK — ' || case when new.source = 'new' then 'Langganan Baru' else 'Perpanjangan' end || '</b>',
            '👤 ' || tg_esc(coalesce(nullif(new.nomor_pesanan, ''), new.username)) || ' <i>(akun ' || tg_esc(new.username) || ')</i>',
            '📦 ' || new.dashboard_baru || ' · ' || new.hari || ' hari' || case when coalesce(new.jumlah_item, 1) > 1 then ' · ' || new.jumlah_item || ' tagar' else '' end,
            '🏷 ' || tg_esc(case when new.tagar_list is not null and cardinality(new.tagar_list) > 0 then tg_tags(new.tagar_list) else new.tagar_baru end),
            '💰 ' || tg_rp(new.total_harga) || case when new.kode_referal is not null then ' · kode ' || tg_esc(new.kode_referal) else '' end,
            case k when 'hari_ini' then '🔥 <b>KIRIM HARI INI</b>' when 'besok' then '📅 Kirim besok' end,
            case when coalesce(new.catatan_pelanggan, '') <> '' then '📝 ' || tg_esc(left(new.catatan_pelanggan, 200)) end,
            '🕒 ' || tg_now() || ' · #' || new.id));
    exception when others then null; end;
    return null;
end; $$;

create or replace function tg_trg_bot() returns trigger language plpgsql security definer set search_path = public, extensions as $$
begin
    begin
        perform tg_send(case when new.dashboard = 'BULK' then 'bulk' else 'bot' end, concat_ws(E'\n',
            '🔔 <b>ORDER MASUK — ' || case when new.dashboard = 'BULK' then 'Bulk Order' else 'Bot ' || new.dashboard end || '</b>',
            '👤 ' || tg_esc(new.username),
            case when new.dashboard = 'BULK'
                 then '📦 BEM ' || coalesce(cardinality(new.tagar_bem), 0) || ' · SEM ' || coalesce(cardinality(new.tagar_sem), 0) || ' · LEM ' || coalesce(cardinality(new.tagar_lem), 0) || ' (' || new.jumlah || ' tagar)'
                 else '📦 ' || new.jumlah || ' tagar' end,
            '🏷 ' || tg_esc(tg_tags(new.tagar_list)),
            '💰 ' || tg_rp(new.total_harga),
            case when coalesce(new.catatan_pelanggan, '') <> '' then '📝 ' || tg_esc(left(new.catatan_pelanggan, 200)) end,
            '🕒 ' || tg_now() || ' · #' || new.id));
    exception when others then null; end;
    return null;
end; $$;

create or replace function tg_trg_catalog() returns trigger language plpgsql security definer set search_path = public, extensions as $$
declare kt text := nullif(current_setting('app.kontak', true), ''); tg text := nullif(current_setting('app.tagar', true), '');
begin
    begin
        perform tg_send(case when new.kategori = 'koin' then 'koin' else 'voucher' end, concat_ws(E'\n',
            '🔔 <b>ORDER MASUK — ' || case when new.kategori = 'koin' then 'Koin Hayday' else 'Voucher' end || '</b>',
            '👤 ' || tg_esc(new.username),
            '🛍 ' || tg_esc(new.item_nama) || ' × ' || new.qty,
            '💰 ' || tg_rp(new.total),
            case when tg is not null then '🏷 Tagar: ' || tg_esc(tg) end,
            case when kt is not null then '📱 Kontak: ' || tg_esc(kt) end,
            case when coalesce(new.catatan, '') <> '' then '📝 ' || tg_esc(left(new.catatan, 200)) end,
            '🕒 ' || tg_now() || ' · #' || new.id));
    exception when others then null; end;
    return null;
end; $$;

create or replace function tg_trg_supply() returns trigger language plpgsql security definer set search_path = public, extensions as $$
declare kt text := nullif(current_setting('app.kontak', true), ''); tg text := nullif(current_setting('app.tagar', true), ''); b record;
begin
    begin
        select coalesce(nullif(item, ''), nama) as item, satuan into b from supply_batches where id = new.batch_id;
        perform tg_send('supply', concat_ws(E'\n',
            '🔔 <b>ORDER MASUK — Supply & Stock</b>',
            '👤 ' || tg_esc(new.username),
            '📦 ' || tg_esc(b.item) || ' · ' || new.qty || ' ' || tg_esc(b.satuan),
            '💰 ' || tg_rp(new.harga_total),
            case when tg is not null then '🏷 Tagar: ' || tg_esc(tg) end,
            case when kt is not null then '📱 Kontak: ' || tg_esc(kt) end,
            '🕒 ' || tg_now() || ' · #' || new.id));
    exception when others then null; end;
    return null;
end; $$;

create or replace function tg_trg_preorder() returns trigger language plpgsql security definer set search_path = public, extensions as $$
begin
    begin
        perform tg_send('preorder', concat_ws(E'\n',
            '🔔 <b>ORDER MASUK — Pre Order</b>' || case when new.batch_total > 1 then ' <i>(batch ' || new.batch_no || '/' || new.batch_total || ')</i>' end,
            '👤 ' || tg_esc(new.username),
            '📝 ' || tg_esc(new.item_nama) || ' · ' || to_char(new.total_barang, 'FM999,999,999') || ' barang',
            '🏷 ' || tg_esc((select string_agg(l ->> 'tagar', ', ') from (select l from jsonb_array_elements(new.lines) l limit 8) q)),
            '💰 ' || tg_rp(new.total_koin),
            case when coalesce(new.catatan, '') <> '' then '📝 ' || tg_esc(left(new.catatan, 200)) end,
            '🕒 ' || tg_now() || ' · #' || new.id));
    exception when others then null; end;
    return null;
end; $$;

create or replace function tg_trg_topup() returns trigger language plpgsql security definer set search_path = public, extensions as $$
begin
    begin
        perform tg_send('topup', concat_ws(E'\n', '🔔 <b>ORDER MASUK — Top Up Koin</b>', '👤 ' || tg_esc(new.username), '🪙 ' || to_char(new.jumlah, 'FM999,999,999,999') || ' koin', '🕒 ' || tg_now() || ' · #' || new.id));
    exception when others then null; end;
    return null;
end; $$;

create or replace function tg_trg_request() returns trigger language plpgsql security definer set search_path = public, extensions as $$
begin
    begin
        perform tg_send('request', concat_ws(E'\n',
            '🔔 <b>REQUEST PELANGGAN — ' || case new.jenis when 'hold' then 'Tunda' when 'activate' then 'Aktifkan kembali' else 'Arsipkan' end || '</b>',
            '👤 ' || tg_esc(coalesce(nullif(new.nomor_pesanan, ''), new.username)),
            '🏷 ' || tg_esc(coalesce(new.tagar, '-')) || ' (' || coalesce(new.dashboard, '') || ')',
            case when coalesce(new.catatan, '') <> '' then '📝 ' || tg_esc(left(new.catatan, 200)) end,
            '🕒 ' || tg_now() || ' · #' || new.id));
    exception when others then null; end;
    return null;
end; $$;

create or replace function tg_trg_sale() returns trigger language plpgsql security definer set search_path = public, extensions as $$
begin
    begin
        perform tg_send(case when TG_TABLE_NAME = 'hav_sales' then 'hav' else 'farm' end, concat_ws(E'\n',
            '🛒 <b>Pembelian ' || case when TG_TABLE_NAME = 'hav_sales' then 'HAV Token' else 'Farm Token' end || '</b> <i>(otomatis terkirim)</i>',
            '👤 ' || tg_esc(new.username), '📦 ' || tg_esc(new.batch_nama) || ' × ' || new.qty, '💰 ' || tg_rp(new.total), '🕒 ' || tg_now()));
    exception when others then null; end;
    return null;
end; $$;
revoke all on function tg_trg_renewal(), tg_trg_bot(), tg_trg_catalog(), tg_trg_supply(), tg_trg_preorder(), tg_trg_topup(), tg_trg_request(), tg_trg_sale() from public, anon, authenticated;

do $$
declare spec text; tb text; fn text;
begin
    foreach spec in array array['renewal_requests:tg_trg_renewal', 'bot_orders:tg_trg_bot', 'catalog_orders:tg_trg_catalog', 'supply_orders:tg_trg_supply',
        'preorder_orders:tg_trg_preorder', 'coin_topups:tg_trg_topup', 'order_requests:tg_trg_request', 'farm_sales:tg_trg_sale', 'hav_sales:tg_trg_sale'] loop
        tb := split_part(spec, ':', 1); fn := split_part(spec, ':', 2);
        if to_regclass('public.' || tb) is not null then
            execute format('drop trigger if exists zz_tg_notify on public.%I', tb);
            execute format('create trigger zz_tg_notify after insert on public.%I for each row execute function %I()', tb, fn);
        end if;
    end loop;
end $$;

-- pembungkus yang menitipkan info (kirim hari ini / kontak / tagar) ke trigger lewat pengaturan sesi sementara
create or replace function cu_request_new_order_k(p_session_token uuid, p_dashboard text, p_hari integer, p_tagar_list text[],
                                                  p_catatan text default null, p_kode text default null, p_hari_ini boolean default false)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare r jsonb; acc customer_accounts%rowtype;
begin
    acc := portal_session_acc(p_session_token);
    perform set_config('app.kirim_waktu', case when coalesce(p_hari_ini, false) then 'hari_ini' else 'besok' end, true);
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
    perform set_config('app.kirim_waktu', case when coalesce(p_hari_ini, false) then 'hari_ini' else 'besok' end, true);
    r := cu_request_renewal(p_session_token, p_source, p_source_id, p_dashboard, p_hari, p_tagar_baru, p_kode);
    update renewal_requests set kirim_waktu = case when coalesce(p_hari_ini, false) then 'hari_ini' else 'besok' end
     where id = (r->>'id')::bigint and customer_id = acc.id;
    return r;
end; $$;

create or replace function cu_place_supply_order_k(p_session_token uuid, p_batch_id bigint, p_qty integer, p_catatan text default null,
                                                   p_kontak text default null, p_tagar text default null)
returns bigint language plpgsql security definer set search_path = public, extensions as $$
declare v_id bigint; acc customer_accounts%rowtype; v_kontak text := trim(coalesce(p_kontak, '')); v_tagar text := trim(coalesce(p_tagar, ''));
begin
    acc := portal_session_acc(p_session_token);
    if not valid_kontak(v_kontak) then raise exception 'Kontak wajib diisi: nomor WhatsApp atau link profil Messenger yang valid'; end if;
    if v_tagar = '' then raise exception 'Tagar akun yang akan dikirim wajib diisi'; end if;
    perform set_config('app.kontak', v_kontak, true); perform set_config('app.tagar', v_tagar, true);
    v_id := cu_place_supply_order(p_session_token, p_batch_id, p_qty);
    update supply_orders set catatan = nullif(left(trim(coalesce(p_catatan, '')), 500), ''), kontak = left(v_kontak, 200), tagar = left(v_tagar, 200)
     where id = v_id and customer_id = acc.id;
    return v_id;
end; $$;

create or replace function cu_order_catalog_k(p_session_token uuid, p_item_id bigint, p_qty integer, p_catatan text default null,
                                              p_kontak text default null, p_tagar text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare r jsonb; acc customer_accounts%rowtype; v_kontak text := trim(coalesce(p_kontak, '')); v_tagar text := trim(coalesce(p_tagar, ''));
begin
    acc := portal_session_acc(p_session_token);
    if not valid_kontak(v_kontak) then raise exception 'Kontak wajib diisi: nomor WhatsApp atau link profil Messenger yang valid'; end if;
    if v_tagar = '' then raise exception 'Tagar akun yang akan dikirim wajib diisi'; end if;
    perform set_config('app.kontak', v_kontak, true); perform set_config('app.tagar', v_tagar, true);
    r := cu_order_catalog(p_session_token, p_item_id, p_qty, p_catatan);
    update catalog_orders set kontak = left(v_kontak, 200), tagar = left(v_tagar, 200) where id = (r->>'id')::bigint and customer_id = acc.id;
    return r;
end; $$;

grant execute on function cu_request_new_order_k(uuid, text, integer, text[], text, text, boolean),
    cu_request_renewal_k(uuid, text, bigint, text, integer, text, text, boolean),
    cu_place_supply_order_k(uuid, bigint, integer, text, text, text), cu_order_catalog_k(uuid, bigint, integer, text, text, text) to anon, authenticated;
