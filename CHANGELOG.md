# CHANGELOG

Perubahan di atas versi asli **V8-update-13-8**. Website tetap vanilla JavaScript (tanpa framework).
Detail teknis per fitur juga ada di `UPDATE-13.md` bagian 19–23.

---

## Ringkasan perubahan

### 1. Perbaikan Batch Tagar Bot + aksi massal Bot Order (admin)
- **Bug lama:** tagar yang sudah ditandai "sudah dikirim" tetap muncul terus di Batch 1. Penyebabnya, nomor batch dihitung dari **semua** tagar pesanan yang belum diarsip, termasuk yang sudah terkirim. Tagar baru keluar dari antrian kalau seluruh pesanannya diarsip.
- Tiap tagar sekarang punya status: `pending → sent → archived`, atau `cancelled`.
- Batch hanya berisi tagar `pending`. Tombol **✅ Tandai sudah dikirim** menyimpan status ke database. Kalau gagal, muncul pesan. Kalau berhasil, tagar langsung hilang dari batch tanpa reload dan slotnya diisi tagar pending berikutnya.
- Panel **Sudah dikirim (belum diarsip)** punya tombol ↩ untuk mengembalikan tagar ke batch dan 📦 **Arsipkan** (per paket atau semua). Pesanan yang semua tagarnya sudah terkirim ikut diarsip.
- Menu **Order → Bot Order** dipisah menjadi sub-tab **BEM Order / SEM Order / LEM Order / Semua**.
- Tombol massal **✅ Terima semua** dan **✅ Tandai semua sudah dikirim** berlaku untuk pesanan yang sedang tampil dan cukup 1 request. Kedua tombol juga ada di Bulk Order.
- Portal pelanggan memakai nomor batch yang sama dengan admin.

### 2. Pencarian tagar di Bot Order (admin)
- Kolom 🔍 Cari menerima tagar, nama pelanggan, atau #nomor pesanan, dengan debounce 400 ms. Hasilnya mencakup semua status & paket; tagar yang cocok ditandai 🔎.
- Kalau tagar sudah dimuat di browser, pencarian tidak membuat request sama sekali. Kalau belum, server memakai `ilike` + limit 50 + kolom seperlunya (`bot_search_tags`). Hasil disimpan per kata kunci.

### 3. Total tagar per hari (portal pelanggan)
- Panel **📊 Total Tagar per Hari** ada di tab Bot Order. Defaultnya 7 hari, dengan pilihan 7 / 14 / 30 hari. Isinya tanggal, jumlah tagar, dan jumlah pesanan; tanggal memakai zona Asia/Jakarta.
- Dihitung di database dengan `group by` tanggal (`cu_bot_daily`). Pelanggan hanya melihat datanya sendiri, berdasarkan sesi login.
- Pesanan yang ditolak atau dibatalkan tidak dihitung. Data tidak ikut polling.

### 4. Batal order oleh pelanggan
- Berlaku untuk order yang **masih menunggu**: Bot/Bulk, Pesanan Baru/Perpanjang, Koin Hayday/Voucher/Katalog, Pre Order, Supply & Stock, dan Top Up Koin.
- Selalu ada dialog konfirmasi. Status menjadi `cancelled` dan data **tidak dihapus**. Sebelumnya, batal Perpanjang, Supply, dan Top Up menghapus baris.
- Koin dan jatah kode referal dikembalikan otomatis.
- Pengecekan ada di database (`cu_cancel_order`): hanya pemilik order dan hanya order berstatus pending.
- Admin melihat filter dan label **🚫 Dibatalkan** di semua daftar order. Order batal tidak bisa di-ACC atau dikirim, dan tagarnya tidak pernah masuk batch.
- Celah lama ditutup: tombol "Sudah dikirim / Batal kirim" di Supply & Stock tidak bisa lagi mengubah order yang sudah ditolak atau dibatalkan.
- Farm dan HAV Token tidak bisa dibatalkan, karena barangnya langsung terkirim saat dibayar.

