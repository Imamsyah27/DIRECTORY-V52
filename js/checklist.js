const _checkBusy = new Set();     // cegah klik ganda pada tombol ✓ (dulu bisa menambah hari 2x)
async function checkDaily(id) {
    if (_checkBusy.has(id)) return;
    _checkBusy.add(id);
    try { await _checkDaily(id); } finally { _checkBusy.delete(id); }
}
async function _checkDaily(id) {
    const todayUTC = getUTCDate();

    const { data, error } = await ordersQuery(cols => supabaseClient
        .from("orders")
        .select(cols)
        .eq("id", id)
        .single());

    if (error || !data) {
        showToast("Gagal memuat data pesanan", "danger");
        return;
    }

    if (data.hold) { showToast("Langganan ini sedang ditunda — aktifkan dulu untuk mencentang", "danger"); return; }
    if (data.paket_terkirim >= data.paket_total) {
        showToast("Paket sudah mencapai limit — simpan ke arsip atau hapus", "danger");
        return;
    }

    if (data.last_check_utc === todayUTC) {
        showToast("Pengiriman hari ini sudah dicentang", "danger");
        return;
    }

    let terkirim = data.paket_terkirim + 1;
    if (terkirim > data.paket_total) terkirim = data.paket_total;

    const paketBaru = `H${terkirim}/H${data.paket_total}`;
    const wa = data.nomor_whatsapp ? `https://wa.me/${data.nomor_whatsapp.replace("+", "")}` : "";
    const keterangan = `${data.dashboard} ${paketBaru} | ${data.tagar}${wa ? " | " + wa : ""}`;

    // pengaman di server: hanya baris yang BELUM dicentang hari ini yang diubah (tab lain / klik ganda tidak menambah hari lagi)
    const { data: upd, error: updErr } = await supabaseClient
        .from("orders")
        .update({
            paket_terkirim: terkirim,
            last_check_utc: todayUTC,
            keterangan: keterangan
        })
        .eq("id", id)
        .or(`last_check_utc.is.null,last_check_utc.neq.${todayUTC}`)
        .select("id");
    if (updErr) { console.error(updErr); showToast("Gagal mencatat pengiriman", "danger"); return; }
    if (!upd || !upd.length) { showToast("Pengiriman hari ini sudah dicentang", "danger"); loadData(); return; }

    // Fast Order (1 hari): setelah dikirim & dicentang langsung masuk arsip
    if (isFastDash(data.dashboard) && terkirim >= data.paket_total) {
        const ok = await moveOrdersToArchive([{ ...data, paket_terkirim: terkirim, keterangan }]);
        showToast(ok ? `⚡ Fast Order terkirim (${paketBaru}) — langsung diarsipkan` : "Terkirim, tapi gagal diarsipkan otomatis", ok ? "archive" : "danger");
        loadData();
        return;
    }

    showToast(`Pengiriman hari ini dicatat (${paketBaru})`, "success");
    loadData();
}

/**
 * Mencentang pengiriman hari ini untuk SEMUA pesanan aktif di dashboard
 * yang sedang dibuka (satu klik). Pesanan yang sudah mencapai limit atau
 * yang sudah dicentang hari ini otomatis dilewati.
 */
