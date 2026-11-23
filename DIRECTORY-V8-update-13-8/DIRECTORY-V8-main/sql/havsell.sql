-- =====================================================================
-- HAV SELL — penyimpanan key per batch
-- Jalankan SELURUH file ini SEKALI di Supabase SQL Editor.
-- Syarat: customer_portal_fixed.sql sudah pernah dijalankan (admin_verify_pin).
-- Tabel tanpa policy publik; semua akses lewat fungsi ber-PIN admin.
-- Arsip key = baris hav_keys dengan status 'taken'.
-- =====================================================================
create table if not exists hav_batches (
    id bigint generated always as identity primary key,
    nama text not null,
    created_at timestamptz not null default now()
);
create table if not exists hav_keys (
    id bigint generated always as identity primary key,
    batch_id bigint not null references hav_batches(id) on delete cascade,
    key_value text not null,
    status text not null default 'available' check (status in ('available', 'taken')),
    taken_at timestamptz,
    created_at timestamptz not null default now(),
    unique (batch_id, key_value)
);
create index if not exists hav_keys_batch_idx on hav_keys(batch_id, status, id);
alter table hav_batches enable row level security;
alter table hav_keys enable row level security;

create or replace function hs_list_batches(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v jsonb;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'nama', b.nama, 'created_at', b.created_at,
        'available', (select count(*) from hav_keys k where k.batch_id = b.id and k.status = 'available'),
        'taken', (select count(*) from hav_keys k where k.batch_id = b.id and k.status = 'taken')) order by b.id), '[]'::jsonb)
    into v from hav_batches b;
    return v;
end; $$;

create or replace function hs_create_batch(p_pin text, p_nama text)
returns bigint language plpgsql security definer set search_path = public, extensions as $$
declare v_id bigint; v_nama text;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    v_nama := nullif(trim(coalesce(p_nama, '')), '');
    if v_nama is null then v_nama := 'Batch ' || ((select count(*) from hav_batches) + 1); end if;
    insert into hav_batches (nama) values (v_nama) returning id into v_id;
    return v_id;
end; $$;

create or replace function hs_rename_batch(p_pin text, p_id bigint, p_nama text)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    if p_nama is null or trim(p_nama) = '' then raise exception 'Nama batch tidak boleh kosong'; end if;
    update hav_batches set nama = trim(p_nama) where id = p_id;
end; $$;

create or replace function hs_delete_batch(p_pin text, p_id bigint)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    delete from hav_batches where id = p_id;
end; $$;

create or replace function hs_list_keys(p_pin text, p_batch_id bigint, p_status text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v jsonb;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    select coalesce(jsonb_agg(jsonb_build_object('id', k.id, 'key', k.key_value, 'taken_at', k.taken_at)
        order by case when p_status = 'taken' then 0 else k.id end, k.taken_at desc, k.id), '[]'::jsonb)
    into v from hav_keys k where k.batch_id = p_batch_id and k.status = p_status;
    return v;
end; $$;

-- p_keys = ["HAV_abc", "HAV_def", ...]; key kembar dalam batch dilewati
create or replace function hs_add_keys(p_pin text, p_batch_id bigint, p_keys jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare k text; v_added integer := 0; v_skipped integer := 0;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    if not exists (select 1 from hav_batches where id = p_batch_id) then raise exception 'Batch tidak ditemukan'; end if;
    for k in select trim(value #>> '{}') from jsonb_array_elements(p_keys) loop
        if coalesce(k, '') = '' or exists (select 1 from hav_keys where batch_id = p_batch_id and key_value = k) then
            v_skipped := v_skipped + 1;
        else
            insert into hav_keys (batch_id, key_value) values (p_batch_id, k);
            v_added := v_added + 1;
        end if;
    end loop;
    return jsonb_build_object('added', v_added, 'skipped', v_skipped);
end; $$;

-- Ambil N key teratas -> otomatis pindah ke arsip. Mengembalikan daftar key saja.
create or replace function hs_take_keys(p_pin text, p_batch_id bigint, p_count integer)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v jsonb;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    if p_count is null or p_count < 1 then raise exception 'Jumlah minimal 1'; end if;
    with picked as (
        select id from hav_keys where batch_id = p_batch_id and status = 'available' order by id limit p_count for update
    ), upd as (
        update hav_keys k set status = 'taken', taken_at = now() from picked where k.id = picked.id
        returning k.id, k.key_value
    )
    select coalesce(jsonb_agg(to_jsonb(key_value) order by id), '[]'::jsonb) into v from upd;
    return v;
end; $$;

create or replace function hs_restore_keys(p_pin text, p_ids bigint[])
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    update hav_keys set status = 'available', taken_at = null where id = any(p_ids);
end; $$;

create or replace function hs_delete_keys(p_pin text, p_ids bigint[])
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    delete from hav_keys where id = any(p_ids);
end; $$;

grant execute on function
    hs_list_batches(text), hs_create_batch(text, text), hs_rename_batch(text, bigint, text),
    hs_delete_batch(text, bigint), hs_list_keys(text, bigint, text), hs_add_keys(text, bigint, jsonb),
    hs_take_keys(text, bigint, integer), hs_restore_keys(text, bigint[]), hs_delete_keys(text, bigint[])
to anon, authenticated;
