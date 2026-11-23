-- =====================================================================
-- KOIN — BAGIAN 14c/3: MODAL -> CASHFLOW
-- Butuh koin-usdt-14-modal.sql. CashFlow: pilih barang, modal & profit per transaksi.
-- Aman diulang. Jalankan berurutan: 13, 14, 14b, 14c, 15.
-- =====================================================================

-- ---------------- CASHFLOW: modal & profit per transaksi ----------------
drop function if exists cf_add_entry(text, bigint, text, text, bigint, integer);
drop function if exists cf_update_entry(text, bigint, text, text, bigint, integer);

create or replace function cf_list_batches(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_result jsonb;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    select coalesce(jsonb_agg(row_data order by row_id), '[]'::jsonb) into v_result from (
        select b.id as row_id, jsonb_build_object('id', b.id, 'nama', b.nama, 'status', b.status, 'created_at', b.created_at, 'withdrawn_at', b.withdrawn_at,
                'total', coalesce(sum(e.harga * e.jumlah), 0), 'total_modal', coalesce(sum(e.modal * e.jumlah), 0),
                'profit', coalesce(sum((e.harga - e.modal) * e.jumlah), 0), 'item_count', count(e.id)) as row_data
          from cashflow_batches b left join cashflow_entries e on e.batch_id = b.id group by b.id) sub;
    return v_result;
end; $$;

create or replace function cf_list_entries(p_pin text, p_batch_id bigint)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_result jsonb;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'nama', e.nama, 'produk', e.produk, 'harga', e.harga, 'jumlah', e.jumlah,
            'modal', e.modal, 'item_key', e.item_key, 'total', e.harga * e.jumlah, 'total_modal', e.modal * e.jumlah,
            'profit', (e.harga - e.modal) * e.jumlah, 'created_at', e.created_at) order by e.id), '[]'::jsonb)
      into v_result from cashflow_entries e where e.batch_id = p_batch_id;
    return v_result;
end; $$;

-- Pilih barang (p_item_key): modal diambil dari menu Modal; harga jual = p_harga (bila 0 -> harga etalase)
create or replace function cf_add_entry(p_pin text, p_batch_id bigint, p_nama text, p_produk text, p_harga bigint, p_jumlah integer,
                                        p_item_key text default null, p_modal bigint default null)
returns bigint language plpgsql security definer set search_path = public, extensions as $$
declare v_id bigint; v_status text; v_modal bigint := coalesce(p_modal, 0); v_harga bigint := p_harga; v_produk text := trim(coalesce(p_produk, '')); it record;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    select b.status into v_status from cashflow_batches b where b.id = p_batch_id;
    if v_status is null then raise exception 'Batch tidak ditemukan'; end if;
    if v_status <> 'active' then raise exception 'Batch sudah diambil (withdraw), aktifkan kembali untuk menambah data'; end if;
    if p_item_key is not null and p_item_key <> '' then
        select * into it from md_all_items() i where i.key = p_item_key and p_item_key not like 'bsl:%';
        if not found then raise exception 'Barang tidak ditemukan di etalase'; end if;
        if p_modal is null then v_modal := md_get(p_item_key); end if;
        if coalesce(v_harga, 0) <= 0 then v_harga := coalesce(it.harga, 0); end if;
        if v_produk = '' then v_produk := it.nama; end if;
    end if;
    if p_nama is null or trim(p_nama) = '' then raise exception 'Nama wajib diisi'; end if;
    if v_produk = '' then raise exception 'Produk wajib diisi'; end if;
    if v_harga is null or v_harga < 0 then raise exception 'Harga tidak valid'; end if;
    if v_modal < 0 then raise exception 'Modal tidak valid'; end if;
    if p_jumlah is null or p_jumlah < 1 then raise exception 'Jumlah minimal 1'; end if;
    insert into cashflow_entries (batch_id, nama, produk, harga, jumlah, modal, item_key)
    values (p_batch_id, trim(p_nama), v_produk, v_harga, p_jumlah, v_modal, nullif(p_item_key, '')) returning id into v_id;
    return v_id;
end; $$;

create or replace function cf_update_entry(p_pin text, p_id bigint, p_nama text, p_produk text, p_harga bigint, p_jumlah integer, p_modal bigint default null)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_status text;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    select b.status into v_status from cashflow_entries e join cashflow_batches b on b.id = e.batch_id where e.id = p_id;
    if v_status is null then raise exception 'Data tidak ditemukan'; end if;
    if v_status <> 'active' then raise exception 'Batch sudah diambil (withdraw), aktifkan kembali untuk mengubah data'; end if;
    if p_nama is null or trim(p_nama) = '' then raise exception 'Nama wajib diisi'; end if;
    if p_produk is null or trim(p_produk) = '' then raise exception 'Produk wajib diisi'; end if;
    if p_harga is null or p_harga < 0 then raise exception 'Harga tidak valid'; end if;
    if coalesce(p_modal, 0) < 0 then raise exception 'Modal tidak valid'; end if;
    if p_jumlah is null or p_jumlah < 1 then raise exception 'Jumlah minimal 1'; end if;
    update cashflow_entries set nama = trim(p_nama), produk = trim(p_produk), harga = p_harga, jumlah = p_jumlah, modal = coalesce(p_modal, modal) where id = p_id;
end; $$;

grant execute on function
    cf_list_batches(text), cf_list_entries(text, bigint),
    cf_add_entry(text, bigint, text, text, bigint, integer, text, bigint), cf_update_entry(text, bigint, text, text, bigint, integer, bigint)
to anon, authenticated;
