-- =====================================================================
-- CASHFLOW — catatan pendapatan per batch
-- Jalankan SELURUH file ini SEKALI di Supabase SQL Editor.
-- Syarat: customer_portal_fixed.sql sudah pernah dijalankan (butuh
-- fungsi admin_verify_pin). Aman dijalankan ulang; tidak menyentuh
-- tabel orders / products / tagar_batches / customer_accounts.
--
-- Keamanan: data pendapatan sensitif, jadi tabel TIDAK punya policy
-- publik. Semua akses lewat fungsi yang meminta PIN admin.
-- =====================================================================

create table if not exists cashflow_batches (
    id bigint generated always as identity primary key,
    nama text not null,
    status text not null default 'active' check (status in ('active', 'withdrawn')),
    created_at timestamptz not null default now(),
    withdrawn_at timestamptz
);

create table if not exists cashflow_entries (
    id bigint generated always as identity primary key,
    batch_id bigint not null references cashflow_batches(id) on delete cascade,
    nama text not null,
    produk text not null,
    harga bigint not null check (harga >= 0),
    jumlah integer not null check (jumlah >= 1),
    created_at timestamptz not null default now()
);

create index if not exists cashflow_entries_batch_idx on cashflow_entries(batch_id);

alter table cashflow_batches enable row level security;
alter table cashflow_entries enable row level security;
-- sengaja tanpa policy publik

