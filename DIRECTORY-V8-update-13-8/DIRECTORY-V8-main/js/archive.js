/**
 * ====================================================================
 * DATA ARSIP — Supabase (tabel `archives`)
 * ====================================================================
 * Alur:
 * - "Simpan ke Arsip": snapshot data pesanan di-insert ke tabel
 *   `archives`, lalu baris asli di tabel `orders` DIHAPUS (pesanan
 *   benar-benar pindah dari daftar aktif ke arsip).
 * - "Pulihkan": baris arsip di-insert kembali ke tabel `orders`
 *   sebagai pesanan aktif baru, lalu baris di `archives` dihapus.
 * - "Hapus Permanen": baris di tabel `archives` dihapus. Baris asli
 *   di `orders` sudah tidak ada (sudah dihapus saat diarsipkan),
 *   sehingga tidak perlu dihapus lagi.
 * ====================================================================
 */

/**
 * Pindahkan satu pesanan ke tabel archives, lalu hapus dari orders.
 * Mengembalikan true jika berhasil.
 */
async function archiveOrder(order) {
    const { error: insertError } = await supabaseClient
        .from("archives")
        .insert([{
            order_id: order.id,
            dashboard: order.dashboard,
            nomor_pesanan: order.nomor_pesanan,
            tagar: order.tagar,
            nomor_whatsapp: order.nomor_whatsapp || "",
            paket_total: order.paket_total,
            paket_terkirim: order.paket_terkirim,
            keterangan: order.keterangan || "",
            created_at: order.created_at || null
        }]);

    if (insertError) {
        console.error(insertError);
        showToast("Gagal menyimpan ke arsip", "danger");
        return false;
    }

    const { error: deleteError } = await supabaseClient
        .from("orders")
        .delete()
        .eq("id", order.id);

    if (deleteError) {
        console.error(deleteError);
        showToast("Tersimpan ke arsip, tapi gagal dihapus dari daftar aktif", "danger");
        return false;
    }

    ssCache.del("arc");
    return true;
}

/**
 * Jumlah total data arsip (untuk badge di nav). Hitungan di server (count head, tanpa data),
 * disimpan 60 detik di sessionStorage karena dipanggil di setiap pemuatan Dashboard.
 */
async function getArchiveCount() {
    const hit = ssCache.get("arc:count"); if (hit !== null) return hit;
    const { count, error } = await supabaseClient
        .from("archives")
        .select("id", { count: "exact", head: true });

    if (error) {
        console.error(error);
        return 0;
    }
    ssCache.set("arc:count", count || 0, 60000);
    return count || 0;
}

