-- PRICE bagian 2/4: trigger + fungsi admin
-- Jalankan price-1 -> price-2 -> price-3 -> price-4, satu per satu (tempel, Run, lalu file berikutnya).
-- Dipecah dari price.sql karena SQL Editor bisa memotong teks yang terlalu panjang.

-- ---------------------------------------------------------------------
-- Trigger: harga & pemakaian kode referal tercatat otomatis saat permintaan dibuat
-- ---------------------------------------------------------------------
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
    end if;
    new.harga_normal_hari := (q->>'normal_hari')::integer;
    new.harga_hari := (q->>'harga_hari')::integer;
    new.jumlah_item := v_jumlah;
    new.kode_referal := v_kode;
    new.diskon_referral := (q->>'referral')::integer;
    new.total_harga := (q->>'total')::integer;
    return new;
end; $$;
drop trigger if exists renewal_price_fill_trg on renewal_requests;
create trigger renewal_price_fill_trg before insert on renewal_requests for each row execute function renewal_price_fill();

-- Permintaan dibatalkan pelanggan / ditolak admin -> jatah kode referal dikembalikan
create or replace function renewal_referral_release()
returns trigger language plpgsql security definer set search_path = public, extensions as $$
begin
    if tg_op = 'DELETE' then
        if old.status = 'pending' and old.kode_referal is not null then
            update referral_codes set used_count = greatest(used_count - 1, 0) where upper(kode) = upper(old.kode_referal);
        end if;
        return old;
    end if;
    if old.status = 'pending' and new.status = 'rejected' and old.kode_referal is not null then
        update referral_codes set used_count = greatest(used_count - 1, 0) where upper(kode) = upper(old.kode_referal);
    end if;
    return new;
end; $$;
drop trigger if exists renewal_referral_release_del on renewal_requests;
create trigger renewal_referral_release_del after delete on renewal_requests for each row execute function renewal_referral_release();
drop trigger if exists renewal_referral_release_upd on renewal_requests;
create trigger renewal_referral_release_upd after update of status on renewal_requests for each row execute function renewal_referral_release();

-- ---------------------------------------------------------------------
-- ADMIN (PIN)
-- ---------------------------------------------------------------------
create or replace function pr_get(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    return jsonb_build_object(
        'settings', (select to_jsonb(s) from price_settings s where s.id = 1),
        'special', coalesce((select jsonb_agg(jsonb_build_object('customer_id', sp.customer_id, 'username', ca.username,
                        'bem', sp.bem, 'sem', sp.sem, 'lem', sp.lem, 'catatan', sp.catatan) order by ca.username)
                      from price_special sp join customer_accounts ca on ca.id = sp.customer_id), '[]'::jsonb),
        'codes', coalesce((select jsonb_agg(to_jsonb(c) order by c.id desc) from referral_codes c), '[]'::jsonb)
    );
end; $$;

create or replace function pr_save_default(p_pin text, p_bem integer, p_sem integer, p_lem integer)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    if least(coalesce(p_bem, -1), coalesce(p_sem, -1), coalesce(p_lem, -1)) < 0 then raise exception 'Harga tidak boleh kosong atau negatif'; end if;
    if greatest(p_bem, p_sem, p_lem) > 100000000 then raise exception 'Harga terlalu besar'; end if;
    update price_settings set bem = p_bem, sem = p_sem, lem = p_lem, updated_at = now() where id = 1;
end; $$;

create or replace function pr_save_diskon(p_pin text, p_aktif boolean, p_persen integer, p_label text, p_bem boolean, p_sem boolean, p_lem boolean)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    if p_persen is null or p_persen < 0 or p_persen > 100 then raise exception 'Persen diskon harus 0 sampai 100'; end if;
    update price_settings set diskon_aktif = coalesce(p_aktif, false), diskon_persen = p_persen, diskon_label = left(trim(coalesce(p_label, '')), 60),
           diskon_bem = coalesce(p_bem, true), diskon_sem = coalesce(p_sem, true), diskon_lem = coalesce(p_lem, true), updated_at = now() where id = 1;
end; $$;

-- harga kosong / 0 = pakai harga default untuk paket itu (tetap tercatat sebagai pelanggan istimewa)
create or replace function pr_special_save(p_pin text, p_customer_id bigint, p_bem integer, p_sem integer, p_lem integer, p_catatan text)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    if not exists (select 1 from customer_accounts where id = p_customer_id) then raise exception 'Akun pelanggan tidak ditemukan'; end if;
    if greatest(coalesce(p_bem, 0), coalesce(p_sem, 0), coalesce(p_lem, 0)) > 100000000 or least(coalesce(p_bem, 0), coalesce(p_sem, 0), coalesce(p_lem, 0)) < 0 then raise exception 'Harga tidak valid'; end if;
    insert into price_special (customer_id, bem, sem, lem, catatan, updated_at)
    values (p_customer_id, nullif(p_bem, 0), nullif(p_sem, 0), nullif(p_lem, 0), left(trim(coalesce(p_catatan, '')), 200), now())
    on conflict (customer_id) do update set bem = excluded.bem, sem = excluded.sem, lem = excluded.lem, catatan = excluded.catatan, updated_at = now();
end; $$;

create or replace function pr_special_delete(p_pin text, p_customer_id bigint)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    delete from price_special where customer_id = p_customer_id;
end; $$;

create or replace function pr_code_save(p_pin text, p_id bigint, p_kode text, p_tipe text, p_nilai integer, p_max_uses integer, p_aktif boolean, p_expires timestamptz)
returns bigint language plpgsql security definer set search_path = public, extensions as $$
declare v_kode text := upper(trim(coalesce(p_kode, ''))); v_id bigint;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    if v_kode !~ '^[A-Z0-9_-]{3,32}$' then raise exception 'Kode referal 3-32 karakter: huruf, angka, - atau _'; end if;
    if p_tipe not in ('persen', 'nominal') then raise exception 'Jenis potongan tidak valid'; end if;
    if p_nilai is null or p_nilai < 1 then raise exception 'Nilai potongan minimal 1'; end if;
    if p_tipe = 'persen' and p_nilai > 100 then raise exception 'Potongan persen maksimal 100'; end if;
    if p_max_uses is null or p_max_uses < 1 then raise exception 'Batas pemakaian minimal 1 kali'; end if;
    if exists (select 1 from referral_codes where upper(kode) = v_kode and id is distinct from p_id) then raise exception 'Kode referal sudah ada'; end if;
    if p_id is null then
        insert into referral_codes (kode, tipe, nilai, max_uses, aktif, expires_at)
        values (v_kode, p_tipe, p_nilai, p_max_uses, coalesce(p_aktif, true), p_expires) returning id into v_id;
    else
        update referral_codes set kode = v_kode, tipe = p_tipe, nilai = p_nilai, max_uses = p_max_uses, aktif = coalesce(p_aktif, aktif), expires_at = p_expires
         where id = p_id returning id into v_id;
        if v_id is null then raise exception 'Kode referal tidak ditemukan'; end if;
    end if;
    return v_id;
end; $$;

create or replace function pr_code_delete(p_pin text, p_id bigint)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    delete from referral_codes where id = p_id;
end; $$;