### 5. Hemat egress database
- **Penyebab utama dulu:** `resetDailyUTC` jalan tiap menit. Setiap kali, ia melakukan `select *` seluruh `orders` dan mengirim 1 UPDATE per pesanan. Setiap UPDATE membuat semua web admin dan pelanggan memuat ulang data.
- **Sekarang:** fungsi itu cukup menghitung (`count`, tanpa data) tiap 5 menit, lalu mengirim 1 UPDATE massal hanya bila perlu.
- **Badge menu admin:** 1 request kecil (`admin_badges`), hanya saat ada perubahan. Dulu 6 daftar penuh tiap menit.
- **Auto-refresh:** admin dicek tiap 20 detik dan pelanggan tiap 30 detik (dulu 12 detik). Keduanya berhenti saat tab disembunyikan. Versi dicatat per tabel dan per pelanggan, dan bagian yang dimuat ulang hanya yang tabelnya berubah.
- Polling lama hanya menjadi cadangan tiap 5–10 menit, dan hanya kalau auto-refresh mati.
- Tidak ada lagi `select("*")`, dan semua daftar diberi batas.
  - Data Arsip dan Riwayat Tagar dimuat per 50.
  - Pencarian arsip dikerjakan di server dengan debounce 400 ms.
- Hitungan memakai `count: "exact", head: true`. Grafik hanya mengambil data 12 bulan.
- Cache sessionStorage dengan masa berlaku:
  - jumlah arsip: 60 detik
  - grafik arsip: 10 menit
  - harga & kontak admin di portal pelanggan: 10 menit
- Cegah request ganda:
  - fungsi load digabung kalau dipanggil bersamaan
  - tombol konfirmasi dan tombol ✓ harian tidak bisa terpicu dua kali (✓ harian juga dicek di server)
  - Dashboard tidak lagi dimuat dua kali saat dibuka
- Perkiraan untuk 1 tab admin di Dashboard tanpa aktivitas, dengan 100 pesanan yang belum dicentang: **±128 request/menit → ±3 request/menit**. Tab yang disembunyikan: 0.

### 6. Pesan dengan koin: dialog Ya / Tidak (portal pelanggan)
- Berlaku untuk Bot Order, Bulk Order, Koin Hayday / Voucher / katalog lain, Pre Order, Supply & Stock, Farm, dan HAV Token.
- **Koin cukup:** layar "Bayar dengan Koin" diganti dialog singkat **Konfirmasi Pesanan** berisi total dan sisa saldo, dengan tombol **Ya, pesan** / **Tidak**. Pesanan tetap menunggu ACC admin, kecuali Farm/HAV yang memang langsung terkirim.
- **Koin kurang:** dialog menyebut kekurangannya dan menyediakan tombol **Top Up Koin**. Pesanan tidak dibuat.
- Tombol di form Bot/Bulk berubah dari "Lanjut ke Pembayaran" menjadi "Pesan".
- **Langganan harian (Pesan Baru / Perpanjang) tidak diubah:** tetap memakai alur aslinya (`payStep`). `new-order.js` identik dengan versi asli.
- Kalau sistem koin belum dipasang, alur lama (QRIS / Binance / DANA / PayPal) tetap berjalan.

### 7. Bot Order per jenis BEM / SEM / LEM + search tagar pelanggan
- **Jenis sudah tersimpan** di `bot_orders.dashboard` (`BEM` / `SEM` / `LEM` / `BULK`, dengan tagar bulk per jenis di `tagar_bem/sem/lem`) dan di `bot_queue.dashboard`. Kolom ini wajib diisi, jadi **tidak ada kolom baru** dan data lama otomatis masuk jenis yang benar.
- **Admin, Bot Order dan Bulk Order:** sub-tab **BEM / SEM / LEM / Semua**. Pesanan Bulk tampil di setiap jenis yang ada tagarnya.
  - Di sub-tab jenis, centang "Dikirim" dan **Tandai semua sudah dikirim** hanya menandai **tagar jenis itu** (`bot_set_dikirim_pkg`). Pesanan berstatus Terkirim setelah semua jenisnya terkirim.
  - **Terima semua** tetap menyetujui pesanan bulk secara utuh.
