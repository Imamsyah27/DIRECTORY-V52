-- =====================================================================
-- KATEGORI KATALOG YANG BISA DITAMBAH / DIKURANGI ADMIN (selain Koin, Voucher, Farm)
-- Jalankan SEKALI di Supabase SQL Editor, SETELAH sql/katalog-pesan-baru.sql.
-- Aman dijalankan ulang. Item & gambar yang sudah ada tidak berubah.
-- =====================================================================

create table if not exists catalog_categories (
    slug text primary key,
    nama text not null,
    ikon text not null default '🛍',
    urut integer not null default 0,
    created_at timestamptz not null default now()
);
alter table catalog_categories enable row level security;   -- tanpa policy publik

insert into catalog_categories (slug, nama, ikon, urut) values
    ('koin', 'Koin', '🪙', 0), ('voucher', 'Voucher', '🎟', 1), ('farm', 'Farm', '🌱', 2)
on conflict (slug) do nothing;

-- kategori item tidak lagi dibatasi 3 nilai tetap
alter table catalog_items drop constraint if exists catalog_items_kategori_check;

create or replace function ct_cat_list(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v jsonb;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    select coalesce(jsonb_agg(jsonb_build_object(
        'slug', c.slug, 'nama', c.nama, 'ikon', c.ikon, 'urut', c.urut,
        'jumlah', (select count(*) from catalog_items i where i.kategori = c.slug)
    ) order by c.urut, c.created_at), '[]'::jsonb) into v from catalog_categories c;
    return v;
end; $$;

-- p_slug null = kategori baru; terisi = ubah nama/ikon. Mengembalikan slug.
create or replace function ct_cat_save(p_pin text, p_slug text, p_nama text, p_ikon text)
returns text language plpgsql security definer set search_path = public, extensions as $$
declare v_nama text := trim(coalesce(p_nama, '')); v_ikon text := left(trim(coalesce(p_ikon, '')), 8);
        v_slug text; v_base text; n int := 1;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    if v_nama = '' then raise exception 'Nama kategori wajib diisi'; end if;
    if length(v_nama) > 40 then raise exception 'Nama kategori maksimal 40 karakter'; end if;
    if v_ikon = '' then v_ikon := '🛍'; end if;
    if p_slug is not null then
        update catalog_categories set nama = v_nama, ikon = v_ikon where slug = p_slug returning slug into v_slug;
        if v_slug is null then raise exception 'Kategori tidak ditemukan'; end if;
        return v_slug;
    end if;
    v_base := trim(both '-' from lower(regexp_replace(v_nama, '[^a-zA-Z0-9]+', '-', 'g')));
    if v_base = '' then v_base := 'kategori'; end if;
    v_slug := v_base;
    while exists (select 1 from catalog_categories where slug = v_slug) loop n := n + 1; v_slug := v_base || '-' || n; end loop;
    insert into catalog_categories (slug, nama, ikon, urut)
    values (v_slug, v_nama, v_ikon, coalesce((select max(urut) + 1 from catalog_categories), 0));
    return v_slug;
end; $$;

-- Hapus kategori: SEMUA item di dalamnya (beserta gambarnya) ikut terhapus
create or replace function ct_cat_delete(p_pin text, p_slug text)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    delete from catalog_items where kategori = p_slug;      -- gambar ikut terhapus (cascade)
    delete from catalog_categories where slug = p_slug;
end; $$;

-- ct_save: kategori divalidasi terhadap tabel kategori
create or replace function ct_save(p_pin text, p_id bigint, p_kategori text, p_nama text, p_deskripsi text, p_harga text, p_ready boolean)
returns bigint language plpgsql security definer set search_path = public, extensions as $$
declare v_id bigint; v_nama text := trim(coalesce(p_nama, ''));
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    if v_nama = '' then raise exception 'Nama item wajib diisi'; end if;
    if length(v_nama) > 120 then raise exception 'Nama item maksimal 120 karakter'; end if;
    if not exists (select 1 from catalog_categories where slug = p_kategori) then raise exception 'Kategori tidak valid'; end if;
    if p_id is null then
        insert into catalog_items (kategori, nama, deskripsi, harga, ready, urut)
        values (p_kategori, v_nama, left(trim(coalesce(p_deskripsi, '')), 500), left(trim(coalesce(p_harga, '')), 80), coalesce(p_ready, true),
                coalesce((select max(urut) + 1 from catalog_items where kategori = p_kategori), 0))
        returning id into v_id;
    else
        update catalog_items
           set kategori = p_kategori, nama = v_nama, deskripsi = left(trim(coalesce(p_deskripsi, '')), 500),
               harga = left(trim(coalesce(p_harga, '')), 80), ready = coalesce(p_ready, ready), updated_at = now()
         where id = p_id returning id into v_id;
        if v_id is null then raise exception 'Item tidak ditemukan'; end if;
    end if;
    return v_id;
end; $$;

-- Pelanggan: daftar kategori
create or replace function cu_catalog_cats(p_session_token uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v jsonb;
begin
    perform portal_session_acc(p_session_token);
    select coalesce(jsonb_agg(jsonb_build_object('slug', c.slug, 'nama', c.nama, 'ikon', c.ikon) order by c.urut, c.created_at), '[]'::jsonb)
      into v from catalog_categories c;
    return v;
end; $$;

grant execute on function
    ct_cat_list(text), ct_cat_save(text, text, text, text), ct_cat_delete(text, text),
    ct_save(text, bigint, text, text, text, text, boolean), cu_catalog_cats(uuid)
to anon, authenticated;
