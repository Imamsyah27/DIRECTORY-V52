-- =====================================================================
-- KOIN + USDT + KETERSEDIAAN — BAGIAN 2/8: Sistem koin
-- Jalankan BERURUTAN: bagian 1 s/d 8 (masing-masing sekali; aman diulang).
-- Dipecah karena SQL Editor Supabase memotong skrip di sekitar 20.000 karakter.
-- Isi: saldo koin, riwayat, potong/kembalikan otomatis, fungsi admin. Butuh bagian 1 sudah jalan.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 3. KOIN
-- ---------------------------------------------------------------------
alter table customer_accounts add column if not exists koin bigint not null default 0 check (koin >= 0);

create table if not exists coin_ledger (
    id bigint generated always as identity primary key,
    customer_id bigint not null references customer_accounts(id) on delete cascade,
    delta bigint not null,
    saldo_after bigint not null,
    jenis text not null check (jenis in ('topup', 'koreksi', 'order', 'refund')),
    keterangan text not null default '',
    ref_type text,
    ref_id bigint,
    created_at timestamptz not null default now()
);
create index if not exists coin_ledger_cust_idx on coin_ledger (customer_id, created_at desc);
alter table coin_ledger enable row level security;      -- tanpa policy publik

alter table renewal_requests add column if not exists koin_dipotong bigint not null default 0;
alter table bot_orders add column if not exists koin_dipotong bigint not null default 0;

-- Fungsi INTERNAL: ubah saldo + catat riwayat (atomik). TIDAK boleh bisa dipanggil publik.
create or replace function coin_apply(p_customer_id bigint, p_delta bigint, p_jenis text, p_ket text, p_ref_type text default null, p_ref_id bigint default null)
returns bigint language plpgsql security definer set search_path = public, extensions as $$
declare v_saldo bigint;
begin
    update customer_accounts set koin = koin + p_delta where id = p_customer_id and koin + p_delta >= 0 returning koin into v_saldo;
    if not found then
        if exists (select 1 from customer_accounts where id = p_customer_id) then raise exception 'Saldo koin tidak cukup'; end if;
        if p_delta > 0 then return 0; end if;      -- akun sudah terhapus (cascade): tidak ada yang perlu dikembalikan
        raise exception 'Akun tidak ditemukan';
    end if;
    insert into coin_ledger (customer_id, delta, saldo_after, jenis, keterangan, ref_type, ref_id)
    values (p_customer_id, p_delta, v_saldo, p_jenis, left(coalesce(p_ket, ''), 200), p_ref_type, p_ref_id);
    return v_saldo;
end; $$;
revoke all on function coin_apply(bigint, bigint, text, text, text, bigint) from public, anon, authenticated;

-- Pesanan langganan (baru / perpanjang): potong koin sebesar total bayar.
-- Nama trigger diawali "renewal_zz" supaya jalan SESUDAH renewal_price_fill_trg (total_harga sudah terisi).
create or replace function renewal_coin_charge()
returns trigger language plpgsql security definer set search_path = public, extensions as $$
begin
    if coalesce(new.total_harga, 0) > 0 then
        perform coin_apply(new.customer_id, -new.total_harga::bigint, 'order',
                           case when new.source = 'new' then 'Pesanan baru ' else 'Perpanjang ' end || upper(new.dashboard_baru) || ' ' || new.hari || ' hari',
                           'renewal', new.id);
        new.koin_dipotong := new.total_harga;
    end if;
    return new;
end; $$;
drop trigger if exists renewal_zz_coin_charge_trg on renewal_requests;
create trigger renewal_zz_coin_charge_trg before insert on renewal_requests for each row execute function renewal_coin_charge();

-- Dibatalkan pelanggan (dihapus saat masih menunggu) / ditolak admin -> koin kembali
create or replace function renewal_coin_refund()
returns trigger language plpgsql security definer set search_path = public, extensions as $$
begin
    if tg_op = 'DELETE' then
        if old.status = 'pending' and old.koin_dipotong > 0 then
            perform coin_apply(old.customer_id, old.koin_dipotong, 'refund', 'Pesanan dibatalkan #' || old.id, 'renewal', old.id);
        end if;
        return old;
    end if;
    if old.status = 'pending' and new.status = 'rejected' and old.koin_dipotong > 0 then
        perform coin_apply(old.customer_id, old.koin_dipotong, 'refund', 'Pesanan ditolak #' || old.id, 'renewal', old.id);
    end if;
    return new;
end; $$;
drop trigger if exists renewal_coin_refund_del on renewal_requests;
create trigger renewal_coin_refund_del after delete on renewal_requests for each row execute function renewal_coin_refund();
drop trigger if exists renewal_coin_refund_upd on renewal_requests;
create trigger renewal_coin_refund_upd after update of status on renewal_requests for each row execute function renewal_coin_refund();

-- Pelanggan: saldo + 30 riwayat terakhir
create or replace function cu_coin_info(p_session_token uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare acc customer_accounts%rowtype;
begin
    acc := portal_session_acc(p_session_token);
    return jsonb_build_object(
        'koin', (select koin from customer_accounts where id = acc.id),
        'riwayat', coalesce((select jsonb_agg(jsonb_build_object('delta', l.delta, 'saldo_after', l.saldo_after, 'jenis', l.jenis,
                                    'keterangan', l.keterangan, 'created_at', l.created_at) order by l.created_at desc, l.id desc)
                               from (select * from coin_ledger where customer_id = acc.id order by created_at desc, id desc limit 30) l), '[]'::jsonb));
end; $$;

-- Admin: saldo semua akun
create or replace function coin_admin_list(p_admin_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_admin_pin) then raise exception 'PIN admin salah'; end if;
    return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'koin', koin)) from customer_accounts), '[]'::jsonb);
end; $$;

-- Admin: isi (+) atau kurangi (-) koin akun yang sudah ada. Saldo tidak boleh negatif.
create or replace function coin_admin_adjust(p_admin_pin text, p_customer_id bigint, p_delta bigint, p_keterangan text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_saldo bigint;
begin
    if not admin_verify_pin(p_admin_pin) then raise exception 'PIN admin salah'; end if;
    if p_delta is null or p_delta = 0 then raise exception 'Jumlah koin tidak boleh 0'; end if;
    if abs(p_delta) > 1000000000 then raise exception 'Jumlah koin terlalu besar'; end if;
    v_saldo := coin_apply(p_customer_id, p_delta, case when p_delta > 0 then 'topup' else 'koreksi' end,
                          coalesce(nullif(trim(p_keterangan), ''), case when p_delta > 0 then 'Top up oleh admin' else 'Koreksi oleh admin' end), 'admin', null);
    return jsonb_build_object('saldo', v_saldo);
end; $$;

-- Admin: riwayat koin 1 akun
create or replace function coin_admin_history(p_admin_pin text, p_customer_id bigint)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_admin_pin) then raise exception 'PIN admin salah'; end if;
    return coalesce((select jsonb_agg(jsonb_build_object('delta', l.delta, 'saldo_after', l.saldo_after, 'jenis', l.jenis,
                                'keterangan', l.keterangan, 'created_at', l.created_at) order by l.created_at desc, l.id desc)
                       from (select * from coin_ledger where customer_id = p_customer_id order by created_at desc, id desc limit 50) l), '[]'::jsonb);
end; $$;

grant execute on function
    cu_coin_info(uuid), coin_admin_list(text), coin_admin_adjust(text, bigint, bigint, text), coin_admin_history(text, bigint)
to anon, authenticated;
