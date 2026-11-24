-- =====================================================================
-- MIGRASI 011 — BATAS JAM PENGIRIMAN (UTC) PER PROSES + TANDA "KIRIM BESOK"
-- Jalankan SEKALI di Supabase SQL Editor, SETELAH migrasi 007–010. Aman diulang.
--
-- * bot_packages.batas_utc : batas jam kirim hari ini, dalam MENIT sejak 00:00 UTC (720 = 12:00 UTC); null = tanpa batas.
--   Default saat kolom dibuat: 2F = 12:00 UTC, 1F = tanpa batas. Diubah admin di Price -> Proses Pengiriman Bot.
-- * Batas jam TIDAK memblokir pemesanan. Pesanan yang masuk setelah batas jam tetap diterima (pre order) dan
--   ditandai bot_orders.kirim_besok = true -> dikirim besok mulai 00:00 UTC. Tanda dihitung dari JAM SERVER (UTC).
-- Order lama: kirim_besok = false. Bulk Order tidak berubah.
-- =====================================================================

-- 1. Kolom ------------------------------------------------------------------
do $$
begin
    if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'bot_packages' and column_name = 'batas_utc') then
        alter table bot_packages add column batas_utc smallint check (batas_utc is null or batas_utc between 0 and 1439);
        update bot_packages set batas_utc = 720 where proses = '2F';      -- default awal (hanya saat kolom baru dibuat)
    end if;
end $$;
alter table bot_orders add column if not exists kirim_besok boolean not null default false;

-- 2. ADMIN: ubah batas jam (menit sejak 00:00 UTC; null = tanpa batas) -------------
create or replace function bot_pkg_set_batas(p_pin text, p_proses text, p_batas_utc integer)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    if upper(coalesce(p_proses, '')) not in ('1F', '2F') then raise exception 'Proses harus 1F atau 2F'; end if;
    if p_batas_utc is not null and (p_batas_utc < 0 or p_batas_utc > 1439) then raise exception 'Batas jam harus 00:00 – 23:59 UTC'; end if;
    update bot_packages set batas_utc = p_batas_utc, updated_at = now() where proses = upper(p_proses);
end; $$;

