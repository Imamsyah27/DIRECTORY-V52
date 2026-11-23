-- Cek apakah mode "Tampilan Customer" sudah terpasang benar di database.
-- Jalankan di Supabase SQL Editor. HARUS keluar 4 baris dan semua kolom "siap" = true.
-- Jika ada yang false / kurang dari 4 baris: jalankan ulang sql/admin-view.sql (paling terakhir).
select p.proname,
       case p.proname
            when 'portal_session_acc' then pg_get_functiondef(p.oid) ilike '%admin_view_tokens%'
            when 'admin_view_open'    then true
            else pg_get_functiondef(p.oid) ilike '%portal_session_acc%'
       end as siap
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('portal_session_acc', 'get_my_orders', 'get_my_profile', 'admin_view_open')
order by p.proname;