- **Search admin** dibatasi pada jenis yang dipilih. "Semua" mencari di seluruh jenis.
- **Batch Tagar** sudah dihitung terpisah per jenis. Panel baru **📊 Total Tagar per Hari** menampilkan kolom BEM / SEM / LEM untuk semua pelanggan, dimuat 1 request saat tab dibuka (paling sering sekali per 5 menit).
- **Portal pelanggan:**
  - Filter jenis **Semua / BEM / SEM / LEM** di tab Bot Order.
  - Kolom **cari tagar** dengan debounce 400 ms. Semua tagar milik sendiri diambil **1 kali** saat mulai mencari (`cu_my_bot_tags_all`, 100 pesanan terbaru), lalu disaring di browser. Data diambil ulang hanya kalau pesanan berubah.
  - Panel Total Tagar per Hari punya pilihan jenis yang hanya mengganti tampilan, tanpa request.
  - Teks baru ada di `i18n.js` (id, en, vi, ar) dan `lang-tr.js`.

### 8. Proses pengiriman Bot Order: 1F Request / 2F Request
- **1 pesanan = 1 proses + 1 jenis.** Pelanggan memilih proses lewat dropdown **"Pilih proses pengiriman"** (1F / 2F), lalu memilih **BEM / SEM / LEM**, mengisi tagar, dan membaca **notes/rules** proses itu yang diatur admin. Campuran proses atau jenis dalam satu pesanan dikunci di database (`cu_request_bot_order`).
- **Harga dan buka/tutup per kombinasi** diatur di **Price → Proses Pengiriman Bot (1F / 2F)**. Ada 6 kombinasi (**1F-BEM, 1F-SEM, 1F-LEM, 2F-BEM, 2F-SEM, 2F-LEM**), masing-masing dengan harga per tagar, saklar **Dibuka**, dan status (✅ Dibuka / 🔒 Ditutup / ⚠️ Harga 0).
  - Per proses diatur juga nama, notes/rules, dan aktif/nonaktif.
  - Kombinasi bisa dipesan bila prosesnya aktif, kombinasinya dibuka, harganya lebih dari 0, dan ketersediaan BEM/SEM/LEM di panel "Ketersediaan" (saklar utama) menyala. Semua syarat ini dicek juga di server.
  - **Harga custom per pelanggan** memakai `price_item` (kunci `bot:1F:BEM` …), muncul di menu Custom Price / Harga Pelanggan.
  - Harga **dihitung ulang di server**; harga dari browser tidak dipakai.
- Kolom baru `bot_orders.proses` / `bot_queue.proses`. **Order lama tetap aman** (proses kosong, tampil "tanpa proses"). **Bulk Order tidak berubah.**
- **Pemisahan:**
  - Admin Bot Order: tab **Semua proses / 1F / 2F** di atas tab BEM / SEM / LEM.
  - Batch Tagar dihitung **per kombinasi proses + jenis**, ditambah antrian "Tanpa proses" untuk order lama dan Bulk. File ZIP juga dipisah per proses dan jenis.
  - Search tagar per proses, dan kolom 1F / 2F di Total Tagar per Hari.
  - Portal pelanggan: filter proses, label proses di setiap pesanan, chip batch "BEM · 1F", Daftar Harga per proses, total per hari 1F / 2F.