/* ---------------- Rendering Halaman Data Arsip ---------------- */
// Dimuat per 50 kartu ("Muat 50 lagi"); pencarian & filter dikerjakan di server (dulu seluruh arsip diunduh tiap kali).
const ARC_COLS = "id,dashboard,nomor_pesanan,tagar,nomor_whatsapp,paket_total,paket_terkirim,created_at,archived_at";
const ARC_PAGE = 50;
const ARC = { list: [], total: 0, key: "", seq: 0 };
const arcSafeQ = q => q.replace(/[,()"'\\%*_]/g, " ").trim();      // karakter khusus filter PostgREST dibuang

async function renderArchivePage(more) {
    const grid = document.getElementById("archiveGrid");
    const emptyState = document.getElementById("archiveEmptyState");
    const searchValue = arcSafeQ(document.getElementById("archiveSearchInput").value.toLowerCase());
    const filterDashboard = document.getElementById("archiveFilterDashboard").value;
    const sortMode = document.getElementById("archiveSort").value;
    const key = [searchValue, filterDashboard, sortMode].join("|");
    const append = more === true && key === ARC.key;
    const from = append ? ARC.list.length : 0;
    const seq = ++ARC.seq;

    emptyState.style.display = "none";

    let query = supabaseClient.from("archives").select(ARC_COLS, { count: "exact" });

    if (filterDashboard !== "ALL") {
        query = query.eq("dashboard", filterDashboard);
    }
    if (searchValue) {
        const p = `%${searchValue}%`;
        query = query.or(`nomor_pesanan.ilike.${p},tagar.ilike.${p},nomor_whatsapp.ilike.${p}`);
    }

    if (sortMode === "oldest") {
        query = query.order("archived_at", { ascending: true });
    } else if (sortMode === "name") {
        query = query.order("nomor_pesanan", { ascending: true });
    } else {
        query = query.order("archived_at", { ascending: false });
    }

    const { data, error, count } = await query.order("id", { ascending: false }).range(from, from + ARC_PAGE - 1);
    if (seq !== ARC.seq) return;          // sudah ada pencarian / filter yang lebih baru

    if (error) {
        console.error(error);
        showToast("Gagal memuat data arsip", "danger");
        return;
    }

    ARC.key = key;
    ARC.list = append ? ARC.list.concat(data || []) : (data || []);
    ARC.total = count || 0;
    const list = ARC.list;

    getArchiveCount().then(n => { document.getElementById("archiveCountBadge").innerText = n; });

    const moreBox = document.getElementById("archiveMore");
    if (moreBox) {
        moreBox.style.display = list.length && ARC.total > list.length ? "flex" : (list.length ? "flex" : "none");
        document.getElementById("archiveMoreInfo").textContent = `Menampilkan ${list.length} dari ${ARC.total} data arsip`;
        document.getElementById("archiveMoreBtn").style.display = ARC.total > list.length ? "" : "none";
    }

    if (list.length === 0) {
        grid.innerHTML = "";
        emptyState.style.display = "flex";
        return;
    }

    grid.innerHTML = list.map(a => {
        const status = getOrderStatus(a.paket_terkirim, a.paket_total);
        const percent = Math.min(100, Math.round((a.paket_terkirim / a.paket_total) * 100));

        return `
        <div class="archive-card">
            <div class="archive-card-top">
                <div class="archive-card-title">${escapeHtml(a.nomor_pesanan)}</div>
                <span class="badge badge-archived">🗂️ Diarsipkan</span>
            </div>

            <div class="archive-card-meta">
                <span class="chip">${escapeHtml(a.dashboard)}</span>
                <span class="chip">${escapeHtml(a.tagar)}</span>
                ${a.nomor_whatsapp ? `<span class="chip">${escapeHtml(a.nomor_whatsapp)}</span>` : ""}
            </div>

            <div class="progress-cell">
                <div class="progress-text">H${a.paket_terkirim}/H${a.paket_total} &middot; ${status.label}</div>
                <div class="progress-track">
                    <div class="progress-fill ${status.barClass}" style="width:${percent}%;"></div>
                </div>
            </div>

            <div class="archive-card-dates">
                <span>📅 Dibuat: ${formatDateHuman(a.created_at)}</span>
                <span>🗂️ Diarsipkan: ${formatDateHuman(a.archived_at)}</span>
            </div>

            <div class="archive-card-actions">
                <button type="button" class="btn btn-outline btn-wrap" onclick="handleRestoreArchive(${a.id})">↩️ Pulihkan</button>
                <button type="button" class="btn btn-danger btn-wrap" onclick="handleDeleteArchive(${a.id}, '${escapeHtml(a.nomor_pesanan)}')">🗑 Hapus Permanen</button>
            </div>
        </div>`;
    }).join("");
}

function handleRestoreArchive(archiveId) {
    openConfirmModal({
        icon: "↩️",
        iconClass: "archive",
        title: "Pulihkan Pesanan?",
        body: "Pesanan ini akan dikembalikan ke daftar <b>Pesanan Aktif</b>.",
        confirmText: "Pulihkan",
        confirmClass: "btn-archive",
        onConfirm: async () => {
            const { data, error } = await supabaseClient
                .from("archives")
                .select("dashboard,nomor_pesanan,tagar,nomor_whatsapp,paket_total,paket_terkirim,keterangan")
                .eq("id", archiveId)
                .single();

            if (error || !data) {
                showToast("Gagal memuat data arsip", "danger");
                return;
            }

            const { error: insertError } = await supabaseClient
                .from("orders")
                .insert([{
                    dashboard: data.dashboard,
                    nomor_pesanan: data.nomor_pesanan,
                    tagar: data.tagar,
                    nomor_whatsapp: data.nomor_whatsapp,
                    paket_total: data.paket_total,
                    paket_terkirim: data.paket_terkirim,
                    last_check_utc: "",
                    keterangan: data.keterangan || ""
                }]);

            if (insertError) {
                console.error(insertError);
                showToast("Gagal memulihkan pesanan", "danger");
                return;
            }

            const { error: deleteError } = await supabaseClient
                .from("archives")
                .delete()
                .eq("id", archiveId);

            if (deleteError) {
                console.error(deleteError);
            }

            ssCache.del("arc");
            renderArchivePage();
            loadData();
            showToast("Pesanan dipulihkan ke daftar aktif", "archive");
        }
    });
}

function handleDeleteArchive(archiveId, nama) {
    openConfirmModal({
        icon: "🗑",
        iconClass: "danger",
        title: "Hapus Permanen?",
        body: `Data <b>${escapeHtml(nama)}</b> akan dihapus permanen dari arsip dan tidak dapat dikembalikan.`,
        confirmText: "Hapus Permanen",
        confirmClass: "btn-danger",
        onConfirm: async () => {
            const { error } = await supabaseClient
                .from("archives")
                .delete()
                .eq("id", archiveId);

            if (error) {
                console.error(error);
                showToast("Gagal menghapus data arsip", "danger");
                return;
            }

            ssCache.del("arc");
            renderArchivePage();
            showToast("Data arsip dihapus permanen", "danger");
        }
    });
}

/* tombol "Muat 50 lagi" */
document.getElementById("archiveMoreBtn").addEventListener("click", () => renderArchivePage(true));

