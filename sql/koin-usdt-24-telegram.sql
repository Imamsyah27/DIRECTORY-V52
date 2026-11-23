-- =====================================================================
-- KOIN — BAGIAN 24: NOTIFIKASI BOT TELEGRAM KHUSUS ADMIN (pengaturan + pengirim + fungsi admin)
-- Jalankan SETELAH koin-usdt-23b. Aman diulang. Lanjutkan dengan koin-usdt-24b-telegram-trigger.sql
--  * Database memanggil API Telegram langsung lewat ekstensi pg_net (tanpa server tambahan).
--    Bila perintah di bawah gagal: Supabase Dashboard -> Database -> Extensions -> aktifkan "pg_net", lalu jalankan ulang.
--  * Token bot disimpan di tabel tg_settings (tanpa akses publik; hanya fungsi berPIN admin yang bisa membaca/menulis).
-- =====================================================================
do $$
begin
    create extension if not exists pg_net with schema extensions;
exception when others then
    raise notice 'pg_net belum aktif: aktifkan di Dashboard Supabase -> Database -> Extensions -> pg_net';
end $$;

create table if not exists tg_settings (
    id integer primary key default 1 check (id = 1),
    bot_token text,
    chat_id text,
    aktif boolean not null default false,
    events jsonb not null default '{"langganan":true,"bot":true,"bulk":true,"koin":true,"voucher":true,"supply":true,"preorder":true,"topup":true,"request":true,"farm":false,"hav":false}'::jsonb,
    updated_at timestamptz not null default now()
);
insert into tg_settings (id) values (1) on conflict (id) do nothing;
alter table tg_settings enable row level security;       -- tanpa policy publik

create or replace function tg_esc(t text) returns text language sql immutable as $$
    select replace(replace(replace(coalesce(t, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
$$;
create or replace function tg_rp(n numeric) returns text language sql immutable as $$
    select 'Rp ' || replace(to_char(coalesce(n, 0), 'FM999,999,999,999,999'), ',', '.');
$$;
create or replace function tg_tags(arr text[], p_max integer default 8) returns text language sql immutable as $$
    select case when arr is null or cardinality(arr) = 0 then '-'
                else array_to_string(arr[1:p_max], ', ') || case when cardinality(arr) > p_max then ' (+' || (cardinality(arr) - p_max) || ' lagi)' else '' end end;
$$;
create or replace function tg_now() returns text language sql stable as $$
    select to_char(now() at time zone 'Asia/Jakarta', 'DD Mon HH24:MI') || ' WIB';
$$;

-- kirim pesan ke admin (tidak pernah menggagalkan transaksi pemanggil)
create or replace function tg_send(p_event text, p_text text)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare s tg_settings%rowtype;
begin
    select * into s from tg_settings where id = 1;
    if not found or not s.aktif or coalesce(s.bot_token, '') = '' or coalesce(s.chat_id, '') = '' then return; end if;
    if coalesce((s.events ->> p_event)::boolean, true) is not true then return; end if;
    perform net.http_post(
        url := 'https://api.telegram.org/bot' || s.bot_token || '/sendMessage',
        body := jsonb_build_object('chat_id', s.chat_id, 'text', left(p_text, 3900), 'parse_mode', 'HTML', 'disable_web_page_preview', true),
        headers := jsonb_build_object('Content-Type', 'application/json'),
        timeout_milliseconds := 5000);
exception when others then
    null;
end; $$;
revoke all on function tg_send(text, text) from public, anon, authenticated;

-- ---------------- ADMIN ----------------
create or replace function tg_get(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare s tg_settings%rowtype;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    select * into s from tg_settings where id = 1;
    return jsonb_build_object('aktif', s.aktif, 'chat_id', s.chat_id, 'token_set', coalesce(s.bot_token, '') <> '',
        'token_hint', case when coalesce(s.bot_token, '') <> '' then '••••' || right(s.bot_token, 4) end, 'events', s.events,
        'pg_net', to_regnamespace('net') is not null);
end; $$;

create or replace function tg_save(p_pin text, p_token text, p_chat_id text, p_aktif boolean, p_events jsonb)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_token text := nullif(trim(coalesce(p_token, '')), ''); v_chat text := nullif(trim(coalesce(p_chat_id, '')), '');
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    if v_token is not null and v_token !~ '^[0-9]{6,12}:[A-Za-z0-9_-]{30,}$' then raise exception 'Format token bot tidak valid (contoh 123456789:AAE...)'; end if;
    if v_chat is not null and v_chat !~ '^(-?[0-9]{4,20}|@[A-Za-z0-9_]{4,})$' then raise exception 'Chat ID tidak valid (angka, mis. 123456789, atau @namachannel)'; end if;
    update tg_settings set bot_token = coalesce(v_token, bot_token), chat_id = coalesce(v_chat, chat_id), aktif = coalesce(p_aktif, aktif),
           events = case when p_events is not null and jsonb_typeof(p_events) = 'object' then events || p_events else events end, updated_at = now() where id = 1;
    if coalesce(p_aktif, false) and (select coalesce(bot_token, '') = '' or coalesce(chat_id, '') = '' from tg_settings where id = 1) then
        raise exception 'Isi token bot dan Chat ID dulu sebelum mengaktifkan'; end if;
end; $$;

-- kirim pesan tes -> mengembalikan id permintaan; hasilnya dicek dengan tg_check
create or replace function tg_test(p_pin text)
returns bigint language plpgsql security definer set search_path = public, extensions as $$
declare s tg_settings%rowtype; v_id bigint;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    select * into s from tg_settings where id = 1;
    if coalesce(s.bot_token, '') = '' or coalesce(s.chat_id, '') = '' then raise exception 'Simpan token bot dan Chat ID dulu'; end if;
    select net.http_post(
        url := 'https://api.telegram.org/bot' || s.bot_token || '/sendMessage',
        body := jsonb_build_object('chat_id', s.chat_id, 'text', E'✅ <b>Tes notifikasi</b>\nBot Telegram admin terhubung. Order masuk akan dikirim ke sini.\n🕒 ' || tg_now(), 'parse_mode', 'HTML'),
        headers := jsonb_build_object('Content-Type', 'application/json'), timeout_milliseconds := 8000) into v_id;
    return v_id;
end; $$;

create or replace function tg_check(p_pin text, p_req bigint)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare r record;
begin
    if not admin_verify_pin(p_pin) then raise exception 'PIN admin salah'; end if;
    select status_code, content, error_msg, timed_out into r from net._http_response where id = p_req;
    if not found then return jsonb_build_object('pending', true); end if;
    return jsonb_build_object('pending', false, 'status', r.status_code, 'ok', r.status_code = 200,
        'body', left(coalesce(r.content, ''), 400), 'error', r.error_msg, 'timed_out', r.timed_out);
end; $$;

grant execute on function tg_get(text), tg_save(text, text, text, boolean, jsonb), tg_test(text), tg_check(text, bigint) to anon, authenticated;