- Pengaturan proses di browser pelanggan **di-cache 10 menit** dan dihapus otomatis saat admin mengubahnya. Tidak ada polling baru, dan tidak ada `select *`.
- **Harga bot lama dikunci:** panel Price "Harga Bot Order (lama)" dan kolom 🤖 Bot di **Custom Price** / **Harga Pelanggan** diberi label 🔒 dan tidak bisa diedit, karena tidak dipakai lagi untuk pesanan baru. Nilai lama tetap tersimpan sebagai acuan (pratinjau modal BSL Profit, saran harga). Tidak ada benturan harga: pesanan baru hanya memakai harga proses.
- **Modal khusus 1F / 2F:** menu **Modal** → grup "BSL · Bot Order Proses 1F / 2F", 6 isian (1F-BEM … 2F-LEM). Saat pesanan disetujui, BSL Profit memakai modal kombinasi itu. Kalau masih 0 atau kosong, dipakai modal BEM / SEM / LEM Bot lama.

---

## Urutan menjalankan migrasi (`/migrations`)

Jalankan di **Supabase → SQL Editor**, satu file sekali Run, **berurutan**. Semua file aman diulang.
Syaratnya, semua SQL lama di `UPDATE-13.md` (sampai `koin-usdt-24b`) sudah pernah dijalankan.

| # | File | Isi | Wajib setelah |
|---|------|-----|---------------|
| 1 | `migrations/001_bot_queue_status.sql` | Status tagar batch, fungsi batch baru, Terima semua / Tandai semua dikirim | `koin-usdt-23` + `23b` |
| 2 | `migrations/002_bot_search_tags.sql` | Pencarian tagar Bot Order (`bot_search_tags`) | 001 |
| 3 | `migrations/003_cu_bot_daily.sql` | Total tagar per hari (`cu_bot_daily`) + index `bot_orders (customer_id, created_at)` | — |
| 4 | `migrations/004_cu_cancel_order.sql` | Batal order pelanggan (status `cancelled`, `cu_cancel_order`) | 001 |
| 5 | `migrations/005_hemat_egress.sql` | Auto-refresh per tabel & per pelanggan, `admin_badges`, index | `koin-usdt-21` + 001–004 |
| 6 | `migrations/006_bot_per_jenis.sql` | Bot Order per jenis: `bot_list` (+ sisa tagar per jenis), `bot_set_dikirim_pkg`, `bot_search_tags` per jenis, `bot_daily_admin`, `cu_bot_daily` per jenis, `cu_my_bot_tags_all`. Tanpa kolom baru | 001–005 |
| 7 | `migrations/007_bot_proses_1f_2f.sql` | Proses 1F/2F (bagian 1): kolom `proses`, tabel `bot_packages`, harga custom (`price_item` + `pi_catalog`), `bot_pkg_list/save`, `cu_bot_packages`, `cu_request_bot_order` wajib proses | 001–006 |
| 8 | `migrations/008_bot_proses_batch.sql` | Proses 1F/2F (bagian 2): antrian & batch per proses + jenis, `bot_list` / `cu_my_bot_orders` membawa proses, `bot_search_tags` filter proses | 007 |
| 9 | `migrations/009_bot_proses_total_bsl.sql` | Proses 1F/2F (bagian 3): total per hari 1F/2F, BSL Profit (keterangan + **modal khusus 1F/2F per jenis**, `md_all_items` / `md_save`), judul notifikasi Telegram | 008 |

⚠️ **Jangan** menjalankan ulang `sql/koin-usdt-23-bot-batch.sql` / `23b` setelah migrasi 001 dan 004. Kalau dijalankan ulang, fungsi batch kembali ke versi lama dan bug Batch 1 muncul lagi.
Kalau tidak sengaja terjalankan, jalankan ulang 001, lalu 004.

Folder `/migrations` diblokir dari publik oleh `vercel.json`.

---

## Cara menguji

Gunakan akun pelanggan percobaan dengan saldo koin secukupnya. Buka admin dan portal pelanggan di dua jendela browser.
Untuk memeriksa database, gunakan query **read-only** di SQL Editor seperti yang ditulis di bawah.

