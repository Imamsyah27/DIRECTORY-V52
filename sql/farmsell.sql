-- =====================================================================
-- FARM SELL — penyimpanan token farm per batch
-- Jalankan SELURUH file ini SEKALI di Supabase SQL Editor.
-- Syarat: customer_portal_fixed.sql sudah pernah dijalankan (butuh
-- fungsi admin_verify_pin). Aman dijalankan ulang.
-- Keamanan: token = data rahasia -> tabel TANPA policy publik, semua
-- akses lewat fungsi yang meminta PIN admin (sama seperti CashFlow).
-- Arsip token = baris farm_tokens dengan status 'taken'.
-- =====================================================================

create table if not exists farm_batches (
    id bigint generated always as identity primary key,
    nama text not null,
    created_at timestamptz not null default now()
);

create table if not exists farm_tokens (
    id bigint generated always as identity primary key,
    batch_id bigint not null references farm_batches(id) on delete cascade,
    no integer not null,                 -- nomor urut otomatis (jadi "nama")
    farm_id text not null,
    token text not null,
    status text not null default 'available' check (status in ('available', 'taken')),
    taken_at timestamptz,
    created_at timestamptz not null default now(),
    unique (batch_id, no)
);
create index if not exists farm_tokens_batch_idx on farm_tokens(batch_id, status, no);

alter table farm_batches enable row level security;
alter table farm_tokens enable row level security;
-- sengaja tanpa policy publik

create or replace function fs_list_batches(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v jsonb;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    select coalesce(jsonb_agg(jsonb_build_object(
        'id', b.id, 'nama', b.nama, 'created_at', b.created_at,
        'available', (select count(*) from farm_tokens t where t.batch_id = b.id and t.status = 'available'),
        'taken', (select count(*) from farm_tokens t where t.batch_id = b.id and t.status = 'taken')
    ) order by b.id), '[]'::jsonb) into v from farm_batches b;
    return v;
end; $$;

create or replace function fs_create_batch(p_pin text, p_nama text)
returns bigint language plpgsql security definer set search_path = public, extensions as $$
declare v_id bigint; v_nama text;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    v_nama := nullif(trim(coalesce(p_nama, '')), '');
    if v_nama is null then v_nama := 'Batch ' || ((select count(*) from farm_batches) + 1); end if;
    insert into farm_batches (nama) values (v_nama) returning id into v_id;
    return v_id;
end; $$;

create or replace function fs_rename_batch(p_pin text, p_id bigint, p_nama text)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    if p_nama is null or trim(p_nama) = '' then raise exception 'Nama batch tidak boleh kosong'; end if;
    update farm_batches set nama = trim(p_nama) where id = p_id;
end; $$;

create or replace function fs_delete_batch(p_pin text, p_id bigint)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    delete from farm_batches where id = p_id;
end; $$;

-- p_status: 'available' (daftar) atau 'taken' (arsip)
create or replace function fs_list_tokens(p_pin text, p_batch_id bigint, p_status text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v jsonb;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    select coalesce(jsonb_agg(jsonb_build_object(
        'id', t.id, 'no', t.no, 'farm_id', t.farm_id, 'token', t.token, 'taken_at', t.taken_at
    ) order by case when p_status = 'taken' then 0 else t.no end, t.taken_at desc, t.no), '[]'::jsonb)
    into v from farm_tokens t where t.batch_id = p_batch_id and t.status = p_status;
    return v;
end; $$;

-- Tambah banyak token sekaligus. p_rows = [{"id":"12-3635","token":"abc..."}, ...]
-- Nomor urut dilanjutkan otomatis (tidak pernah dipakai ulang). Token kembar dalam batch dilewati.
create or replace function fs_add_tokens(p_pin text, p_batch_id bigint, p_rows jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare r jsonb; v_no integer; v_added integer := 0; v_skipped integer := 0;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    if not exists (select 1 from farm_batches where id = p_batch_id) then raise exception 'Batch tidak ditemukan'; end if;
    select coalesce(max(no), 0) into v_no from farm_tokens where batch_id = p_batch_id;
    for r in select * from jsonb_array_elements(p_rows) loop
        if coalesce(trim(r->>'id'), '') = '' or coalesce(trim(r->>'token'), '') = '' then
            v_skipped := v_skipped + 1;
        elsif exists (select 1 from farm_tokens where batch_id = p_batch_id and token = trim(r->>'token')) then
            v_skipped := v_skipped + 1;
        else
            v_no := v_no + 1;
            insert into farm_tokens (batch_id, no, farm_id, token) values (p_batch_id, v_no, trim(r->>'id'), trim(r->>'token'));
            v_added := v_added + 1;
        end if;
    end loop;
    return jsonb_build_object('added', v_added, 'skipped', v_skipped);
end; $$;

-- Ambil N token teratas dari daftar -> otomatis pindah ke arsip (status 'taken')
create or replace function fs_take_tokens(p_pin text, p_batch_id bigint, p_count integer)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v jsonb;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    if p_count is null or p_count < 1 then raise exception 'Jumlah minimal 1'; end if;
    with picked as (
        select id from farm_tokens where batch_id = p_batch_id and status = 'available'
        order by no limit p_count for update
    ), upd as (
        update farm_tokens t set status = 'taken', taken_at = now()
        from picked where t.id = picked.id
        returning t.no, t.farm_id, t.token
    )
    select coalesce(jsonb_agg(jsonb_build_object('no', no, 'farm_id', farm_id, 'token', token) order by no), '[]'::jsonb)
    into v from upd;
    return v;
end; $$;

create or replace function fs_restore_tokens(p_pin text, p_ids bigint[])
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    update farm_tokens set status = 'available', taken_at = null where id = any(p_ids);
end; $$;

create or replace function fs_delete_tokens(p_pin text, p_ids bigint[])
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    delete from farm_tokens where id = any(p_ids);
end; $$;

grant execute on function
    fs_list_batches(text), fs_create_batch(text, text), fs_rename_batch(text, bigint, text),
    fs_delete_batch(text, bigint), fs_list_tokens(text, bigint, text), fs_add_tokens(text, bigint, jsonb),
    fs_take_tokens(text, bigint, integer), fs_restore_tokens(text, bigint[]), fs_delete_tokens(text, bigint[])
to anon, authenticated;