-- Daftar batch + total + jumlah baris (urut dari batch pertama)
create or replace function cf_list_batches(p_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_result jsonb;
begin
    if not admin_verify_pin(p_pin) then
        raise exception 'PIN admin salah';
    end if;

    select coalesce(jsonb_agg(row_data order by row_id), '[]'::jsonb)
      into v_result
    from (
        select
            b.id as row_id,
            jsonb_build_object(
                'id', b.id,
                'nama', b.nama,
                'status', b.status,
                'created_at', b.created_at,
                'withdrawn_at', b.withdrawn_at,
                'total', coalesce(sum(e.harga * e.jumlah), 0),
                'item_count', count(e.id)
            ) as row_data
        from cashflow_batches b
        left join cashflow_entries e on e.batch_id = b.id
        group by b.id
    ) sub;

    return v_result;
end;
$$;

create or replace function cf_list_entries(p_pin text, p_batch_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_result jsonb;
begin
    if not admin_verify_pin(p_pin) then
        raise exception 'PIN admin salah';
    end if;

    select coalesce(jsonb_agg(jsonb_build_object(
            'id', e.id,
            'nama', e.nama,
            'produk', e.produk,
            'harga', e.harga,
            'jumlah', e.jumlah,
            'total', e.harga * e.jumlah,
            'created_at', e.created_at
        ) order by e.id), '[]'::jsonb)
      into v_result
    from cashflow_entries e
    where e.batch_id = p_batch_id;

    return v_result;
end;
$$;

create or replace function cf_create_batch(p_pin text, p_nama text)
returns bigint
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_id bigint;
    v_nama text;
begin
    if not admin_verify_pin(p_pin) then
        raise exception 'PIN admin salah';
    end if;

    v_nama := nullif(trim(coalesce(p_nama, '')), '');
    if v_nama is null then
        v_nama := 'Batch ' || ((select count(*) from cashflow_batches) + 1);
    end if;

    insert into cashflow_batches (nama) values (v_nama) returning id into v_id;
    return v_id;
end;
$$;

create or replace function cf_rename_batch(p_pin text, p_id bigint, p_nama text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
    if not admin_verify_pin(p_pin) then
        raise exception 'PIN admin salah';
    end if;
    if p_nama is null or trim(p_nama) = '' then
        raise exception 'Nama batch tidak boleh kosong';
    end if;
    update cashflow_batches set nama = trim(p_nama) where id = p_id;
end;
$$;

-- Tandai batch sudah diambil (withdrawn) / aktifkan kembali (active)
create or replace function cf_set_batch_status(p_pin text, p_id bigint, p_status text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
    if not admin_verify_pin(p_pin) then
        raise exception 'PIN admin salah';
    end if;
    if p_status not in ('active', 'withdrawn') then
        raise exception 'Status tidak valid';
    end if;
    update cashflow_batches
        set status = p_status,
            withdrawn_at = case when p_status = 'withdrawn' then now() else null end
        where id = p_id;
end;
$$;

create or replace function cf_delete_batch(p_pin text, p_id bigint)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
    if not admin_verify_pin(p_pin) then
        raise exception 'PIN admin salah';
    end if;
    delete from cashflow_batches where id = p_id;  -- baris di dalamnya ikut terhapus
end;
$$;

create or replace function cf_add_entry(p_pin text, p_batch_id bigint, p_nama text, p_produk text, p_harga bigint, p_jumlah integer)
returns bigint
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_id bigint;
    v_status text;
begin
    if not admin_verify_pin(p_pin) then
        raise exception 'PIN admin salah';
    end if;

    select b.status into v_status from cashflow_batches b where b.id = p_batch_id;
    if v_status is null then
        raise exception 'Batch tidak ditemukan';
    end if;
    if v_status <> 'active' then
        raise exception 'Batch sudah diambil (withdraw), aktifkan kembali untuk menambah data';
    end if;

    if p_nama is null or trim(p_nama) = '' then raise exception 'Nama wajib diisi'; end if;
    if p_produk is null or trim(p_produk) = '' then raise exception 'Produk wajib diisi'; end if;
    if p_harga is null or p_harga < 0 then raise exception 'Harga tidak valid'; end if;
    if p_jumlah is null or p_jumlah < 1 then raise exception 'Jumlah minimal 1'; end if;

    insert into cashflow_entries (batch_id, nama, produk, harga, jumlah)
    values (p_batch_id, trim(p_nama), trim(p_produk), p_harga, p_jumlah)
    returning id into v_id;

    return v_id;
end;
$$;

create or replace function cf_update_entry(p_pin text, p_id bigint, p_nama text, p_produk text, p_harga bigint, p_jumlah integer)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_status text;
begin
    if not admin_verify_pin(p_pin) then
        raise exception 'PIN admin salah';
    end if;

    select b.status into v_status
    from cashflow_entries e join cashflow_batches b on b.id = e.batch_id
    where e.id = p_id;

    if v_status is null then
        raise exception 'Data tidak ditemukan';
    end if;
    if v_status <> 'active' then
        raise exception 'Batch sudah diambil (withdraw), aktifkan kembali untuk mengubah data';
    end if;

    if p_nama is null or trim(p_nama) = '' then raise exception 'Nama wajib diisi'; end if;
    if p_produk is null or trim(p_produk) = '' then raise exception 'Produk wajib diisi'; end if;
    if p_harga is null or p_harga < 0 then raise exception 'Harga tidak valid'; end if;
    if p_jumlah is null or p_jumlah < 1 then raise exception 'Jumlah minimal 1'; end if;

    update cashflow_entries
        set nama = trim(p_nama), produk = trim(p_produk), harga = p_harga, jumlah = p_jumlah
        where id = p_id;
end;
$$;

create or replace function cf_delete_entry(p_pin text, p_id bigint)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_status text;
begin
    if not admin_verify_pin(p_pin) then
        raise exception 'PIN admin salah';
    end if;

    select b.status into v_status
    from cashflow_entries e join cashflow_batches b on b.id = e.batch_id
    where e.id = p_id;

    if v_status is not null and v_status <> 'active' then
        raise exception 'Batch sudah diambil (withdraw), aktifkan kembali untuk menghapus data';
    end if;

    delete from cashflow_entries where id = p_id;
end;
$$;

grant execute on function
    cf_list_batches(text),
    cf_list_entries(text, bigint),
    cf_create_batch(text, text),
    cf_rename_batch(text, bigint, text),
    cf_set_batch_status(text, bigint, text),
    cf_delete_batch(text, bigint),
    cf_add_entry(text, bigint, text, text, bigint, integer),
    cf_update_entry(text, bigint, text, text, bigint, integer),
    cf_delete_entry(text, bigint)
to anon, authenticated;
