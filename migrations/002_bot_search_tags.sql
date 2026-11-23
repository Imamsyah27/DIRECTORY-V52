-- =====================================================================
-- MIGRASI 002 — PENCARIAN TAGAR BOT ORDER (admin)
-- Jalankan SEKALI di Supabase SQL Editor (setelah 001). Aman diulang.
-- Dipakai hanya bila tagar lengkap pesanan belum dimuat di browser.
-- Hasil: maks. 50 pesanan, kolom seperlunya (id + tagar pertama yang cocok).
-- =====================================================================
create or replace function bot_search_tags(p_pin text, p_q text, p_bulk boolean default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_q text; v jsonb;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    v_q := left(ltrim(trim(coalesce(p_q, '')), '#'), 60);
    if length(v_q) < 2 then return '[]'::jsonb; end if;
    -- karakter wildcard dari input dianggap huruf biasa
    v_q := '%' || replace(replace(replace(v_q, '\', '\\'), '%', '\%'), '_', '\_') || '%';
    -- limit 50 dipasang SEBELUM agregasi supaya benar-benar membatasi jumlah baris
    select coalesce(jsonb_agg(jsonb_build_object('id', h.id, 'tagar', h.tagar) order by h.created_at desc), '[]'::jsonb) into v
      from (select r.id, r.created_at, r.tagar
              from (select b.id, b.created_at,
                           (select t from unnest(coalesce(b.tagar_list, '{}') || coalesce(b.tagar_bem, '{}') || coalesce(b.tagar_sem, '{}') || coalesce(b.tagar_lem, '{}')) t
                             where t ilike v_q escape '\' limit 1) as tagar
                      from bot_orders b
                     where (p_bulk is null or (b.dashboard = 'BULK') = p_bulk)) r
             where r.tagar is not null
             order by r.created_at desc
             limit 50) h;
    return v;
end; $$;
grant execute on function bot_search_tags(text, text, boolean) to anon, authenticated;