### A. Batch Tagar
1. Pelanggan: buat Bot Order **BEM** dengan 3 tagar, lalu Bot Order BEM lagi dengan 2 tagar.
2. Admin → Order → Bot Order → sub-tab **BEM Order**. Kedua pesanan tampil. Tab SEM/LEM tidak menampilkannya.
3. Klik **✅ Terima semua** → konfirmasi menunjukkan 2 pesanan / 5 tagar → Ya. Muncul toast "2 pesanan disetujui".
4. Admin → Order → **📋 Batch Tagar**, lalu ubah **Isi per batch** menjadi `2` → Simpan. Kalau antrian BEM tadinya kosong: Batch 1 = 2 tagar, Batch 2 = 2 tagar, Batch 3 = 1 tagar. Kembalikan isi per batch ke nilai semula setelah selesai menguji.
5. Klik **✅ Tandai sudah dikirim** di Batch 1:
   - Batch 1 langsung berisi 2 tagar berikutnya, tanpa reload. Batch 2 sekarang berisi 1 tagar.
   - Tagar tadi muncul di panel **Sudah dikirim**.
   - Cek di database: `select tagar, status from bot_queue order by id desc limit 5;` → 2 baris `sent`, sisanya `pending`.
6. Klik ↩ pada satu tagar di panel Sudah dikirim. Tagar itu kembali ke posisi awalnya di batch.
7. Tandai semua batch terkirim, lalu klik **📦 Arsipkan BEM terkirim**:
   - Panel Sudah dikirim kosong.
   - Kedua pesanan pindah ke filter **🗂️ Arsip** di Bot Order.
   - Cek: `select status, count(*) from bot_queue group by status;` → tagar tadi `archived`.
8. **Pesan bila gagal:** buka tab Batch Tagar di dua tab admin. Di tab A tandai Batch 1. Di tab B tandai Batch 1 yang sama (data lama) → muncul toast merah "Tagar ini sudah berubah status…".
9. **Tandai semua sudah dikirim:** buat dan ACC 2 pesanan baru → filter **📮 Perlu Dikirim** → **✅ Tandai semua sudah dikirim**. Pesanan berstatus Terkirim dan tagarnya hilang dari Batch Tagar.
10. Pelanggan → tab Bot Order: chip batch menunjukkan nomor batch yang sama dengan admin. Tagar terkirim tampil sebagai `BEM: n tagar ✅`.

### B. Pencarian tagar (Bot Order admin)
1. Admin → Order → Bot Order. Buka DevTools → Network, filter `rpc`.
2. Ketik sebagian tagar dari pesanan yang daftar tagarnya **belum** dibuka:
   - Hasil muncul ±400 ms setelah berhenti mengetik.
   - Hanya ada **1** request `bot_search_tags`, bukan satu per huruf.
   - Tagar yang cocok ditandai 🔎.
3. Hapus lalu ketik ulang kata yang sama → **tidak ada** request baru (hasil dari cache).
4. Buka daftar tagar (▸ n tagar) semua pesanan di tab itu, lalu cari tagar baru → **tidak ada** request (filter di browser).
5. Cari nama pelanggan atau `#12` (nomor pesanan) → pesanan yang sesuai tampil.
6. Ketik `%` atau `_` → tidak dianggap wildcard; hasilnya hanya tagar yang benar-benar mengandung karakter itu.
7. Selama mencari, tombol massal tersembunyi. Klik filter status atau sub-tab paket → pencarian dikosongkan.

### C. Total tagar per hari (portal pelanggan)
1. Pelanggan → tab **🤖 Bot Order** → panel **📊 Total Tagar per Hari** tampil dengan 7 baris (hari ini paling atas). Hari tanpa pesanan tampil samar.
2. Buat Bot Order 4 tagar → angka hari ini bertambah 4 dan "1 pesanan" bertambah, tanpa reload halaman.
3. Klik **14 hari** / **30 hari** → jumlah baris berubah. Cek di Network: response hanya berisi 1 baris per hari, bukan daftar pesanan.
4. Admin menolak pesanan itu → setelah ±30 detik angka hari ini berkurang lagi.
5. **Hanya milik sendiri:** login sebagai pelanggan lain → angkanya berbeda. Cek: `select cu_bot_daily('<token-acak>'::uuid, 7);` → error "Sesi login tidak valid".
6. Ganti bahasa (EN/VI/AR/TR) → teks panel ikut berganti.

