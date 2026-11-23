-- =====================================================================
-- BSL PROFIT: catatan pemasukan (omset), modal, dan profit.
--
-- Jalankan SELURUH file ini SEKALI di Supabase SQL Editor.
-- Urutan: SETELAH price.sql (butuh price_settings, price_calc, renewal_requests.total_harga).
-- Aman dijalankan ulang.
--
-- Aturan:
--   1 hari = 1 tag.  Modal = modal per tag per hari (BEM / SEM / LEM) x hari x jumlah tag.
--   Profit = omset - modal.
--
-- Sumber catatan (kolom jenis):
--   'langganan' -> otomatis saat admin menambah pesanan di Dashboard (harga dari pricelist, bisa di-custom)
--   'request'   -> otomatis saat admin MENYETUJUI permintaan pelanggan (pesan baru / perpanjang);
--                  omset = total bayar setelah diskon & kode referal
--   'manual'    -> dicatat admin lewat tombol (penjualan akun, dll)
-- Modal dicatat sebagai "snapshot" saat transaksi terjadi, jadi mengubah modal di kemudian hari
-- tidak mengubah profit transaksi lama.
-- =====================================================================

create table if not exists bsl_settings (
    id integer primary key default 1 check (id = 1),
    modal_bem integer not null default 0 check (modal_bem >= 0),
    modal_sem integer not null default 0 check (modal_sem >= 0),
    modal_lem integer not null default 0 check (modal_lem >= 0),
    updated_at timestamptz not null default now()
);
insert into bsl_settings (id) values (1) on conflict (id) do nothing;

create table if not exists bsl_entries (
    id bigint generated always as identity primary key,
    tanggal date not null default ((now() at time zone 'Asia/Jakarta')::date),
    jenis text not null check (jenis in ('langganan', 'request', 'manual')),
    kategori text not null default '',          -- BEM / SEM / LEM, atau bebas untuk manual (mis. Penjualan Akun)
    pelanggan text not null default '',
    keterangan text not null default '',
    hari integer,
    jumlah_tagar integer,
    harga_hari integer,
    modal_hari integer,
    omset bigint not null default 0 check (omset >= 0),
    modal bigint not null default 0 check (modal >= 0),
    profit bigint generated always as (omset - modal) stored,
    request_id bigint,                          -- penanda permintaan yang sudah dicatat (mencegah dobel)
    created_at timestamptz not null default now()
);
create unique index if not exists bsl_entries_req_uidx on bsl_entries (request_id) where request_id is not null;
create index if not exists bsl_entries_tanggal_idx on bsl_entries (tanggal);

alter table bsl_settings enable row level security;
alter table bsl_entries enable row level security;      -- tanpa policy publik: hanya lewat fungsi PIN di bawah

-- ---------------------------------------------------------------------
-- Otomatis: permintaan disetujui -> masuk catatan profit
-- ---------------------------------------------------------------------
create or replace function bsl_request_approved()
returns trigger language plpgsql security definer set search_path = public, extensions as $$
declare s bsl_settings%rowtype; v_dash text; v_n integer; v_m integer;
begin
    if new.status = 'approved' and old.status is distinct from 'approved' then
        select * into s from bsl_settings where id = 1;
        v_dash := upper(coalesce(new.dashboard_baru, ''));
        v_n := greatest(coalesce(new.jumlah_item, cardinality(new.tagar_list), 1), 1);
        v_m := case v_dash when 'BEM' then s.modal_bem when 'SEM' then s.modal_sem else s.modal_lem end;
        insert into bsl_entries (tanggal, jenis, kategori, pelanggan, keterangan, hari, jumlah_tagar, harga_hari, modal_hari, omset, modal, request_id)
        values ((now() at time zone 'Asia/Jakarta')::date, 'request', v_dash, coalesce(new.nomor_pesanan, new.username, ''),
                case when new.source = 'new' then 'Pesanan baru' else 'Perpanjangan' end || ' #' || new.id
                    || case when new.kode_referal is not null then ' · kode ' || new.kode_referal else '' end,
                new.hari, v_n, new.harga_hari, v_m,
                coalesce(new.total_harga, 0), v_m::bigint * coalesce(new.hari, 0) * v_n, new.id)
        on conflict (request_id) where request_id is not null do nothing;
    end if;
    return new;
