-- =====================================================================
-- CUSTOM PRICE — BAGIAN 8/8: harga HARIAN BEM/SEM/LEM memakai Custom Price
-- Jalankan SETELAH bagian 1 (tabel price_custom) dan referral-sekali.sql. Aman diulang.
--
-- Menggantikan price_calc: bila akun punya Custom Price untuk paket itu, harga tersebut dipakai
-- sebagai harga biasa — TIDAK ada coretan, label, maupun harga umum di data yang dikirim ke pelanggan.
-- Custom Price tidak mendapat diskon umum / harga istimewa (kode referal tetap berlaku).
-- =====================================================================
create or replace function price_calc(p_customer_id bigint, p_dashboard text, p_hari integer, p_jumlah integer, p_kode text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
    s price_settings%rowtype; sp price_special%rowtype; cp price_custom%rowtype; rc referral_codes%rowtype;
    v_dash text := upper(coalesce(p_dashboard, ''));
    v_istimewa boolean := false; v_normal integer; v_hari_price integer; v_special integer; v_custom integer; v_jenis text;
    v_sub bigint; v_ref bigint := 0; v_kode text := nullif(upper(trim(coalesce(p_kode, ''))), '');
    v_kode_ok boolean; v_msg text; v_pakai_diskon boolean;
begin
    select * into s from price_settings where id = 1;
    v_normal := case v_dash when 'BEM' then s.bem when 'SEM' then s.sem else s.lem end;
    v_hari_price := v_normal;

    select * into cp from price_custom where customer_id = p_customer_id;
    if found then v_custom := case v_dash when 'BEM' then cp.bem when 'SEM' then cp.sem else cp.lem end; end if;

    if coalesce(v_custom, 0) > 0 then
        v_normal := v_custom; v_hari_price := v_custom;       -- tampil sebagai harga biasa (harga umum tidak pernah dikirim)
    else
        select * into sp from price_special where customer_id = p_customer_id;
        v_istimewa := found;
        if v_istimewa then
            v_special := case v_dash when 'BEM' then sp.bem when 'SEM' then sp.sem else sp.lem end;
            if v_special is not null then v_hari_price := v_special; v_jenis := 'istimewa'; end if;
        else
            v_pakai_diskon := s.diskon_aktif and s.diskon_persen > 0
                              and (case v_dash when 'BEM' then s.diskon_bem when 'SEM' then s.diskon_sem else s.diskon_lem end);
            if v_pakai_diskon then
                v_hari_price := round(v_normal * (100 - s.diskon_persen) / 100.0)::integer;
                v_jenis := 'diskon';
            end if;
        end if;
    end if;

    v_sub := v_hari_price::bigint * greatest(coalesce(p_hari, 0), 0) * greatest(coalesce(p_jumlah, 1), 1);

    if v_kode is not null then
        select * into rc from referral_codes where upper(kode) = v_kode;
        if not found then v_kode_ok := false; v_msg := 'Kode referal tidak ditemukan';
        elsif not rc.aktif then v_kode_ok := false; v_msg := 'Kode referal tidak aktif';
        elsif rc.expires_at is not null and rc.expires_at < now() then v_kode_ok := false; v_msg := 'Kode referal sudah kedaluwarsa';
        elsif rc.used_count >= rc.max_uses then v_kode_ok := false; v_msg := 'Kode referal sudah habis dipakai';
        elsif exists (select 1 from referral_uses ru where ru.code_id = rc.id and ru.customer_id = p_customer_id) then
            v_kode_ok := false; v_msg := 'Kode referal ini sudah pernah Anda pakai';
        else
            v_kode_ok := true;
            v_ref := case rc.tipe when 'persen' then floor(v_sub * rc.nilai / 100.0) else least(rc.nilai::bigint, v_sub) end;
        end if;
    end if;

    return jsonb_build_object(
        'dashboard', v_dash, 'hari', p_hari, 'jumlah', p_jumlah,
        'normal_hari', v_normal, 'harga_hari', v_hari_price, 'jenis', v_jenis, 'istimewa', v_istimewa,
        'diskon_label', case when v_jenis = 'diskon' then s.diskon_label end, 'diskon_persen', case when v_jenis = 'diskon' then s.diskon_persen end,
        'subtotal', v_sub, 'referral', v_ref, 'kode', v_kode, 'kode_ok', v_kode_ok, 'kode_pesan', v_msg,
        'kode_tipe', rc.tipe, 'kode_nilai', rc.nilai,
        'total', greatest(v_sub - v_ref, 0)
    );
end; $$;
