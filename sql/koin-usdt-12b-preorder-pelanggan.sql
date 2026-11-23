-- =====================================================================
-- KOIN — BAGIAN 12 (2/2): PRE ORDER — fungsi PELANGGAN + daftar item harga (pi_catalog) yang menyertakan Pre Order
-- Jalankan SETELAH koin-usdt-12-preorder.sql. Aman diulang.
-- =====================================================================

-- ---------------- PELANGGAN ----------------
create or replace function cu_preorder_items(p_session_token uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare acc customer_accounts%rowtype;
begin
    acc := portal_session_acc(p_session_token);
    return coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'nama', p.nama, 'deskripsi', p.deskripsi,
                'harga_koin', pi_final(acc.id, 'pre:' || p.id, p.harga_koin), 'harga_normal', pi_normal(acc.id, 'pre:' || p.id, p.harga_koin),
                'per_farm', p.per_farm, 'max_barang', p.max_barang, 'max_tagar', p.max_tagar,
                'img_v', (select (extract(epoch from i.updated_at) * 1000)::bigint from preorder_images i where i.item_id = p.id)) order by p.urut, p.id)
              from preorder_items p where p.aktif and p.harga_koin > 0), '[]'::jsonb);
end; $$;

create or replace function cu_preorder_image(p_session_token uuid, p_item_id bigint)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v jsonb;
begin
    perform portal_session_acc(p_session_token);
    select jsonb_build_object('mime', i.mime, 'data', i.data) into v
      from preorder_images i join preorder_items p on p.id = i.item_id where i.item_id = p_item_id and p.aktif;
    return v;
end; $$;

-- p_batches = [ [ {"tagar":"#a","jumlah":3}, ... ], [ ... ] ]  (tiap array = 1 batch). Atomik: gagal sebagian = batal semua.
create or replace function cu_place_preorder(p_session_token uuid, p_item_id bigint, p_batches jsonb, p_catatan text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare acc customer_accounts%rowtype; it preorder_items%rowtype; v_price bigint; v_grup uuid := gen_random_uuid();
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
    v_price := pi_final(acc.id, 'pre:' || it.id, it.harga_koin);

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
        v_total := v_tb::bigint * v_price;
        insert into preorder_orders (grup, batch_no, batch_total, customer_id, username, item_id, item_nama, harga_satuan, per_farm, lines,
                                     total_farm, total_barang, total_koin, catatan)
        values (v_grup, bi, nb, acc.id, acc.username, it.id, it.nama, v_price, it.per_farm, v_lines, v_tf, v_tb, v_total,
                nullif(left(trim(coalesce(p_catatan, '')), 300), '')) returning id into v_id;
        perform coin_apply(acc.id, -v_total, 'order', 'Pre Order ' || left(it.nama, 40) || ' · batch ' || bi || ' · #' || v_id, 'preorder', v_id);
        v_all := v_all + v_total;
    end loop;
    return jsonb_build_object('grup', v_grup, 'batches', nb, 'total', v_all);
end; $$;

create or replace function cu_my_preorders(p_session_token uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare acc customer_accounts%rowtype;
begin
    acc := portal_session_acc(p_session_token);
    return coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'grup', o.grup, 'batch_no', o.batch_no, 'batch_total', o.batch_total, 'item_nama', o.item_nama,
                'lines', o.lines, 'total_farm', o.total_farm, 'total_barang', o.total_barang, 'total_koin', o.total_koin, 'status', o.status,
                'catatan_admin', o.catatan_admin, 'created_at', o.created_at) order by o.created_at desc, o.batch_no)
              from (select * from preorder_orders where customer_id = acc.id order by created_at desc, batch_no limit 30) o), '[]'::jsonb);
end; $$;

-- pi_catalog: sama seperti bagian 11 + barang Pre Order (otomatis ikut bila ada barang baru)
create or replace function pi_catalog(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    return coalesce((select jsonb_agg(to_jsonb(r) order by r.ord, r.sub, r.nama) from (
        select ('farm:' || b.id)::text as key, 'Farm'::text as grup, '🌱'::text as ikon, 1 as ord, ''::text as sub, b.nama::text as nama, b.harga_koin as harga, '/ token'::text as satuan
          from farm_batches b where b.etalase and b.harga_koin > 0
        union all
        select 'hav:' || b.id, 'Hav Token', '🔑', 2, '', b.nama, b.harga_koin, '/ key' from hav_batches b where b.etalase and b.harga_koin > 0
        union all
        select 'sup:' || b.id || ':100', 'Product (Supply & Stock)', '📦', 3, b.nama, coalesce(nullif(b.item, ''), b.nama) || ' · 100 ' || b.satuan, b.price_100::bigint, 'total' from supply_batches b where b.visible and b.price_100 > 0
        union all
        select 'sup:' || b.id || ':500', 'Product (Supply & Stock)', '📦', 3, b.nama, coalesce(nullif(b.item, ''), b.nama) || ' · 500 ' || b.satuan, b.price_500::bigint, 'total' from supply_batches b where b.visible and b.price_500 > 0
        union all
        select 'sup:' || b.id || ':1000', 'Product (Supply & Stock)', '📦', 3, b.nama, coalesce(nullif(b.item, ''), b.nama) || ' · 1000 ' || b.satuan, b.price_1000::bigint, 'total' from supply_batches b where b.visible and b.price_1000 > 0
        union all
        select 'pre:' || p.id, 'Pre Order', '📝', 4, '', p.nama, p.harga_koin, '/ barang' from preorder_items p where p.harga_koin > 0
        union all
        select 'cat:' || c.id, coalesce(k.nama, c.kategori), coalesce(k.ikon, '🛍'), 10 + coalesce(k.urut, 99), c.kategori, c.nama, c.harga_koin, '/ item'
          from catalog_items c left join catalog_categories k on k.slug = c.kategori where c.kategori <> 'farm' and c.harga_koin > 0
    ) r), '[]'::jsonb);
end; $$;

grant execute on function
    cu_preorder_items(uuid), cu_preorder_image(uuid, bigint), cu_place_preorder(uuid, bigint, jsonb, text), cu_my_preorders(uuid), pi_catalog(text)
to anon, authenticated;
