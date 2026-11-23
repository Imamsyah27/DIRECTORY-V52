-- =====================================================================
-- BOT ORDER: TANDAI SUDAH DIKIRIM (dicentang admin) + ARSIP
-- Jalankan SEKALI di Supabase SQL Editor, SETELAH bot-order.sql. Aman dijalankan ulang.
--
-- Alur status: Menunggu -> (admin SETUJUI) -> Perlu Dikirim -> (admin CENTANG "Dikirim") -> Terkirim
--              -> (admin ARSIPKAN) -> Arsip.   Pesanan Ditolak juga bisa diarsipkan.
-- Pelanggan melihat status terbaru di tab "Bot Order" pada dashboard mereka.
-- =====================================================================

alter table bot_orders add column if not exists dikirim_at timestamptz;
alter table bot_orders add column if not exists arsip boolean not null default false;
alter table bot_orders add column if not exists arsip_at timestamptz;
create index if not exists bot_orders_arsip_idx on bot_orders (arsip, status);

-- Admin: antrian (sekarang ikut membawa dikirim_at & arsip)
create or replace function bot_list(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v jsonb;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    select coalesce(jsonb_agg(to_jsonb(r) order by r.created_at desc), '[]'::jsonb) into v
    from (select b.id, b.username, b.dashboard, b.jumlah, b.tagar_list[1] as tagar_pertama, b.catatan_pelanggan,
                 b.harga_tagar, b.total_harga, b.status, b.catatan_admin, b.created_at, b.processed_at,
                 b.dikirim_at, b.arsip, b.arsip_at,
                 (select ca.whatsapp from customer_accounts ca where ca.id = b.customer_id) as whatsapp
            from bot_orders b order by b.created_at desc limit 500) r;
    return v;
end; $$;

-- Pelanggan: riwayat bot order (termasuk status dikirim & arsip)
create or replace function cu_my_bot_orders(p_session_token uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare acc customer_accounts%rowtype; v jsonb;
begin
    acc := portal_session_acc(p_session_token);
    select coalesce(jsonb_agg(jsonb_build_object(
        'id', b.id, 'dashboard', b.dashboard, 'jumlah', b.jumlah, 'tagar_pertama', b.tagar_list[1],
        'harga_tagar', b.harga_tagar, 'total_harga', b.total_harga, 'status', b.status,
        'catatan_admin', b.catatan_admin, 'created_at', b.created_at, 'processed_at', b.processed_at,
        'dikirim_at', b.dikirim_at, 'arsip', b.arsip
    ) order by b.created_at desc), '[]'::jsonb) into v
    from (select * from bot_orders where customer_id = acc.id order by created_at desc limit 100) b;
    return v;
end; $$;

-- Admin: centang / lepas centang "sudah dikirim" (hanya untuk pesanan yang sudah disetujui)
create or replace function bot_set_dikirim(p_pin text, p_id bigint, p_dikirim boolean)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare b bot_orders%rowtype;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    select * into b from bot_orders where id = p_id for update;
    if not found then raise exception 'Pesanan tidak ditemukan'; end if;
    if b.status <> 'approved' then raise exception 'Hanya pesanan yang sudah disetujui yang bisa ditandai dikirim'; end if;
    if b.arsip then raise exception 'Pesanan sudah diarsipkan'; end if;
    update bot_orders set dikirim_at = case when coalesce(p_dikirim, false) then now() else null end where id = p_id;
    return jsonb_build_object('id', p_id, 'dikirim', coalesce(p_dikirim, false));
end; $$;

-- Admin: arsipkan / kembalikan dari arsip.
-- Boleh diarsipkan: yang sudah DIKIRIM, atau yang DITOLAK. (Menunggu / belum dikirim tidak bisa.)
create or replace function bot_set_arsip(p_pin text, p_id bigint, p_arsip boolean)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare b bot_orders%rowtype;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    select * into b from bot_orders where id = p_id for update;
    if not found then raise exception 'Pesanan tidak ditemukan'; end if;
    if coalesce(p_arsip, false) then
        if not (b.status = 'rejected' or (b.status = 'approved' and b.dikirim_at is not null)) then
            raise exception 'Hanya pesanan yang sudah dikirim atau ditolak yang bisa diarsipkan';
        end if;
        update bot_orders set arsip = true, arsip_at = now() where id = p_id;
    else
        update bot_orders set arsip = false, arsip_at = null where id = p_id;
    end if;
end; $$;

-- Admin: arsipkan sekaligus semua yang sudah dikirim
create or replace function bot_archive_sent(p_pin text)
returns integer language plpgsql security definer set search_path = public, extensions as $$
declare n integer;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    update bot_orders set arsip = true, arsip_at = now()
     where status = 'approved' and dikirim_at is not null and not arsip;
    get diagnostics n = row_count;
    return n;
end; $$;

grant execute on function
    bot_list(text), cu_my_bot_orders(uuid), bot_set_dikirim(text, bigint, boolean),
    bot_set_arsip(text, bigint, boolean), bot_archive_sent(text)
to anon, authenticated;