async function checkAllDaily() {
    const todayUTC = getUTCDate();

    const { data, error } = await ordersQuery(cols => supabaseClient
        .from("orders")
        .select(cols)
        .eq("dashboard", currentDashboard)
        .limit(5000));

    if (error || !data) {
        showToast("Gagal memuat data pesanan", "danger");
        return;
    }

    // hanya baris yang SEDANG TAMPIL (menghormati search & filter status)
    const visibleIds = new Set(getVisibleOrderIds());
    const searchVal = document.getElementById("searchInput").value.trim();
    const statusVal = document.getElementById("statusFilterSelect").value;
    const filtered = searchVal !== "" || statusVal !== "semua";

    const eligible = data.filter(item =>
        visibleIds.has(item.id) && !item.hold &&
        item.paket_terkirim < item.paket_total && item.last_check_utc !== todayUTC
    );

    if (eligible.length === 0) {
        showToast(filtered ? "Tidak ada pesanan hasil filter yang perlu dicentang hari ini" : "Tidak ada pesanan yang perlu dicentang hari ini", "danger");
        return;
    }

    openConfirmModal({
        icon: "✅",
        iconClass: "success",
        title: "Ceklis Semua Pesanan?",
        body: `Pengiriman hari ini akan dicatat untuk <b>${eligible.length} pesanan</b> di dashboard <b>${currentDashboard}</b> yang belum dicentang${filtered ? ` — <b>hanya yang tampil pada hasil filter${searchVal ? ` “${escapeHtml(searchVal)}”` : ""}</b>, pesanan lain tidak diubah` : ""}. Pesanan yang sudah mencapai limit atau sudah dicentang hari ini akan otomatis dilewati.`,
        confirmText: `Ya, Ceklis ${eligible.length} Pesanan`,
        confirmClass: "btn-success",
        onConfirm: async () => {
            const results = await Promise.allSettled(eligible.map(item => {
                let terkirim = item.paket_terkirim + 1;
                if (terkirim > item.paket_total) terkirim = item.paket_total;

                const paketBaru = `H${terkirim}/H${item.paket_total}`;
                const wa = item.nomor_whatsapp ? `https://wa.me/${item.nomor_whatsapp.replace("+", "")}` : "";
                const keterangan = `${item.dashboard} ${paketBaru} | ${item.tagar}${wa ? " | " + wa : ""}`;

                return supabaseClient
                    .from("orders")
                    .update({
                        paket_terkirim: terkirim,
                        last_check_utc: todayUTC,
                        keterangan: keterangan
                    })
                    .eq("id", item.id);
            }));

            const failed = results.filter(r => r.status === "rejected").length;
            const success = eligible.length - failed;

            // Fast Order yang baru saja tuntas -> otomatis diarsipkan
            const fastDone = eligible.filter((item, i) => results[i].status === "fulfilled" && isFastDash(item.dashboard) && item.paket_terkirim + 1 >= item.paket_total)
                .map(item => ({ ...item, paket_terkirim: item.paket_total }));
            if (fastDone.length) {
                const ok = await moveOrdersToArchive(fastDone);
                if (ok) showToast(`⚡ ${fastDone.length} Fast Order langsung diarsipkan`, "archive");
            }

            if (failed > 0) {
                showToast(`${success} pesanan dicentang, ${failed} gagal`, "danger");
            } else {
                showToast(`${success} pesanan berhasil dicentang hari ini`, "success");
            }

            loadData();
        }
    });
}

/**
 * Kosongkan keterangan pesanan yang belum dicentang hari ini (UTC) — perilaku sama seperti dulu.
 * DULU: tiap 1 menit select * seluruh orders + 1 UPDATE per pesanan, walau keterangannya sudah kosong
 * (tiap UPDATE juga membuat semua web admin & pelanggan memuat ulang data) -> penyebab utama egress berlebih.
 * SEKARANG: cek jumlah dulu (count head: tanpa data, tidak memicu auto-refresh), lalu 1 UPDATE massal
 * HANYA bila memang ada yang perlu dikosongkan. Dipanggil saat buka, tiap 5 menit (tab terlihat), dan saat data orders berubah.
 */
async function resetDailyUTC() {
    const todayUTC = getUTCDate();
    const need = `last_check_utc.is.null,last_check_utc.neq.${todayUTC}`;
    const { count, error } = await supabaseClient.from("orders").select("id", { count: "exact", head: true })
        .or(need).neq("keterangan", "");
    if (error) { console.error(error); return; }
    if (!count) return;
    const { error: updErr } = await supabaseClient.from("orders").update({ keterangan: "" }).or(need).neq("keterangan", "");
    if (updErr) console.error(updErr);
}
resetDailyUTC = dedupeAsync(resetDailyUTC);
pollVisible(resetDailyUTC, 5 * 60000);