end; $$;
drop trigger if exists bsl_request_approved_trg on renewal_requests;
create trigger bsl_request_approved_trg after update of status on renewal_requests
    for each row execute function bsl_request_approved();

-- ---------------------------------------------------------------------
-- ADMIN (PIN)
-- ---------------------------------------------------------------------
create or replace function bp_get(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    return jsonb_build_object(
        'settings', (select to_jsonb(s) from bsl_settings s where s.id = 1),
        'harga', (select jsonb_build_object('bem', p.bem, 'sem', p.sem, 'lem', p.lem) from price_settings p where p.id = 1),
        'entries', coalesce((select jsonb_agg(to_jsonb(e) order by e.tanggal desc, e.id desc)
                               from (select * from bsl_entries order by tanggal desc, id desc limit 5000) e), '[]'::jsonb)
    );
end; $$;

create or replace function bp_save_modal(p_pin text, p_bem integer, p_sem integer, p_lem integer)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    if least(coalesce(p_bem, -1), coalesce(p_sem, -1), coalesce(p_lem, -1)) < 0 then raise exception 'Modal tidak boleh kosong atau negatif'; end if;
    if greatest(p_bem, p_sem, p_lem) > 100000000 then raise exception 'Modal terlalu besar'; end if;
    update bsl_settings set modal_bem = p_bem, modal_sem = p_sem, modal_lem = p_lem, updated_at = now() where id = 1;
end; $$;

-- Saran harga per hari untuk form Tambah Pesanan (pricelist; harga istimewa bila nama cocok dengan akun istimewa)
create or replace function bp_suggest(p_pin text, p_dashboard text, p_nama text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare s bsl_settings%rowtype; acc customer_accounts%rowtype; q jsonb; v_dash text := upper(coalesce(p_dashboard, ''));
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    if v_dash not in ('BEM', 'SEM', 'LEM') then raise exception 'Paket tidak valid'; end if;
    select * into s from bsl_settings where id = 1;
    if coalesce(trim(p_nama), '') <> '' then
        select * into acc from customer_accounts where match_key = normalize_pelanggan_name(p_nama) limit 1;
    end if;
    q := price_calc(coalesce(acc.id, -1), v_dash, 1, 1, null);
    return jsonb_build_object('normal_hari', q->'normal_hari', 'harga_hari', q->'harga_hari', 'jenis', q->'jenis',
        'istimewa', coalesce((q->>'istimewa')::boolean, false), 'akun', acc.username,
        'modal_hari', case v_dash when 'BEM' then s.modal_bem when 'SEM' then s.modal_sem else s.modal_lem end);
end; $$;

-- Catat penjualan dari form Tambah Pesanan. p_harga_hari kosong/0 = otomatis dari pricelist.
create or replace function bp_add_sale(p_pin text, p_dashboard text, p_nama text, p_hari integer, p_jumlah integer,
                                       p_harga_hari integer, p_tanggal date default null, p_keterangan text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare s bsl_settings%rowtype; acc customer_accounts%rowtype; q jsonb; v_dash text := upper(coalesce(p_dashboard, ''));
        v_harga integer; v_m integer; v_n integer := greatest(coalesce(p_jumlah, 1), 1); v_id bigint; v_omset bigint; v_modal bigint;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    if v_dash not in ('BEM', 'SEM', 'LEM') then raise exception 'Paket tidak valid'; end if;
    if p_hari is null or p_hari < 1 or p_hari > 3650 then raise exception 'Jumlah hari tidak valid'; end if;
    if coalesce(p_harga_hari, 0) < 0 or coalesce(p_harga_hari, 0) > 100000000 then raise exception 'Harga tidak valid'; end if;
    select * into s from bsl_settings where id = 1;

    if coalesce(p_harga_hari, 0) > 0 then
        v_harga := p_harga_hari;
    else
        if coalesce(trim(p_nama), '') <> '' then
            select * into acc from customer_accounts where match_key = normalize_pelanggan_name(p_nama) limit 1;
        end if;
        q := price_calc(coalesce(acc.id, -1), v_dash, 1, 1, null);
        v_harga := coalesce((q->>'harga_hari')::integer, 0);
    end if;
    v_m := case v_dash when 'BEM' then s.modal_bem when 'SEM' then s.modal_sem else s.modal_lem end;
    v_omset := v_harga::bigint * p_hari * v_n;
    v_modal := v_m::bigint * p_hari * v_n;

    insert into bsl_entries (tanggal, jenis, kategori, pelanggan, keterangan, hari, jumlah_tagar, harga_hari, modal_hari, omset, modal)
    values (coalesce(p_tanggal, (now() at time zone 'Asia/Jakarta')::date), 'langganan', v_dash, left(trim(coalesce(p_nama, '')), 120),
            left(trim(coalesce(p_keterangan, '')), 200), p_hari, v_n, v_harga, v_m, v_omset, v_modal)
    returning id into v_id;
    return jsonb_build_object('id', v_id, 'harga_hari', v_harga, 'omset', v_omset, 'modal', v_modal, 'profit', v_omset - v_modal);
end; $$;

-- Tambah (p_id null -> manual) atau ubah catatan.
create or replace function bp_entry_save(p_pin text, p_id bigint, p_tanggal date, p_kategori text, p_pelanggan text,
                                         p_keterangan text, p_omset bigint, p_modal bigint)
returns bigint language plpgsql security definer set search_path = public, extensions as $$
declare v_id bigint;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    if p_omset is null or p_omset < 0 or p_omset > 100000000000 then raise exception 'Pendapatan tidak valid'; end if;
    if coalesce(p_modal, 0) < 0 or coalesce(p_modal, 0) > 100000000000 then raise exception 'Modal tidak valid'; end if;
    if p_id is null then
        if coalesce(trim(p_kategori), '') = '' then raise exception 'Kategori wajib diisi'; end if;
        insert into bsl_entries (tanggal, jenis, kategori, pelanggan, keterangan, omset, modal)
        values (coalesce(p_tanggal, (now() at time zone 'Asia/Jakarta')::date), 'manual', left(trim(p_kategori), 60),
                left(trim(coalesce(p_pelanggan, '')), 120), left(trim(coalesce(p_keterangan, '')), 200), p_omset, coalesce(p_modal, 0))
        returning id into v_id;
    else
        update bsl_entries set
            tanggal = coalesce(p_tanggal, tanggal),
            kategori = case when jenis = 'manual' and coalesce(trim(p_kategori), '') <> '' then left(trim(p_kategori), 60) else kategori end,
            pelanggan = left(trim(coalesce(p_pelanggan, '')), 120),
            keterangan = left(trim(coalesce(p_keterangan, '')), 200),
            omset = p_omset, modal = coalesce(p_modal, 0)
         where id = p_id returning id into v_id;
        if v_id is null then raise exception 'Catatan tidak ditemukan'; end if;
    end if;
    return v_id;
end; $$;

create or replace function bp_entry_delete(p_pin text, p_id bigint)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    delete from bsl_entries where id = p_id;
end; $$;

grant execute on function
    bp_get(text), bp_save_modal(text, integer, integer, integer), bp_suggest(text, text, text),
    bp_add_sale(text, text, text, integer, integer, integer, date, text),
    bp_entry_save(text, bigint, date, text, text, text, bigint, bigint), bp_entry_delete(text, bigint)
to anon, authenticated;