-- 3. ADMIN: pengaturan proses ikut membawa batas jam (sama dengan migrasi 007 + batas_utc)
create or replace function bot_pkg_list(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    return coalesce((select jsonb_agg(jsonb_build_object('proses', proses, 'nama', nama, 'notes', notes, 'aktif', aktif,
                        'harga_bem', harga_bem, 'harga_sem', harga_sem, 'harga_lem', harga_lem,
                        'buka_bem', buka_bem, 'buka_sem', buka_sem, 'buka_lem', buka_lem, 'batas_utc', batas_utc, 'updated_at', updated_at) order by proses)
                       from bot_packages), '[]'::jsonb);
end; $$;

-- 4. PELANGGAN: pengaturan proses (cache 10 menit di browser) ikut membawa batas jam (sama dengan 007 + batas_utc)
create or replace function cu_bot_packages(p_session_token uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare acc customer_accounts%rowtype;
begin
    acc := portal_session_acc(p_session_token);
    return coalesce((select jsonb_agg(jsonb_build_object('proses', k.proses, 'nama', k.nama, 'notes', k.notes, 'batas_utc', k.batas_utc,
                        'harga', (select coalesce(jsonb_object_agg(d.dash, pi_final(acc.id, 'bot:' || k.proses || ':' || d.dash, bot_pkg_price(k.proses, d.dash))), '{}'::jsonb)
                                    from (values ('BEM'), ('SEM'), ('LEM')) d(dash) where bot_pkg_price(k.proses, d.dash) > 0 and bot_pkg_open(k.proses, d.dash)),
                        'normal', (select coalesce(jsonb_object_agg(d.dash, pi_normal(acc.id, 'bot:' || k.proses || ':' || d.dash, bot_pkg_price(k.proses, d.dash))), '{}'::jsonb)
                                    from (values ('BEM'), ('SEM'), ('LEM')) d(dash) where bot_pkg_price(k.proses, d.dash) > 0 and bot_pkg_open(k.proses, d.dash)))
                        order by k.proses)
                       from bot_packages k where k.aktif), '[]'::jsonb);
end; $$;

-- 5. PEMESANAN: sama dengan migrasi 010 + tanda kirim_besok dari jam server
create or replace function cu_request_bot_order(p_session_token uuid, p_dashboard text, p_tagar_list text[], p_catatan text default null, p_proses text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
    acc customer_accounts%rowtype; v_aktif boolean; v_nama text; v_batas smallint; v_besok boolean;
    v_dash text := upper(trim(coalesce(p_dashboard, '')));
    v_pro text := upper(trim(coalesce(p_proses, '')));
    v_list text[] := '{}'; v_norm text[] := '{}'; x text; n text;
    v_note text := nullif(left(trim(coalesce(p_catatan, '')), 500), '');
    v_harga bigint; v_id bigint; v_total bigint;
begin
    acc := portal_session_acc(p_session_token);
    if v_pro = '' then raise exception 'Pilih proses pengiriman'; end if;
    if v_pro not in ('1F', '2F') then raise exception 'Proses pengiriman tidak valid'; end if;
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

    -- ketersediaan HANYA per kombinasi proses + jenis (saklar lama "BEM/SEM/LEM Bot tersedia" tidak dibaca lagi)
    select aktif, nama, batas_utc into v_aktif, v_nama, v_batas from bot_packages where proses = v_pro;
    -- lewat batas jam (dihitung dari jam SERVER, UTC) -> tetap boleh pesan, ditandai kirim besok mulai 00:00 UTC
    v_besok := v_batas is not null and (extract(hour from now() at time zone 'UTC') * 60 + extract(minute from now() at time zone 'UTC')) >= v_batas;
    if not coalesce(v_aktif, false) then raise exception 'Proses pengiriman ini sedang tidak tersedia'; end if;
    if not bot_pkg_open(v_pro, v_dash) then raise exception 'Pemesanan proses dan jenis ini sedang ditutup'; end if;
    -- harga dihitung di server: Custom Price -> Harga Pelanggan -> harga proses (harga dari browser tidak dipakai)
    v_harga := pi_final(acc.id, 'bot:' || v_pro || ':' || v_dash, bot_pkg_price(v_pro, v_dash));
    if coalesce(v_harga, 0) <= 0 then raise exception 'Harga Bot Order belum diatur admin'; end if;
    v_total := v_harga * cardinality(v_list);

    insert into bot_orders (customer_id, username, dashboard, proses, kirim_besok, tagar_list, jumlah, catatan_pelanggan, harga_tagar, total_harga, koin_dipotong)
    values (acc.id, acc.username, v_dash, v_pro, v_besok, v_list, cardinality(v_list), v_note, v_harga, v_total, v_total)
    returning id into v_id;
    perform coin_apply(acc.id, -v_total, 'order', 'Bot Order ' || v_dash || ' · ' || v_nama || ' · ' || cardinality(v_list) || ' tagar', 'bot', v_id);
    return jsonb_build_object('id', v_id, 'status', 'pending', 'jumlah', cardinality(v_list), 'harga_tagar', v_harga, 'total', v_total, 'proses', v_pro, 'kirim_besok', v_besok);
end; $$;

-- 6. Daftar pesanan ikut membawa kirim_besok (sama dengan migrasi 008 + kirim_besok)
create or replace function bot_list(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v jsonb;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    select coalesce(jsonb_agg(to_jsonb(r) order by r.created_at desc), '[]'::jsonb) into v
    from (select b.id, b.username, b.dashboard, b.proses, b.kirim_besok, b.jumlah, b.tagar_list[1] as tagar_pertama, b.catatan_pelanggan,
                 b.harga_tagar, b.total_harga, b.status, b.catatan_admin, b.created_at, b.processed_at,
                 b.dikirim_at, b.arsip, b.arsip_at, b.bulk_tier,
                 coalesce(cardinality(b.tagar_bem), 0) as n_bem, coalesce(cardinality(b.tagar_sem), 0) as n_sem, coalesce(cardinality(b.tagar_lem), 0) as n_lem,
                 q.q_total, q.q_bem, q.q_sem, q.q_lem,
                 (select ca.whatsapp from customer_accounts ca where ca.id = b.customer_id) as whatsapp
            from bot_orders b
            left join lateral (
                select count(*)::int as q_total,
                       count(*) filter (where qq.dashboard = 'BEM' and qq.status = 'pending')::int as q_bem,
                       count(*) filter (where qq.dashboard = 'SEM' and qq.status = 'pending')::int as q_sem,
                       count(*) filter (where qq.dashboard = 'LEM' and qq.status = 'pending')::int as q_lem
                  from bot_queue qq where qq.order_id = b.id and qq.status in ('pending', 'sent', 'archived')) q on true
           order by b.created_at desc limit 500) r;
    return v;
end; $$;

create or replace function cu_my_bot_orders(p_session_token uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare acc customer_accounts%rowtype; v jsonb;
begin
    acc := portal_session_acc(p_session_token);
    select coalesce(jsonb_agg(jsonb_build_object(
        'id', b.id, 'dashboard', b.dashboard, 'proses', b.proses, 'kirim_besok', b.kirim_besok, 'jumlah', b.jumlah, 'tagar_pertama', b.tagar_list[1],
        'harga_tagar', b.harga_tagar, 'total_harga', b.total_harga, 'status', b.status,
        'catatan_admin', b.catatan_admin, 'created_at', b.created_at, 'processed_at', b.processed_at,
        'dikirim_at', b.dikirim_at, 'arsip', b.arsip, 'bulk_tier', b.bulk_tier,
        'n_bem', coalesce(cardinality(b.tagar_bem), 0), 'n_sem', coalesce(cardinality(b.tagar_sem), 0), 'n_lem', coalesce(cardinality(b.tagar_lem), 0)
    ) order by b.created_at desc), '[]'::jsonb) into v
    from (select id, dashboard, proses, kirim_besok, jumlah, tagar_list, harga_tagar, total_harga, status, catatan_admin, created_at, processed_at,
                 dikirim_at, arsip, bulk_tier, tagar_bem, tagar_sem, tagar_lem
            from bot_orders where customer_id = acc.id order by created_at desc limit 100) b;
    return v;
end; $$;

grant execute on function bot_pkg_set_batas(text, text, integer), bot_pkg_list(text), cu_bot_packages(uuid),
    cu_request_bot_order(uuid, text, text[], text, text), bot_list(text), cu_my_bot_orders(uuid) to anon, authenticated;
