-- =====================================================================
-- KOIN + USDT — BAGIAN 4/8: ORDER TOP UP KOIN (waiting list admin)
-- Jalankan SETELAH bagian 1-3. Aman diulang.
-- Alur: pelanggan "Pesan Top Up" -> masuk waiting list admin -> admin ACC -> koin otomatis masuk akun.
-- =====================================================================

create table if not exists coin_topups (
    id bigint generated always as identity primary key,
    customer_id bigint not null references customer_accounts(id) on delete cascade,
    username text not null,
    jumlah bigint not null check (jumlah > 0),
    status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
    catatan_admin text,
    created_at timestamptz not null default now(),
    processed_at timestamptz
);
create index if not exists coin_topups_status_idx on coin_topups (status, created_at desc);
create index if not exists coin_topups_cust_idx on coin_topups (customer_id, created_at desc);
alter table coin_topups enable row level security;      -- tanpa policy publik

-- Pelanggan: pesan top up (koin BELUM masuk sampai admin ACC)
create or replace function cu_request_topup(p_session_token uuid, p_jumlah bigint)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare acc customer_accounts%rowtype; v_id bigint;
begin
    acc := portal_session_acc(p_session_token);
    if p_jumlah is null or p_jumlah < 1000 then raise exception 'Minimal top up 1.000 koin'; end if;
    if p_jumlah > 100000000 then raise exception 'Jumlah top up terlalu besar'; end if;
    if (select count(*) from coin_topups where customer_id = acc.id and status = 'pending') >= 5 then
        raise exception 'Terlalu banyak top up yang masih menunggu'; end if;
    insert into coin_topups (customer_id, username, jumlah) values (acc.id, acc.username, p_jumlah) returning id into v_id;
    return jsonb_build_object('id', v_id, 'jumlah', p_jumlah, 'status', 'pending');
end; $$;

-- cu_coin_info: + top up yang masih menunggu ACC
create or replace function cu_coin_info(p_session_token uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare acc customer_accounts%rowtype;
begin
    acc := portal_session_acc(p_session_token);
    return jsonb_build_object(
        'koin', (select koin from customer_accounts where id = acc.id),
        'riwayat', coalesce((select jsonb_agg(jsonb_build_object('delta', l.delta, 'saldo_after', l.saldo_after, 'jenis', l.jenis,
                                    'keterangan', l.keterangan, 'created_at', l.created_at) order by l.created_at desc, l.id desc)
                               from (select * from coin_ledger where customer_id = acc.id order by created_at desc, id desc limit 30) l), '[]'::jsonb),
        'topup_pending', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'jumlah', t.jumlah, 'created_at', t.created_at) order by t.created_at desc)
                                     from coin_topups t where t.customer_id = acc.id and t.status = 'pending'), '[]'::jsonb));
end; $$;

-- Pelanggan membatalkan top up yang masih menunggu
create or replace function cu_cancel_topup(p_session_token uuid, p_id bigint)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare acc customer_accounts%rowtype;
begin
    acc := portal_session_acc(p_session_token);
    delete from coin_topups where id = p_id and customer_id = acc.id and status = 'pending';
end; $$;

-- Admin: waiting list
create or replace function topup_list(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    return coalesce((select jsonb_agg(to_jsonb(r) order by r.created_at desc)
                       from (select t.id, t.customer_id, t.username, t.jumlah, t.status, t.catatan_admin, t.created_at, t.processed_at,
                                    ca.koin as saldo, ca.whatsapp
                               from coin_topups t join customer_accounts ca on ca.id = t.customer_id
                              order by t.created_at desc limit 300) r), '[]'::jsonb);
end; $$;

-- Admin: ACC -> koin otomatis masuk ke akun pelanggan
create or replace function topup_approve(p_pin text, p_id bigint)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare t coin_topups%rowtype; v_saldo bigint;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    select * into t from coin_topups where id = p_id for update;
    if not found then raise exception 'Top up tidak ditemukan'; end if;
    if t.status <> 'pending' then raise exception 'Top up ini sudah diproses'; end if;
    v_saldo := coin_apply(t.customer_id, t.jumlah, 'topup', 'Top up #' || t.id || ' disetujui admin', 'topup', t.id);
    update coin_topups set status = 'approved', processed_at = now() where id = t.id;
    return jsonb_build_object('id', t.id, 'jumlah', t.jumlah, 'saldo', v_saldo, 'username', t.username);
end; $$;

create or replace function topup_reject(p_pin text, p_id bigint, p_catatan text default null)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    update coin_topups set status = 'rejected', processed_at = now(), catatan_admin = nullif(left(trim(coalesce(p_catatan, '')), 300), '')
     where id = p_id and status = 'pending';
    if not found then raise exception 'Top up tidak ditemukan atau sudah diproses'; end if;
end; $$;

create or replace function topup_delete(p_pin text, p_id bigint)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    delete from coin_topups where id = p_id;      -- koin yang sudah masuk (disetujui) TIDAK ditarik; koreksi lewat Akun Pelanggan
end; $$;

grant execute on function
    cu_request_topup(uuid, bigint), cu_coin_info(uuid), cu_cancel_topup(uuid, bigint),
    topup_list(text), topup_approve(text, bigint), topup_reject(text, bigint, text), topup_delete(text, bigint)
to anon, authenticated;
