-- =====================================================================
-- SUPPLY & STOCK + PENGUMUMAN + ARSIP PELANGGAN
-- Jalankan SELURUH file ini SEKALI di Supabase SQL Editor.
-- Syarat: customer_portal_fixed.sql sudah pernah dijalankan.
-- Aman dijalankan ulang. Tidak menghapus data lama.
-- Semua tabel TANPA policy publik; akses hanya lewat fungsi (PIN admin
-- untuk admin, session_token untuk pelanggan).
-- =====================================================================

create table if not exists supply_batches (
    id bigint generated always as identity primary key,
    nama text not null,
    item text not null default '',
    satuan text not null default 'pcs',
    visible boolean not null default true,          -- tampil di dashboard pelanggan?
    created_at timestamptz not null default now()
);
create table if not exists supply_accounts (
    id bigint generated always as identity primary key,
    batch_id bigint not null references supply_batches(id) on delete cascade,
    nama text not null,
    stok integer not null default 0 check (stok >= 0),
    urut integer not null default 0,
    updated_at timestamptz not null default now()
);
create table if not exists supply_orders (
    id bigint generated always as identity primary key,
    batch_id bigint not null references supply_batches(id) on delete cascade,
    customer_id bigint not null references customer_accounts(id) on delete cascade,
    username text not null,
    qty integer not null check (qty > 0),
    status text not null default 'pending' check (status in ('pending', 'sent')),
    sent_at timestamptz,
    created_at timestamptz not null default now()
);
create table if not exists announcements (
    id bigint generated always as identity primary key,
    judul text not null,
    isi text not null default '',
    target text not null default 'semua' check (target in ('semua', 'BEM', 'SEM', 'LEM')),
    pinned boolean not null default false,
    aktif boolean not null default true,
    ends_at timestamptz,
    created_at timestamptz not null default now()
);
create index if not exists supply_accounts_batch_idx on supply_accounts(batch_id, urut);
create index if not exists supply_orders_status_idx on supply_orders(status, created_at desc);

alter table supply_batches enable row level security;
alter table supply_accounts enable row level security;
alter table supply_orders enable row level security;
alter table announcements enable row level security;

-- ---------------------------------------------------------------------
-- Helper internal: validasi sesi pelanggan (tidak boleh dipanggil publik)
-- ---------------------------------------------------------------------
create or replace function portal_session_acc(p_token uuid)
returns customer_accounts language plpgsql security definer set search_path = public, extensions as $$
declare v customer_accounts%rowtype;
begin
    select * into v from customer_accounts where session_token = p_token and session_expires_at > now();
    if not found then raise exception 'Sesi login tidak valid atau sudah habis, silakan login ulang'; end if;
    return v;
end; $$;
revoke all on function portal_session_acc(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- ADMIN: supply & stock
-- ---------------------------------------------------------------------
create or replace function sp_list_batches(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v jsonb;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    select coalesce(jsonb_agg(jsonb_build_object(
        'id', b.id, 'nama', b.nama, 'item', b.item, 'satuan', b.satuan, 'visible', b.visible, 'created_at', b.created_at,
        'total', (select coalesce(sum(a.stok), 0) from supply_accounts a where a.batch_id = b.id),
        'accounts', (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'nama', a.nama, 'stok', a.stok, 'updated_at', a.updated_at) order by a.urut, a.id), '[]'::jsonb)
                     from supply_accounts a where a.batch_id = b.id)
    ) order by b.id), '[]'::jsonb) into v from supply_batches b;
    return v;
end; $$;

create or replace function sp_create_batch(p_pin text, p_nama text, p_item text, p_satuan text, p_jumlah_akun integer)
returns bigint language plpgsql security definer set search_path = public, extensions as $$
declare v_id bigint; i integer;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    insert into supply_batches (nama, item, satuan)
    values (coalesce(nullif(trim(p_nama), ''), 'Batch ' || ((select count(*) from supply_batches) + 1)),
            coalesce(trim(p_item), ''), coalesce(nullif(trim(p_satuan), ''), 'pcs'))
    returning id into v_id;
    for i in 1..greatest(0, least(coalesce(p_jumlah_akun, 4), 50)) loop
        insert into supply_accounts (batch_id, nama, urut) values (v_id, 'Akun ' || i, i);
    end loop;
    return v_id;
end; $$;

create or replace function sp_update_batch(p_pin text, p_id bigint, p_nama text, p_item text, p_satuan text, p_visible boolean)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    update supply_batches set
        nama = coalesce(nullif(trim(p_nama), ''), nama),
        item = coalesce(trim(p_item), item),
        satuan = coalesce(nullif(trim(p_satuan), ''), satuan),
        visible = coalesce(p_visible, visible)
    where id = p_id;
