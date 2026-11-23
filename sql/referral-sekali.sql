-- =====================================================================
-- KODE REFERAL: SATU KALI PAKAI PER PELANGGAN
-- Jalankan SEKALI di Supabase SQL Editor, SETELAH price-1 ... price-4 (atau price.sql).
-- Aman dijalankan ulang.
--
-- Aturan: tiap pelanggan hanya bisa memakai satu kode referal tertentu 1 kali.
--   Contoh: kode "HEMAT" batas 10 kali = bisa dipakai 10 pelanggan berbeda, masing-masing 1 kali.
--   Jika permintaan dibatalkan pelanggan / ditolak admin, kode itu BOLEH dipakai lagi oleh pelanggan tersebut
--   (jatah kode juga dikembalikan). Pemakaian yang sudah disetujui tetap tercatat dan tidak bisa diulang.
-- =====================================================================

create table if not exists referral_uses (
    id bigint generated always as identity primary key,
    code_id bigint not null references referral_codes(id) on delete cascade,
    customer_id bigint not null references customer_accounts(id) on delete cascade,
    request_id bigint,
    created_at timestamptz not null default now(),
    unique (code_id, customer_id)
);
alter table referral_uses enable row level security;      -- tanpa policy publik

-- Data lama: pemakaian yang masih menunggu / sudah disetujui dicatat sebagai "sudah dipakai"
insert into referral_uses (code_id, customer_id, request_id)
select distinct on (rc.id, r.customer_id) rc.id, r.customer_id, r.id
  from renewal_requests r
  join referral_codes rc on upper(rc.kode) = upper(r.kode_referal)
 where r.kode_referal is not null and r.status in ('pending', 'approved')
 order by rc.id, r.customer_id, r.id
on conflict (code_id, customer_id) do nothing;

create or replace function price_calc(p_customer_id bigint, p_dashboard text, p_hari integer, p_jumlah integer, p_kode text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
    s price_settings%rowtype; sp price_special%rowtype; rc referral_codes%rowtype;
    v_dash text := upper(coalesce(p_dashboard, ''));
    v_istimewa boolean; v_normal integer; v_hari_price integer; v_special integer; v_jenis text;
    v_sub bigint; v_ref bigint := 0; v_kode text := nullif(upper(trim(coalesce(p_kode, ''))), '');
    v_kode_ok boolean; v_msg text; v_pakai_diskon boolean;
begin
    select * into s from price_settings where id = 1;
    v_normal := case v_dash when 'BEM' then s.bem when 'SEM' then s.sem else s.lem end;
    v_hari_price := v_normal;

    select * into sp from price_special where customer_id = p_customer_id;
    v_istimewa := found;

    if v_istimewa then
        v_special := case v_dash when 'BEM' then sp.bem when 'SEM' then sp.sem else sp.lem end;
        if v_special is not null then v_hari_price := v_special; v_jenis := 'istimewa'; end if;
        -- pelanggan istimewa TIDAK mendapat diskon umum
    else
        v_pakai_diskon := s.diskon_aktif and s.diskon_persen > 0
                          and (case v_dash when 'BEM' then s.diskon_bem when 'SEM' then s.diskon_sem else s.diskon_lem end);
        if v_pakai_diskon then
            v_hari_price := round(v_normal * (100 - s.diskon_persen) / 100.0)::integer;
            v_jenis := 'diskon';
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

create or replace function renewal_price_fill()
returns trigger language plpgsql security definer set search_path = public, extensions as $$
declare q jsonb; v_jumlah integer; v_kode text := nullif(upper(trim(coalesce(new.kode_referal, ''))), '');
begin
    v_jumlah := coalesce(cardinality(new.tagar_list), 1);
    q := price_calc(new.customer_id, new.dashboard_baru, new.hari, v_jumlah, v_kode);
    if v_kode is not null then
        if not coalesce((q->>'kode_ok')::boolean, false) then raise exception '%', coalesce(q->>'kode_pesan', 'Kode referal tidak valid'); end if;
        update referral_codes set used_count = used_count + 1
         where upper(kode) = v_kode and aktif and used_count < max_uses and (expires_at is null or expires_at >= now());
        if not found then raise exception 'Kode referal sudah habis dipakai'; end if;
        begin
            insert into referral_uses (code_id, customer_id, request_id)
            select id, new.customer_id, new.id from referral_codes where upper(kode) = v_kode;
        exception when unique_violation then
            raise exception 'Kode referal ini sudah pernah Anda pakai';
        end;
    end if;
    new.harga_normal_hari := (q->>'normal_hari')::integer;
    new.harga_hari := (q->>'harga_hari')::integer;
    new.jumlah_item := v_jumlah;
    new.kode_referal := v_kode;
    new.diskon_referral := (q->>'referral')::integer;
    new.total_harga := (q->>'total')::integer;
    return new;
end; $$;

create or replace function renewal_referral_release()
returns trigger language plpgsql security definer set search_path = public, extensions as $$
begin
    if tg_op = 'DELETE' then
        if old.status = 'pending' and old.kode_referal is not null then
            update referral_codes set used_count = greatest(used_count - 1, 0) where upper(kode) = upper(old.kode_referal);
            delete from referral_uses where request_id = old.id;
        end if;
        return old;
    end if;
    if old.status = 'pending' and new.status = 'rejected' and old.kode_referal is not null then
        update referral_codes set used_count = greatest(used_count - 1, 0) where upper(kode) = upper(old.kode_referal);
        delete from referral_uses where request_id = old.id;
    end if;
    return new;
end; $$;

-- penerima kode: pelanggan yang sudah memakai (untuk halaman Price admin)
create or replace function pr_get(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    return jsonb_build_object(
        'settings', (select to_jsonb(s) from price_settings s where s.id = 1),
        'special', coalesce((select jsonb_agg(jsonb_build_object('customer_id', sp.customer_id, 'username', ca.username,
                        'bem', sp.bem, 'sem', sp.sem, 'lem', sp.lem, 'catatan', sp.catatan) order by ca.username)
                      from price_special sp join customer_accounts ca on ca.id = sp.customer_id), '[]'::jsonb),
        'codes', coalesce((select jsonb_agg(to_jsonb(c) || jsonb_build_object('pengguna',
                        coalesce((select string_agg(ca.username, ', ' order by ru.created_at) from referral_uses ru
                                   join customer_accounts ca on ca.id = ru.customer_id where ru.code_id = c.id), ''))
                        order by c.id desc) from referral_codes c), '[]'::jsonb)
    );
end; $$;

grant execute on function pr_get(text) to anon, authenticated;
