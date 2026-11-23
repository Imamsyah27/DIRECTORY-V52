-- =====================================================================
-- KOIN + USDT + KETERSEDIAAN — BAGIAN 3/8: Bot Order memakai koin + ketersediaan
-- Jalankan BERURUTAN: bagian 1 s/d 8 (masing-masing sekali; aman diulang).
-- Dipecah karena SQL Editor Supabase memotong skrip di sekitar 20.000 karakter.
-- Butuh bagian 2 (coin_apply) sudah jalan.
-- =====================================================================

-- ---------------------------------------------------------------------
-- BOT ORDER: cek ketersediaan + potong koin + kembalikan koin bila ditolak / dihapus (menunggu)
-- ---------------------------------------------------------------------
create or replace function cu_request_bot_order(p_session_token uuid, p_dashboard text, p_tagar_list text[], p_catatan text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
    acc customer_accounts%rowtype; s price_settings%rowtype; sp price_special%rowtype; cp price_custom%rowtype;
    v_dash text := upper(trim(coalesce(p_dashboard, '')));
    v_list text[] := '{}'; v_norm text[] := '{}'; x text; n text;
    v_note text := nullif(left(trim(coalesce(p_catatan, '')), 500), '');
    v_harga integer; v_id bigint; v_total bigint;
begin
    acc := portal_session_acc(p_session_token);
    if v_dash not in ('BEM', 'SEM', 'LEM') then raise exception 'Paket tidak valid'; end if;
    foreach x in array coalesce(p_tagar_list, '{}') loop
        x := trim(x);
        continue when x = '';
        if length(x) > 100 then raise exception 'Tagar maksimal 100 karakter'; end if;
        n := lower(replace(x, '#', ''));
        if not (n = any(v_norm)) then v_list := v_list || x; v_norm := v_norm || n; end if;
    end loop;
    if cardinality(v_list) = 0 then raise exception 'Tagar wajib diisi'; end if;
    if cardinality(v_list) > 500 then raise exception 'Maksimal 500 tagar per pesanan'; end if;

    select * into s from price_settings where id = 1;
    if not (case v_dash when 'BEM' then s.avail_bot_bem when 'SEM' then s.avail_bot_sem else s.avail_bot_lem end) then
        raise exception 'Bot Order % sedang tidak tersedia', v_dash;
    end if;
    select * into sp from price_special where customer_id = acc.id;      -- Harga Pelanggan (istimewa)
    select * into cp from price_custom where customer_id = acc.id;       -- Custom Price (tersembunyi) — menang atas semuanya
    v_harga := coalesce(nullif(case v_dash when 'BEM' then cp.bot_bem when 'SEM' then cp.bot_sem else cp.bot_lem end, 0),
                        nullif(case v_dash when 'BEM' then sp.bot_bem when 'SEM' then sp.bot_sem else sp.bot_lem end, 0),
                        case v_dash when 'BEM' then s.bot_bem when 'SEM' then s.bot_sem else s.bot_lem end);
    if coalesce(v_harga, 0) <= 0 then raise exception 'Harga Bot Order belum diatur admin'; end if;
    v_total := v_harga::bigint * cardinality(v_list);

    insert into bot_orders (customer_id, username, dashboard, tagar_list, jumlah, catatan_pelanggan, harga_tagar, total_harga, koin_dipotong)
    values (acc.id, acc.username, v_dash, v_list, cardinality(v_list), v_note, v_harga, v_total, v_total)
    returning id into v_id;
    perform coin_apply(acc.id, -v_total, 'order', 'Bot Order ' || v_dash || ' · ' || cardinality(v_list) || ' tagar', 'bot', v_id);
    return jsonb_build_object('id', v_id, 'status', 'pending', 'jumlah', cardinality(v_list), 'harga_tagar', v_harga, 'total', v_total);
end; $$;

create or replace function bot_reject(p_pin text, p_id bigint, p_catatan text default null)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare b bot_orders%rowtype;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    select * into b from bot_orders where id = p_id and status = 'pending' for update;
    if not found then raise exception 'Pesanan tidak ditemukan atau sudah diproses'; end if;
    update bot_orders set status = 'rejected', processed_at = now(), catatan_admin = nullif(left(trim(coalesce(p_catatan, '')), 300), '') where id = p_id;
    if b.koin_dipotong > 0 then
        perform coin_apply(b.customer_id, b.koin_dipotong, 'refund', 'Bot Order ditolak #' || b.id, 'bot', b.id);
    end if;
end; $$;

create or replace function bot_delete(p_pin text, p_id bigint)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare b bot_orders%rowtype;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    select * into b from bot_orders where id = p_id for update;
    if not found then return; end if;
    if b.status = 'pending' and b.koin_dipotong > 0 then      -- masih menunggu: koin dikembalikan
        perform coin_apply(b.customer_id, b.koin_dipotong, 'refund', 'Bot Order dihapus #' || b.id, 'bot', b.id);
    end if;
    delete from bot_orders where id = p_id;
end; $$;

grant execute on function
    cu_request_bot_order(uuid, text, text[], text), bot_reject(text, bigint, text), bot_delete(text, bigint)
to anon, authenticated;
