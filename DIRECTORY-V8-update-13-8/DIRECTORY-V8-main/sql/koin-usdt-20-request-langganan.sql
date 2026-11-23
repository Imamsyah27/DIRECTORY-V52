-- =====================================================================
-- KOIN — BAGIAN 20: REQUEST PELANGGAN — ARSIPKAN / TUNDA / AKTIFKAN KEMBALI langganan harian
-- Jalankan SETELAH koin-usdt-18-hold-tagar.sql. Aman diulang.
-- Pelanggan mengajukan request per langganan; admin menyetujui / menolak di Dashboard -> tab "Request"
-- (di samping tab Tunda). Persetujuan langsung menjalankan aksinya (tunda / aktifkan / arsipkan).
-- =====================================================================
create table if not exists order_requests (
    id bigint generated always as identity primary key,
    order_id bigint not null,
    customer_id bigint,
    username text not null,
    nomor_pesanan text,
    dashboard text,
    tagar text,
    jenis text not null check (jenis in ('hold', 'activate', 'archive')),
    catatan text,
    status text not null default 'pending' check (status in ('pending', 'approved', 'rejected', 'cancelled')),
    catatan_admin text,
    created_at timestamptz not null default now(),
    processed_at timestamptz
);
create index if not exists order_requests_status_idx on order_requests (status, created_at desc);
create index if not exists order_requests_order_idx on order_requests (order_id);
alter table order_requests enable row level security;      -- tanpa policy publik

-- ---------------- PELANGGAN ----------------
create or replace function cu_request_order_action(p_session_token uuid, p_order_id bigint, p_jenis text, p_catatan text default null)
returns bigint language plpgsql security definer set search_path = public, extensions as $$
declare acc customer_accounts%rowtype; o orders%rowtype; v_id bigint;
begin
    acc := portal_session_acc(p_session_token);
    if p_jenis not in ('hold', 'activate', 'archive') then raise exception 'Jenis request tidak valid'; end if;
    select * into o from orders where id = p_order_id and normalize_pelanggan_name(nomor_pesanan) = acc.match_key;
    if not found then raise exception 'Langganan tidak ditemukan'; end if;
    if exists (select 1 from order_requests where order_id = o.id and status = 'pending') then
        raise exception 'Masih ada request untuk langganan ini yang menunggu admin'; end if;
    if p_jenis = 'hold' and o.hold then raise exception 'Langganan ini sudah ditunda'; end if;
    if p_jenis = 'activate' and not o.hold then raise exception 'Langganan ini sudah aktif'; end if;
    if (select count(*) from order_requests where customer_id = acc.id and status = 'pending') >= 30 then
        raise exception 'Terlalu banyak request yang masih menunggu'; end if;
    insert into order_requests (order_id, customer_id, username, nomor_pesanan, dashboard, tagar, jenis, catatan)
    values (o.id, acc.id, acc.username, o.nomor_pesanan, o.dashboard, o.tagar, p_jenis, nullif(left(trim(coalesce(p_catatan, '')), 300), ''))
    returning id into v_id;
    return v_id;
end; $$;

create or replace function cu_cancel_order_request(p_session_token uuid, p_id bigint)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare acc customer_accounts%rowtype;
begin
    acc := portal_session_acc(p_session_token);
    update order_requests set status = 'cancelled', processed_at = now() where id = p_id and customer_id = acc.id and status = 'pending';
    if not found then raise exception 'Request tidak ditemukan atau sudah diproses'; end if;
end; $$;

create or replace function cu_my_order_requests(p_session_token uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare acc customer_accounts%rowtype;
begin
    acc := portal_session_acc(p_session_token);
    return coalesce((select jsonb_agg(to_jsonb(r) order by r.created_at desc)
        from (select id, order_id, dashboard, tagar, jenis, catatan, status, catatan_admin, created_at, processed_at
                from order_requests where customer_id = acc.id order by created_at desc limit 60) r), '[]'::jsonb);
end; $$;

-- ---------------- ADMIN ----------------
create or replace function orq_list(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    return coalesce((select jsonb_agg(to_jsonb(r) order by (r.status = 'pending') desc, r.created_at desc)
        from (select q.id, q.order_id, q.username, q.nomor_pesanan, q.dashboard, q.tagar, q.jenis, q.catatan, q.status, q.catatan_admin, q.created_at, q.processed_at,
                     o.paket_total, o.paket_terkirim, coalesce(o.hold, false) as hold_now, (o.id is not null) as masih_ada
                from order_requests q left join orders o on o.id = q.order_id
               order by (q.status = 'pending') desc, q.created_at desc limit 300) r), '[]'::jsonb);
end; $$;

create or replace function orq_process(p_pin text, p_id bigint, p_approve boolean, p_catatan text default null)
returns text language plpgsql security definer set search_path = public, extensions as $$
declare q order_requests%rowtype; o orders%rowtype; v_note text := nullif(left(trim(coalesce(p_catatan, '')), 300), '');
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    select * into q from order_requests where id = p_id for update;
    if not found then raise exception 'Request tidak ditemukan'; end if;
    if q.status <> 'pending' then raise exception 'Request ini sudah diproses'; end if;

    if not coalesce(p_approve, false) then
        update order_requests set status = 'rejected', catatan_admin = v_note, processed_at = now() where id = q.id;
        return 'rejected';
    end if;

    select * into o from orders where id = q.order_id for update;
    if not found then
        update order_requests set status = 'rejected', catatan_admin = coalesce(v_note, 'Langganan sudah tidak ada (sudah diarsipkan / dihapus)'), processed_at = now() where id = q.id;
        return 'rejected';
    end if;

    if q.jenis = 'hold' then
        update orders set hold = true, hold_at = now() where id = o.id;
    elsif q.jenis = 'activate' then
        update orders set hold = false, hold_at = null where id = o.id;
    else
        insert into archives (order_id, dashboard, nomor_pesanan, tagar, nomor_whatsapp, paket_total, paket_terkirim, keterangan, created_at)
        values (o.id, o.dashboard, o.nomor_pesanan, o.tagar, coalesce(o.nomor_whatsapp, ''), o.paket_total, o.paket_terkirim, coalesce(o.keterangan, ''), o.created_at);
        delete from orders where id = o.id;
    end if;
    update order_requests set status = 'approved', catatan_admin = v_note, processed_at = now() where id = q.id;
    return 'approved';
end; $$;

grant execute on function cu_request_order_action(uuid, bigint, text, text), cu_cancel_order_request(uuid, bigint), cu_my_order_requests(uuid),
    orq_list(text), orq_process(text, bigint, boolean, text) to anon, authenticated;