end; $$;

create or replace function sp_delete_batch(p_pin text, p_id bigint)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    delete from supply_batches where id = p_id;
end; $$;

create or replace function sp_add_account(p_pin text, p_batch_id bigint, p_nama text)
returns bigint language plpgsql security definer set search_path = public, extensions as $$
declare v_id bigint;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    insert into supply_accounts (batch_id, nama, urut)
    values (p_batch_id, coalesce(nullif(trim(p_nama), ''), 'Akun baru'),
            coalesce((select max(urut) from supply_accounts where batch_id = p_batch_id), 0) + 1)
    returning id into v_id;
    return v_id;
end; $$;

-- p_nama null = nama tidak diubah; p_stok null = stok tidak diubah
create or replace function sp_update_account(p_pin text, p_id bigint, p_nama text, p_stok integer)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    if p_stok is not null and p_stok < 0 then raise exception 'Stok tidak boleh minus'; end if;
    update supply_accounts set
        nama = coalesce(nullif(trim(p_nama), ''), nama),
        stok = coalesce(p_stok, stok),
        updated_at = now()
    where id = p_id;
end; $$;

create or replace function sp_delete_account(p_pin text, p_id bigint)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    delete from supply_accounts where id = p_id;
end; $$;

-- p_status: 'pending' | 'sent' | 'all'
create or replace function sp_list_orders(p_pin text, p_status text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v jsonb;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    select coalesce(jsonb_agg(jsonb_build_object(
        'id', o.id, 'username', o.username, 'qty', o.qty, 'status', o.status,
        'created_at', o.created_at, 'sent_at', o.sent_at,
        'batch', b.nama, 'item', b.item, 'satuan', b.satuan
    ) order by o.created_at desc), '[]'::jsonb) into v
    from supply_orders o join supply_batches b on b.id = o.batch_id
    where p_status = 'all' or o.status = p_status;
    return v;
end; $$;

create or replace function sp_set_order_status(p_pin text, p_id bigint, p_sent boolean)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    update supply_orders set status = case when p_sent then 'sent' else 'pending' end,
        sent_at = case when p_sent then now() else null end where id = p_id;
end; $$;

create or replace function sp_delete_order(p_pin text, p_id bigint)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    delete from supply_orders where id = p_id;
end; $$;

-- ---------------------------------------------------------------------
-- ADMIN: pengumuman
-- ---------------------------------------------------------------------
create or replace function an_list(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v jsonb;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    select coalesce(jsonb_agg(to_jsonb(a) order by a.pinned desc, a.created_at desc), '[]'::jsonb) into v from announcements a;
    return v;
end; $$;

-- p_id null = buat baru
create or replace function an_save(p_pin text, p_id bigint, p_judul text, p_isi text, p_target text, p_pinned boolean, p_aktif boolean, p_ends_at timestamptz)
returns bigint language plpgsql security definer set search_path = public, extensions as $$
declare v_id bigint;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    if coalesce(trim(p_judul), '') = '' then raise exception 'Judul pengumuman wajib diisi'; end if;
    if p_id is null then
        insert into announcements (judul, isi, target, pinned, aktif, ends_at)
        values (trim(p_judul), coalesce(p_isi, ''), coalesce(p_target, 'semua'), coalesce(p_pinned, false), coalesce(p_aktif, true), p_ends_at)
        returning id into v_id;
    else
        update announcements set judul = trim(p_judul), isi = coalesce(p_isi, ''), target = coalesce(p_target, 'semua'),
            pinned = coalesce(p_pinned, false), aktif = coalesce(p_aktif, true), ends_at = p_ends_at
        where id = p_id returning id into v_id;
    end if;
    return v_id;
end; $$;

create or replace function an_delete(p_pin text, p_id bigint)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    delete from announcements where id = p_id;
end; $$;

-- ---------------------------------------------------------------------
-- PELANGGAN (pakai session_token)
-- ---------------------------------------------------------------------
create or replace function cu_announcements(p_session_token uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare acc customer_accounts%rowtype; v jsonb;
begin
    acc := portal_session_acc(p_session_token);
    select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'judul', a.judul, 'isi', a.isi, 'pinned', a.pinned, 'target', a.target, 'created_at', a.created_at)
        order by a.pinned desc, a.created_at desc), '[]'::jsonb) into v
    from announcements a
    where a.aktif and (a.ends_at is null or a.ends_at > now())
      and (a.target = 'semua' or exists (
            select 1 from (select dashboard, nomor_pesanan from orders union all select dashboard, nomor_pesanan from archives) x
            where normalize_pelanggan_name(x.nomor_pesanan) = acc.match_key and upper(x.dashboard) = a.target));
    return v;
