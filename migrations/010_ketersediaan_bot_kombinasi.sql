-- =====================================================================
-- MIGRASI 010 — KETERSEDIAAN BOT ORDER PER KOMBINASI (1F / 2F × BEM / SEM / LEM)
-- Jalankan SEKALI di Supabase SQL Editor, SETELAH migrasi 007–009. Aman diulang.
--
-- Sebelumnya: saklar "BEM / SEM / LEM Bot tersedia" (price_settings.avail_bot_*) berlaku untuk semua proses,
--             DI ATAS saklar per kombinasi (bot_packages.buka_*).
-- Sekarang:   ketersediaan HANYA diatur per kombinasi: 1F-BEM, 1F-SEM, 1F-LEM, 2F-BEM, 2F-SEM, 2F-LEM
--             (admin: Price -> Proses Pengiriman Bot). Saklar lama tidak dibaca lagi untuk Bot Order.
-- Bulk Order & ketersediaan langganan harian TIDAK diubah.
-- =====================================================================

-- 1. Pindahkan pengaturan lama ke 6 kombinasi — SEKALI saja (penanda avail_lama_dipindah).
--    "BEM Bot tersedia" mati -> 1F-BEM & 2F-BEM ditutup (dst.). Kombinasi yang sudah ditutup admin tetap tertutup.
--    Menjalankan ulang file ini tidak menimpa pengaturan yang diubah admin setelahnya.
alter table bot_packages add column if not exists avail_lama_dipindah boolean not null default false;
update bot_packages k
   set buka_bem = k.buka_bem and coalesce(s.avail_bot_bem, true),
       buka_sem = k.buka_sem and coalesce(s.avail_bot_sem, true),
       buka_lem = k.buka_lem and coalesce(s.avail_bot_lem, true),
       avail_lama_dipindah = true, updated_at = now()
  from price_settings s
 where s.id = 1 and not k.avail_lama_dipindah;

-- 2. Pemesanan: sama dengan migrasi 007, tanpa pengecekan saklar lama price_settings.avail_bot_*.
--    Kombinasi nonaktif tetap DITOLAK di sini (bot_pkg_open).
create or replace function cu_request_bot_order(p_session_token uuid, p_dashboard text, p_tagar_list text[], p_catatan text default null, p_proses text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
    acc customer_accounts%rowtype; v_aktif boolean; v_nama text;
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
    select aktif, nama into v_aktif, v_nama from bot_packages where proses = v_pro;
    if not coalesce(v_aktif, false) then raise exception 'Proses pengiriman ini sedang tidak tersedia'; end if;
    if not bot_pkg_open(v_pro, v_dash) then raise exception 'Pemesanan proses dan jenis ini sedang ditutup'; end if;
    -- harga dihitung di server: Custom Price -> Harga Pelanggan -> harga proses (harga dari browser tidak dipakai)
    v_harga := pi_final(acc.id, 'bot:' || v_pro || ':' || v_dash, bot_pkg_price(v_pro, v_dash));
    if coalesce(v_harga, 0) <= 0 then raise exception 'Harga Bot Order belum diatur admin'; end if;
    v_total := v_harga * cardinality(v_list);

    insert into bot_orders (customer_id, username, dashboard, proses, tagar_list, jumlah, catatan_pelanggan, harga_tagar, total_harga, koin_dipotong)
    values (acc.id, acc.username, v_dash, v_pro, v_list, cardinality(v_list), v_note, v_harga, v_total, v_total)
    returning id into v_id;
    perform coin_apply(acc.id, -v_total, 'order', 'Bot Order ' || v_dash || ' · ' || v_nama || ' · ' || cardinality(v_list) || ' tagar', 'bot', v_id);
    return jsonb_build_object('id', v_id, 'status', 'pending', 'jumlah', cardinality(v_list), 'harga_tagar', v_harga, 'total', v_total, 'proses', v_pro);
end; $$;

grant execute on function cu_request_bot_order(uuid, text, text[], text, text) to anon, authenticated;
