-- =====================================================================
-- KOIN — BAGIAN 19: PRE ORDER — MINIMAL PEMBELIAN 10.000 BARANG & MAKSIMAL 10.000 BARANG PER BATCH
-- Jalankan SETELAH koin-usdt-13. Aman diulang (penyesuaian data lama hanya SEKALI).
--  * Minimal pembelian = total barang semua batch dalam 1 pemesanan (default 10.000).
--  * Maksimal per batch = max_barang (default 10.000). Barang lama otomatis diset 10.000 / 10.000 sekali ini.
--  Keduanya tetap bisa diubah admin per barang.
-- =====================================================================
do $$
begin
    if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'preorder_items' and column_name = 'min_barang') then
        alter table preorder_items add column min_barang integer not null default 10000 check (min_barang between 0 and 1000000);
        update preorder_items set max_barang = 10000, min_barang = 10000;
    end if;
end $$;

create or replace function po_list_items(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    return coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'nama', p.nama, 'deskripsi', p.deskripsi, 'harga_koin', p.harga_koin,
                'per_farm', p.per_farm, 'max_barang', p.max_barang, 'min_barang', p.min_barang, 'max_tagar', p.max_tagar, 'aktif', p.aktif,
                'img_v', (select (extract(epoch from i.updated_at) * 1000)::bigint from preorder_images i where i.item_id = p.id),
                'pending', (select count(*) from preorder_orders o where o.item_id = p.id and o.status = 'pending')) order by p.urut, p.id)
              from preorder_items p), '[]'::jsonb);
end; $$;

create or replace function cu_preorder_items(p_session_token uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare acc customer_accounts%rowtype;
begin
    acc := portal_session_acc(p_session_token);
    return coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'nama', p.nama, 'deskripsi', p.deskripsi,
                'harga_koin', pi_final(acc.id, 'pre:' || p.id, p.harga_koin), 'harga_normal', pi_normal(acc.id, 'pre:' || p.id, p.harga_koin),
                'per_farm', p.per_farm, 'max_barang', p.max_barang, 'min_barang', p.min_barang, 'max_tagar', p.max_tagar,
                'img_v', (select (extract(epoch from i.updated_at) * 1000)::bigint from preorder_images i where i.item_id = p.id)) order by p.urut, p.id)
              from preorder_items p where p.aktif and p.harga_koin > 0), '[]'::jsonb);
end; $$;

drop function if exists po_save_item(text, bigint, text, text, bigint, integer, integer, boolean);
create or replace function po_save_item(p_pin text, p_id bigint, p_nama text, p_deskripsi text, p_harga bigint, p_per_farm integer, p_max_barang integer, p_aktif boolean, p_min_barang integer default 10000)
returns bigint language plpgsql security definer set search_path = public, extensions as $$
declare v_id bigint := p_id; v_nama text := trim(coalesce(p_nama, '')); v_pf integer := coalesce(p_per_farm, 100);
        v_mx integer := coalesce(p_max_barang, 10000); v_mn integer := coalesce(p_min_barang, 10000);
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    if v_nama = '' or length(v_nama) > 80 then raise exception 'Nama barang wajib diisi (maks. 80 karakter)'; end if;
    if coalesce(p_harga, -1) < 0 or p_harga > 1000000000 then raise exception 'Harga koin tidak valid'; end if;
    if v_pf < 1 or v_pf > 100000 then raise exception 'Isi barang per farm tidak valid'; end if;
    if v_mx < v_pf or v_mx > 1000000 then raise exception 'Batas barang per batch tidak valid'; end if;
    if v_mn < 0 or v_mn > 1000000 then raise exception 'Minimal pembelian tidak valid'; end if;
    if v_id is null then
        insert into preorder_items (nama, deskripsi, harga_koin, per_farm, max_barang, min_barang, aktif, urut)
        values (v_nama, left(trim(coalesce(p_deskripsi, '')), 500), p_harga, v_pf, v_mx, v_mn, coalesce(p_aktif, true),
                coalesce((select max(urut) + 1 from preorder_items), 0)) returning id into v_id;
    else
        update preorder_items set nama = v_nama, deskripsi = left(trim(coalesce(p_deskripsi, '')), 500), harga_koin = p_harga,
               per_farm = v_pf, max_barang = v_mx, min_barang = v_mn, aktif = coalesce(p_aktif, aktif) where id = v_id;
        if not found then raise exception 'Barang tidak ditemukan'; end if;
    end if;
    return v_id;
end; $$;