### D. Batal order (pelanggan)
Lakukan untuk setiap jenis: **Bot Order, Bulk Order, Pesanan Baru, Perpanjang, Koin Hayday / Voucher, Pre Order, Supply & Stock, Top Up Koin**.
1. Catat saldo koin. Buat order (status Menunggu) → saldo berkurang.
2. Klik **✖ Batalkan** → dialog konfirmasi muncul dan menyebut jumlah koin yang kembali.
   - Klik **Tidak** → tidak terjadi apa-apa.
   - Klik **Ya, batalkan** → status **🚫 Dibatalkan** dan saldo kembali seperti semula.
3. Cek data **tidak terhapus**: `select id, status, cancelled_at from bot_orders order by id desc limit 3;` (ganti tabel: `renewal_requests`, `catalog_orders`, `preorder_orders`, `supply_orders`, `coin_topups`).
4. Pesanan Baru/Perpanjang dengan kode referal → setelah dibatalkan, kode yang sama bisa dipakai lagi.
5. Admin → daftar terkait → filter **🚫 Dibatalkan** menampilkan order tersebut. Yang tersedia hanya tombol Hapus atau Arsipkan; tidak ada Setujui atau Kirim.
6. **Tidak bisa membatalkan order yang sudah diproses:** admin meng-ACC order dulu → tombol Batalkan hilang di pelanggan. Kalau tombol dari tampilan lama tetap diklik, muncul pesan "sudah diproses".
7. **Hanya milik sendiri:** coba batalkan order milik pelanggan lain lewat konsol browser: `cuRpc("cu_cancel_order", { p_kind: "bot", p_id: <id milik orang lain> })` → error "Pesanan tidak ditemukan atau sudah diproses".
8. **Tidak masuk batch:** Bot Order yang dibatalkan tidak muncul di Batch Tagar. Cek: `select count(*) from bot_queue q join bot_orders o on o.id = q.order_id where o.status = 'cancelled' and q.status = 'pending';` → `0`.
9. **Mode lihat admin** (👁 Tampilan Customer): tombol Batalkan tidak tampil.
10. Supply & Stock → Order Masuk: order berstatus Ditolak / Dibatalkan tidak punya tombol ✅ / ↩.

### E. Egress / jumlah request
1. **Request per menit (admin):** buka Dashboard, masukkan PIN, buka DevTools → Network dengan filter `supabase.co`, kosongkan daftar, lalu diamkan 1 menit tanpa menyentuh apa pun → kira-kira **3 request** (`sync_get`), ditambah sesekali `orders?select=id` (HEAD). Dulu puluhan sampai ratusan.
2. **Tab disembunyikan:** pindah ke tab browser lain selama 1 menit, lalu kembali → tidak ada request selama tersembunyi.
3. **Tidak ada `select=*`:** di Network, cari `select=*` → tidak ada hasil. Request `orders` hanya membawa daftar kolom.
4. **Reset harian tanpa banjir UPDATE:** diamkan 5 menit → paling banyak 1 request HEAD `orders` dan 1 PATCH massal (hanya bila ada keterangan yang perlu dikosongkan). Tidak ada PATCH per pesanan.
5. **Badge menu:** buat order baru dari pelanggan → dalam ±20 detik badge Order bertambah lewat **1** request `admin_badges`.
6. **Per pelanggan:** buka portal pelanggan A dan B. Pelanggan B membuat order → di jendela A hanya ada `cu_sync_get` tiap 30 detik, tanpa memuat ulang daftar pesanan.
7. **Arsip:** halaman Data Arsip menampilkan 50 kartu + "Menampilkan 50 dari N" + tombol **Muat 50 lagi**. Mengetik di kolom cari → 1 request setelah berhenti mengetik.
8. **Klik ganda:** klik ✓ harian dua kali dengan cepat → hari bertambah **1** saja. Klik ganda tombol konfirmasi → aksi berjalan sekali.
9. **Supabase Dashboard → Reports → API / Database:** bandingkan jumlah request dan egress harian sebelum dan sesudah deploy.

