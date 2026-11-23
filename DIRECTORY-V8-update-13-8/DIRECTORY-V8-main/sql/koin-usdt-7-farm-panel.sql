-- =====================================================================
-- KOIN — BAGIAN 7/8: ETALASE FARM OTOMATIS (beli pakai koin, token langsung dikirim) + PANEL (nomor WhatsApp)
-- Jalankan SETELAH bagian 1-6 dan farmsell.sql. Aman diulang.
--
-- FARM  : batch di menu Farm Sell otomatis tersambung ke tab Farm katalog pelanggan bila admin
--         menyalakan "Tampilkan di etalase" + mengisi harga koin per token. Saldo cukup -> token
--         sebanyak jumlah yang dibeli langsung dikirim ke pelanggan (otomatis, tanpa menunggu admin).
-- PANEL : nomor WhatsApp admin untuk (1) kirim bukti pembayaran, (2) order supply & stock.
-- =====================================================================

alter table farm_batches add column if not exists etalase boolean not null default false;
alter table farm_batches add column if not exists harga_koin bigint not null default 0 check (harga_koin >= 0);

create table if not exists farm_sales (
    id bigint generated always as identity primary key,
    customer_id bigint not null references customer_accounts(id) on delete cascade,
    username text not null,
    batch_id bigint,
    batch_nama text not null,
    qty integer not null,
    harga_satuan bigint not null,
    total bigint not null,
    tokens jsonb not null default '[]'::jsonb,
    created_at timestamptz not null default now()
);
create index if not exists farm_sales_cust_idx on farm_sales (customer_id, created_at desc);
alter table farm_sales enable row level security;      -- tanpa policy publik (token = rahasia)

create or replace function fs_list_batches(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v jsonb;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    select coalesce(jsonb_agg(jsonb_build_object(
        'id', b.id, 'nama', b.nama, 'created_at', b.created_at, 'etalase', b.etalase, 'harga_koin', b.harga_koin,
        'available', (select count(*) from farm_tokens t where t.batch_id = b.id and t.status = 'available'),
        'taken', (select count(*) from farm_tokens t where t.batch_id = b.id and t.status = 'taken')
    ) order by b.id), '[]'::jsonb) into v from farm_batches b;
    return v;
end; $$;

create or replace function fs_set_etalase(p_pin text, p_id bigint, p_show boolean, p_harga bigint)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    if coalesce(p_harga, -1) < 0 or p_harga > 1000000000 then raise exception 'Harga koin tidak valid'; end if;
    if p_show and p_harga <= 0 then raise exception 'Isi harga koin per token dulu'; end if;
    update farm_batches set etalase = coalesce(p_show, false), harga_koin = p_harga where id = p_id;
end; $$;

-- Pelanggan: farm yang dipajang admin (otomatis dari Farm Sell)
create or replace function cu_farm_shop(p_session_token uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
    perform portal_session_acc(p_session_token);
    return coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'nama', b.nama, 'harga_koin', b.harga_koin,
                'available', (select count(*) from farm_tokens t where t.batch_id = b.id and t.status = 'available')) order by b.id)
              from farm_batches b where b.etalase and b.harga_koin > 0), '[]'::jsonb);
end; $$;