create or replace function cu_place_preorder(p_session_token uuid, p_item_id bigint, p_batches jsonb, p_catatan text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare acc customer_accounts%rowtype; it preorder_items%rowtype; v_price bigint; v_grup uuid := gen_random_uuid(); v_sum_tb bigint := 0;
        nb integer; bi integer := 0; b jsonb; ln jsonb; v_lines jsonb; v_tag text; v_seen text[]; v_farm integer;
        v_tf integer; v_tb integer; v_total bigint; v_all bigint := 0; v_id bigint;
begin
    acc := portal_session_acc(p_session_token);
    select * into it from preorder_items where id = p_item_id;
    if not found or not it.aktif then raise exception 'Pre Order tidak tersedia'; end if;
    if it.harga_koin <= 0 then raise exception 'Harga Pre Order belum diatur admin'; end if;
    if p_batches is null or jsonb_typeof(p_batches) <> 'array' or jsonb_array_length(p_batches) < 1 then raise exception 'Isi minimal 1 batch'; end if;
    nb := jsonb_array_length(p_batches);
    if nb > 5 then raise exception 'Maksimal 5 batch per pemesanan'; end if;
    if (select count(*) from preorder_orders where customer_id = acc.id and status = 'pending') + nb > 30 then
        raise exception 'Terlalu banyak Pre Order yang masih menunggu'; end if;
    v_price := pi_final(acc.id, 'pre:' || it.id, it.harga_koin);          -- harga per 10.000 barang

    for b in select value from jsonb_array_elements(p_batches) loop
        bi := bi + 1; v_lines := '[]'::jsonb; v_seen := '{}'; v_tf := 0;
        if jsonb_typeof(b) <> 'array' or jsonb_array_length(b) < 1 then raise exception 'Batch % kosong', bi; end if;
        if jsonb_array_length(b) > it.max_tagar then raise exception 'Batch %: maksimal % tagar', bi, it.max_tagar; end if;
        for ln in select value from jsonb_array_elements(b) loop
            v_tag := left(trim(coalesce(ln->>'tagar', '')), 100);
            if v_tag = '' then raise exception 'Batch %: tagar tidak boleh kosong', bi; end if;
            if lower(replace(v_tag, '#', '')) = any(v_seen) then raise exception 'Batch %: tagar % tertulis dobel', bi, v_tag; end if;
            v_seen := v_seen || lower(replace(v_tag, '#', ''));
            if not (coalesce(ln->>'jumlah', '') ~ '^[0-9]{1,6}$') then raise exception 'Batch %: jumlah untuk % harus angka bulat minimal 1', bi, v_tag; end if;
            v_farm := (ln->>'jumlah')::integer;
            if v_farm < 1 then raise exception 'Batch %: jumlah untuk % harus angka bulat minimal 1', bi, v_tag; end if;
            v_tf := v_tf + v_farm;
            v_lines := v_lines || jsonb_build_array(jsonb_build_object('tagar', v_tag, 'jumlah', v_farm, 'barang', v_farm * it.per_farm));
        end loop;
        v_tb := v_tf * it.per_farm;
        if v_tb > it.max_barang then raise exception 'Batch %: maksimal % barang per pemesanan (kamu mengisi %). Lanjutkan di batch / pemesanan berikutnya.', bi, it.max_barang, v_tb; end if;
        v_sum_tb := v_sum_tb + v_tb;
        v_total := po_cost(v_tb, v_price);
        insert into preorder_orders (grup, batch_no, batch_total, customer_id, username, item_id, item_nama, harga_satuan, harga_10k, per_farm, lines,
                                     total_farm, total_barang, total_koin, catatan)
        values (v_grup, bi, nb, acc.id, acc.username, it.id, it.nama, greatest((v_price + 9999) / 10000, 0), v_price, it.per_farm, v_lines,
                v_tf, v_tb, v_total, nullif(left(trim(coalesce(p_catatan, '')), 300), '')) returning id into v_id;
        perform coin_apply(acc.id, -v_total, 'order', 'Pre Order ' || left(it.nama, 40) || ' · batch ' || bi || ' · #' || v_id, 'preorder', v_id);
        v_all := v_all + v_total;
    end loop;
    if v_sum_tb < it.min_barang then raise exception 'Minimal pembelian % barang (total kamu %)', it.min_barang, v_sum_tb; end if;   -- membatalkan semua batch
    return jsonb_build_object('grup', v_grup, 'batches', nb, 'total', v_all);
end; $$;

grant execute on function po_list_items(text), cu_preorder_items(uuid),
    po_save_item(text, bigint, text, text, bigint, integer, integer, boolean, integer), cu_place_preorder(uuid, bigint, jsonb, text) to anon, authenticated;
