-- =====================================================================
-- MIGRASI 003 — TOTAL TAGAR BOT ORDER PER HARI (portal pelanggan)
-- Jalankan SEKALI di Supabase SQL Editor. Aman diulang.
-- Dihitung di database (group by tanggal); browser hanya menerima 1 baris per hari.
-- Pelanggan hanya melihat miliknya sendiri: customer_id diambil dari sesi login, bukan dari parameter.
-- Tanggal memakai zona Asia/Jakarta (sama dengan pencatatan BSL Profit).
-- Pesanan yang ditolak / dibatalkan tidak dihitung.
-- =====================================================================

-- Index customer_id + tanggal pesan. Index ini sudah dibuat oleh sql/bot-order.sql;
-- "if not exists" memastikan ada tanpa membuat duplikat.
create index if not exists bot_orders_customer_idx on bot_orders (customer_id, created_at desc);

create or replace function cu_bot_daily(p_session_token uuid, p_days integer default 7)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare acc customer_accounts%rowtype; v_days integer; v_today date; v_from date;
begin
    acc := portal_session_acc(p_session_token);
    v_days := least(greatest(coalesce(p_days, 7), 1), 90);
    v_today := (now() at time zone 'Asia/Jakarta')::date;
    v_from := v_today - (v_days - 1);
    return coalesce((
        select jsonb_agg(jsonb_build_object('tanggal', d.tgl, 'pesanan', coalesce(s.pesanan, 0), 'tagar', coalesce(s.tagar, 0)) order by d.tgl desc)
          from generate_series(v_from, v_today, interval '1 day') as d0(t)
          cross join lateral (select d0.t::date as tgl) d
          left join (
                select (b.created_at at time zone 'Asia/Jakarta')::date as tgl, count(*)::int as pesanan, sum(b.jumlah)::int as tagar
                  from bot_orders b
                 where b.customer_id = acc.id
                   and b.status <> 'rejected'
                   -- batas bawah dalam timestamptz supaya index (customer_id, created_at) terpakai
                   and b.created_at >= (v_from::timestamp at time zone 'Asia/Jakarta')
                 group by 1) s on s.tgl = d.tgl), '[]'::jsonb);
end; $$;
revoke all on function cu_bot_daily(uuid, integer) from public;
grant execute on function cu_bot_daily(uuid, integer) to anon, authenticated;