-- Pelanggan: beli token farm. Saldo kurang / stok kurang = ditolak. Token langsung dikirim.
create or replace function cu_buy_farm(p_session_token uuid, p_batch_id bigint, p_qty integer)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare acc customer_accounts%rowtype; b farm_batches%rowtype; v_tokens jsonb; v_n integer; v_total bigint; v_id bigint;
begin
    acc := portal_session_acc(p_session_token);
    if p_qty is null or p_qty < 1 or p_qty > 1000 then raise exception 'Jumlah pesanan tidak valid'; end if;
    select * into b from farm_batches where id = p_batch_id;
    if not found or not b.etalase or b.harga_koin <= 0 then raise exception 'Farm tidak tersedia'; end if;
    v_total := b.harga_koin * p_qty;

    with pick as (select id from farm_tokens where batch_id = b.id and status = 'available' order by no limit p_qty for update skip locked),
         upd as (update farm_tokens t set status = 'taken', taken_at = now() from pick where t.id = pick.id returning t.no, t.farm_id, t.token)
    select coalesce(jsonb_agg(jsonb_build_object('no', upd.no, 'farm_id', upd.farm_id, 'token', upd.token) order by upd.no), '[]'::jsonb), count(*)
      into v_tokens, v_n from upd;
    if v_n < p_qty then raise exception 'Stok farm tidak cukup'; end if;       -- membatalkan semuanya

    insert into farm_sales (customer_id, username, batch_id, batch_nama, qty, harga_satuan, total, tokens)
    values (acc.id, acc.username, b.id, b.nama, p_qty, b.harga_koin, v_total, v_tokens) returning id into v_id;
    perform coin_apply(acc.id, -v_total, 'order', 'Farm ' || left(b.nama, 40) || ' x' || p_qty || ' · #' || v_id, 'farm', v_id);
    return jsonb_build_object('id', v_id, 'qty', p_qty, 'total', v_total, 'tokens', v_tokens);
end; $$;

create or replace function cu_my_farm_sales(p_session_token uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare acc customer_accounts%rowtype;
begin
    acc := portal_session_acc(p_session_token);
    return coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'batch_nama', s.batch_nama, 'qty', s.qty, 'total', s.total, 'tokens', s.tokens,
                'created_at', s.created_at) order by s.created_at desc)
              from (select * from farm_sales where customer_id = acc.id order by created_at desc limit 20) s), '[]'::jsonb);
end; $$;

-- Admin: riwayat penjualan farm (tanpa isi token)
create or replace function fs_sales_list(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    return coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'username', s.username, 'batch_nama', s.batch_nama, 'qty', s.qty,
                'harga_satuan', s.harga_satuan, 'total', s.total, 'created_at', s.created_at) order by s.created_at desc)
              from (select * from farm_sales order by created_at desc limit 300) s), '[]'::jsonb);
end; $$;

-- ---------------- PANEL: nomor WhatsApp ----------------
create table if not exists panel_settings (
    id integer primary key default 1 check (id = 1),
    wa_bukti text not null default '',
    wa_supply text not null default '',
    updated_at timestamptz not null default now()
);
insert into panel_settings (id) values (1) on conflict (id) do nothing;
alter table panel_settings enable row level security;      -- tanpa policy publik

create or replace function pn_get(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    return (select to_jsonb(s) from panel_settings s where s.id = 1);
end; $$;

-- Nomor dinormalkan: hanya angka, awalan 0 -> 62. Kosong = pakai nomor bawaan aplikasi.
create or replace function pn_save(p_pin text, p_wa_bukti text, p_wa_supply text)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare a text := regexp_replace(coalesce(p_wa_bukti, ''), '[^0-9]', '', 'g'); b text := regexp_replace(coalesce(p_wa_supply, ''), '[^0-9]', '', 'g');
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    if a like '0%' then a := '62' || substr(a, 2); end if;
    if b like '0%' then b := '62' || substr(b, 2); end if;
    if (a <> '' and length(a) not between 8 and 15) or (b <> '' and length(b) not between 8 and 15) then raise exception 'Nomor WhatsApp tidak valid'; end if;
    update panel_settings set wa_bukti = a, wa_supply = b, updated_at = now() where id = 1;
end; $$;

create or replace function cu_panel_info(p_session_token uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
    perform portal_session_acc(p_session_token);
    return (select jsonb_build_object('wa_bukti', s.wa_bukti, 'wa_supply', s.wa_supply) from panel_settings s where s.id = 1);
end; $$;

grant execute on function
    fs_list_batches(text), fs_set_etalase(text, bigint, boolean, bigint), cu_farm_shop(uuid), cu_buy_farm(uuid, bigint, integer),
    cu_my_farm_sales(uuid), fs_sales_list(text), pn_get(text), pn_save(text, text, text), cu_panel_info(uuid)
to anon, authenticated;