### F. Pesan dengan koin (dialog Ya / Tidak)
1. Pelanggan dengan saldo cukup → Bot Order → isi tagar → **Pesan** → muncul dialog **Konfirmasi Pesanan** berisi total dan sisa saldo, tanpa layar pembayaran.
2. **Tidak** → kembali ke form dan tidak ada yang terjadi. **Ya, pesan** → pesanan berstatus Menunggu konfirmasi dan saldo berkurang.
3. Ulangi untuk Bulk Order, Koin Hayday / Voucher, Pre Order, Supply & Stock, Farm, dan HAV Token.
4. Saldo kurang → dialog **Koin tidak cukup** menyebut kekurangannya → **Top Up Koin** membuka form top up. Tidak ada pesanan baru di admin.
5. **Langganan harian tidak berubah:** Pesan Langganan Baru dan Perpanjang tetap menampilkan layar "Bayar dengan Koin" seperti aslinya.

### G. Bot Order per jenis
1. Buat 1 Bot Order SEM dan 1 Bulk Order (BEM 3 tagar + SEM 2 tagar), lalu admin **Terima semua**.
2. Admin → Bot Order → **SEM**: hanya pesanan SEM. Bulk Order → **SEM**: pesanan bulk tampil dengan chip "SEM 2 tagar". Bulk Order → **LEM**: pesanan itu tidak tampil.
3. Bulk Order → **BEM** → filter Perlu Dikirim → **Tandai semua sudah dikirim**:
   - Di tab BEM pesanan pindah ke Terkirim, di tab SEM masih Perlu dikirim.
   - Cek: `select dashboard, status, count(*) from bot_queue where order_id = <id> group by 1, 2;` → BEM `sent`, SEM `pending`.
4. Tandai juga SEM → pesanan berstatus Terkirim penuh (`dikirim_at` terisi).
5. Batch Tagar: tab BEM / SEM / LEM masing-masing berisi tagar jenisnya saja. Panel **Total Tagar per Hari** menunjukkan BEM 3 dan SEM 2 + 2 untuk hari ini. Ganti 7 / 14 / 30 hari → 1 request per klik.
6. Search admin di sub-tab SEM: tagar BEM dari pesanan bulk tidak ikut ditemukan. Di "Semua" ditemukan.
7. Pelanggan → Bot Order → filter **SEM** → pesanan SEM + bulk (chip "SEM: 2 tagar"). Panel Total per Hari → **SEM** → angka berubah tanpa request baru.

### H. Search tagar pelanggan
1. Pelanggan → Bot Order → DevTools Network (filter `rpc`) → ketik sebagian tagar dari pesanan yang daftarnya belum dibuka → setelah ±400 ms ada **1** request `cu_my_bot_tags_all` dan hasilnya tampil dengan 🔎.
2. Ketik kata lain → **tidak ada** request baru.
3. Pilih jenis BEM / SEM / LEM → hasil menyesuaikan tanpa request.
4. Buka daftar tagar (▸ n tagar) pesanan yang sudah dimuat lewat pencarian → tidak ada request `cu_bot_tags`.
5. Buat pesanan baru, lalu cari lagi → daftar tagar diambil ulang 1 kali.
6. Login sebagai pelanggan lain → tagar pelanggan pertama tidak pernah muncul.
7. Ganti bahasa ID / EN / VI / AR / TR → placeholder dan teks hasil ikut berganti.