end; $$;

-- hanya batch yang ditampilkan; pelanggan hanya melihat TOTAL (bukan rincian akun)
create or replace function cu_supply(p_session_token uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v jsonb;
begin
    perform portal_session_acc(p_session_token);
    select coalesce(jsonb_agg(jsonb_build_object(
        'id', b.id, 'nama', b.nama, 'item', b.item, 'satuan', b.satuan,
        'total', (select coalesce(sum(a.stok), 0) from supply_accounts a where a.batch_id = b.id),
        'updated_at', (select max(a.updated_at) from supply_accounts a where a.batch_id = b.id)
    ) order by b.id), '[]'::jsonb) into v from supply_batches b where b.visible;
    return v;
end; $$;

create or replace function cu_place_supply_order(p_session_token uuid, p_batch_id bigint, p_qty integer)
returns bigint language plpgsql security definer set search_path = public, extensions as $$
declare acc customer_accounts%rowtype; v_total integer; v_id bigint;
begin
    acc := portal_session_acc(p_session_token);
    if p_qty is null or p_qty < 1 then raise exception 'Jumlah pesanan minimal 1'; end if;
    if not exists (select 1 from supply_batches where id = p_batch_id and visible) then raise exception 'Item tidak tersedia'; end if;
    select coalesce(sum(stok), 0) into v_total from supply_accounts where batch_id = p_batch_id;
    if p_qty > v_total then raise exception 'Jumlah melebihi stok tersedia'; end if;
    if (select count(*) from supply_orders where customer_id = acc.id and status = 'pending') >= 20 then
        raise exception 'Terlalu banyak pesanan yang masih menunggu'; end if;
    insert into supply_orders (batch_id, customer_id, username, qty) values (p_batch_id, acc.id, acc.username, p_qty) returning id into v_id;
    return v_id;
end; $$;

create or replace function cu_my_supply_orders(p_session_token uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare acc customer_accounts%rowtype; v jsonb;
begin
    acc := portal_session_acc(p_session_token);
    select coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'qty', o.qty, 'status', o.status, 'created_at', o.created_at, 'sent_at', o.sent_at,
        'item', b.item, 'nama', b.nama, 'satuan', b.satuan) order by o.created_at desc), '[]'::jsonb) into v
    from supply_orders o join supply_batches b on b.id = o.batch_id where o.customer_id = acc.id;
    return v;
end; $$;

create or replace function cu_cancel_supply_order(p_session_token uuid, p_id bigint)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare acc customer_accounts%rowtype;
begin
    acc := portal_session_acc(p_session_token);
    delete from supply_orders where id = p_id and customer_id = acc.id and status = 'pending';
end; $$;

-- Arsip bekas orderan: HANYA milik pelanggan yang login (dicocokkan lewat nama/username)
create or replace function cu_my_archives(p_session_token uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare acc customer_accounts%rowtype; v jsonb;
begin
    acc := portal_session_acc(p_session_token);
    select coalesce(jsonb_agg(jsonb_build_object(
        'id', a.id, 'dashboard', a.dashboard, 'tagar', a.tagar,
        'paket_total', a.paket_total, 'paket_terkirim', a.paket_terkirim,
        'created_at', a.created_at, 'archived_at', a.archived_at
    ) order by a.archived_at desc nulls last), '[]'::jsonb) into v
    from archives a where normalize_pelanggan_name(a.nomor_pesanan) = acc.match_key;
    return v;
end; $$;

grant execute on function
    sp_list_batches(text), sp_create_batch(text, text, text, text, integer), sp_update_batch(text, bigint, text, text, text, boolean),
    sp_delete_batch(text, bigint), sp_add_account(text, bigint, text), sp_update_account(text, bigint, text, integer),
    sp_delete_account(text, bigint), sp_list_orders(text, text), sp_set_order_status(text, bigint, boolean), sp_delete_order(text, bigint),
    an_list(text), an_save(text, bigint, text, text, text, boolean, boolean, timestamptz), an_delete(text, bigint),
    cu_announcements(uuid), cu_supply(uuid), cu_place_supply_order(uuid, bigint, integer), cu_my_supply_orders(uuid),
    cu_cancel_supply_order(uuid, bigint), cu_my_archives(uuid)
to anon, authenticated;
