-- =====================================================================
-- BOT ORDER — pelanggan bisa membuka DAFTAR TAGAR pesanan bot order miliknya
-- (sama seperti admin yang bisa membuka daftar tagar lewat bot_tags).
-- Jalankan SETELAH bot-order.sql. Aman diulang.
-- Pelanggan hanya bisa melihat tagar pesanan MILIKNYA sendiri.
-- =====================================================================
create or replace function cu_bot_tags(p_session_token uuid, p_id bigint)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare acc customer_accounts%rowtype; v text[];
begin
    acc := portal_session_acc(p_session_token);
    select tagar_list into v from bot_orders where id = p_id and customer_id = acc.id;
    if not found then raise exception 'Pesanan tidak ditemukan'; end if;
    return to_jsonb(v);
end; $$;

grant execute on function cu_bot_tags(uuid, bigint) to anon, authenticated;