### I. Proses pengiriman 1F / 2F Request
1. Jalankan migrasi **007 → 008 → 009**. Admin → **Price** → panel **Proses Pengiriman Bot (1F / 2F)**:
   - 1F: harga BEM 1000, SEM 2000, LEM 0, notes "Rule A", centang Aktif → Simpan. Status: 1F-BEM ✅, 1F-SEM ✅, 1F-LEM ⚠️ Harga 0.
   - 2F: biarkan nonaktif.
   - Mencentang Aktif tanpa harga apa pun → muncul pesan "Isi minimal satu harga".
2. Pelanggan → Bot Order → **Pesan Bot Order**:
   - Dropdown "Pilih proses pengiriman" hanya berisi **1F Request**. Tombol Pesan dan tombol jenis nonaktif sebelum proses dipilih.
   - Pilih 1F → "Rule A" tampil; BEM Rp 1.000, SEM Rp 2.000, **LEM nonaktif**.
   - Pilih BEM, isi 2 tagar → total Rp 2.000 → **Pesan** → dialog Ya / Tidak → **Ya** → saldo berkurang 2.000 dan pesanan tampil dengan label "📨 1F Request".
   - Cek: `select id, dashboard, proses, harga_tagar, total_harga from bot_orders order by id desc limit 1;` → `BEM | 1F | 1000 | 2000`.
3. **Buka / tutup per kombinasi:** lepas centang **Dibuka** pada 1F-SEM → Simpan → status 🔒 Ditutup. Dalam ±30 detik, tombol SEM di form pelanggan (proses 1F) menjadi "tidak tersedia". Pesan lewat console dengan `p_dashboard: "SEM", p_proses: "1F"` → ditolak "Pemesanan proses dan jenis ini sedang ditutup". 2F-SEM tidak terpengaruh.
4. **Harga dikunci di server:** di console browser jalankan `cuRpc("cu_request_bot_order", { p_dashboard: "LEM", p_proses: "1F", p_tagar_list: ["#x"] })` → ditolak "Harga Bot Order belum diatur admin". Tanpa `p_proses` → ditolak "Pilih proses pengiriman".
5. **Harga custom:** Admin → Custom Price → pilih pelanggan → grup "Bot Order · Proses" → isi "1F Request · BEM" = 700 → Simpan. Dalam ±10 menit (atau setelah muat ulang), harga BEM di form pelanggan itu menjadi Rp 700, tanpa coretan. Harga Pelanggan tampil dengan coretan.
6. **Admin Bot Order:** tab **1F** hanya menampilkan pesanan 1F. Setujui → Batch Tagar → **1F Request → BEM** → tagar tampil di "1F · BEM · Batch 1". Order lama tetap ada di "Tanpa proses".
7. **Modal 1F / 2F:** menu Modal → isi "1F Request · BEM" = 400 → setujui pesanan 1F-BEM 2 tagar (harga 1000) → BSL Profit mencatat modal 800, profit 1.200. Pesanan 2F-BEM (modal proses kosong) memakai modal "BEM Bot" lama.
8. **Harga lama terkunci:** Price → "Harga Bot Order (lama) 🔒", serta kolom 🤖 Bot di Custom Price / Harga Pelanggan, tampil abu-abu dan tidak bisa diubah.
9. Total per hari: kolom 1F / 2F di admin, dan pilihan 1F / 2F di panel pelanggan.
10. **Bulk Order dan langganan harian** tetap seperti sebelumnya. Login pelanggan dan cancel order tetap berfungsi.

---

## Catatan
- Web versi baru tetap berjalan bila migrasi belum dijalankan. Fitur yang butuh SQL menampilkan pesan "Jalankan dulu migrations/…", dan auto-refresh memakai cara lama.
- Status ini belum diuji di browser sungguhan. Lakukan pengujian di atas sebelum dipakai pelanggan.
