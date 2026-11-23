/**
 * BATCH TAGAR BOT (admin) — Order -> tab "📋 Batch Tagar". Butuh sql/koin-usdt-23 + 23b + migrations/001_bot_queue_status.sql.
 * Status tagar: pending -> sent -> archived (atau cancelled). Batch HANYA berisi tagar pending (urutan = urutan di-ACC).
 * "Tandai sudah dikirim" = tagar keluar dari batch dan slotnya langsung diisi tagar pending berikutnya (tanpa reload).
 * Tagar terkirim tampil di panel "Sudah dikirim" sampai diarsipkan.
 */
const BB = { size: 50, pending: 0, archived: 0, entries: [], sent: [], orders: [], pkg: "BEM", loaded: false, bound: false, busy: false };
const bbPin = () => sessionStorage.getItem("akun_admin_pin");
const bbNum = n => Number(n || 0).toLocaleString("id-ID");
const bbRp = n => "Rp " + bbNum(n);
const bbPkgs = ["BEM", "SEM", "LEM"];

async function bbRpc(name, params) {
    let res;
    try { res = await supabaseClient.rpc(name, { p_pin: bbPin(), ...params }); }
    catch (e) { res = { data: null, error: { message: (e && e.message) || "Koneksi gagal" } }; }
    if (res.error) {
        const m = res.error.message || ""; console.error(res.error);
        if (m.includes("PIN admin salah")) { sessionStorage.removeItem("akun_admin_pin"); ordRenderGate("batch"); showToast("PIN admin tidak valid, masukkan ulang", "danger"); }
        else if (/does not exist|schema cache|Could not find the function|column .*status/i.test(m)) showToast("Jalankan dulu migrations/001_bot_queue_status.sql di Supabase SQL Editor", "danger");
        else showToast("Gagal: " + (m || "Terjadi kesalahan"), "danger");
    }
    return res;
}

async function bbInit() {
    if (!bbPin()) { ordRenderGate("batch"); return; }
    const { data, error } = await bbRpc("bq_get", {});
    if (error || !data) return;
    if (!Array.isArray(data.sent)) { showToast("Jalankan dulu migrations/001_bot_queue_status.sql di Supabase SQL Editor", "danger"); return; }
    Object.assign(BB, { size: data.size, pending: data.pending, archived: data.archived || 0, entries: data.entries || [], sent: data.sent || [], orders: data.orders || [], loaded: true });
    bbRender();
}
/* batch dihitung dari tagar PENDING saja: posisi ke-1..size = Batch 1, dst. */
const bbBatches = pkg => {
    const list = BB.entries.filter(e => e.dashboard === pkg).sort((a, b) => a.id - b.id), out = [];
    for (let i = 0; i < list.length; i += BB.size) out.push([out.length + 1, list.slice(i, i + BB.size)]);
    return out;
};
const bbTags = list => list.map(e => e.tagar).join("\n");

function bbRender() {
    const pane = document.getElementById("ordPane-batch");
    const all = BB.entries, pkgCount = p => all.filter(e => e.dashboard === p).length;
    const batches = bbBatches(BB.pkg), sentPkg = BB.sent.filter(e => e.dashboard === BB.pkg);
    pane.innerHTML = `
    <section class="panel table-section"><div class="panel-title">📋 Batch Tagar Bot <span class="panel-hint">hanya tagar yang BELUM dikirim, dibagi per batch (urutan = urutan di-ACC)</span></div>
        <div class="bb-stats">
            <div><span>Belum terkirim</span><b>${bbNum(all.length)}</b></div>
            <div><span>Sudah dikirim (belum diarsip)</span><b>${bbNum(BB.sent.length)}</b></div>
            <div><span>Diarsip</span><b>${bbNum(BB.archived)}</b></div>
            <div><span>Menunggu ACC</span><b>${bbNum(BB.pending)} pesanan</b></div>
        </div>
        <div class="bb-tools">
            <label class="bb-size">Isi per batch <input type="number" id="bbSize" min="1" max="5000" value="${BB.size}" inputmode="numeric"> tagar</label>
            <button type="button" class="btn btn-primary" id="bbSaveSize">💾 Simpan</button>
            <span class="bb-sep"></span>
            <button type="button" class="btn btn-success" data-bbcopy="unsent-all" ${all.length ? "" : "disabled"}>📋 Salin semua belum terkirim (${bbNum(all.length)})</button>
            <button type="button" class="btn btn-ghost" id="bbZip" ${all.length ? "" : "disabled"}>⬇ Download ZIP batch</button>
        </div>
        <div class="hold-tabs bb-pkg">${bbPkgs.map(p => `<button type="button" data-bbpkg="${p}" class="${BB.pkg === p ? "on" : ""}">${p} <i>${bbNum(pkgCount(p))}</i></button>`).join("")}</div>
        <div class="bb-pkgtools"><button type="button" class="btn btn-ghost mini" data-bbcopy="unsent-pkg" ${pkgCount(BB.pkg) ? "" : "disabled"}>📋 Salin ${BB.pkg} belum terkirim (${bbNum(pkgCount(BB.pkg))})</button></div>
        <div class="bb-grid">${batches.length ? batches.map(([no, list]) => bbCardHtml(BB.pkg, no, list)).join("") : `<div class="rn-empty" style="display:block;">Tidak ada tagar ${BB.pkg} yang menunggu dikirim. Tagar masuk setelah pesanan di-ACC.</div>`}</div>
    </section>
    <section class="panel table-section"><div class="panel-title">✅ Sudah dikirim ${BB.pkg} <span class="panel-hint">belum diarsip — sudah keluar dari batch</span></div>
        <div class="bb-pkgtools">
            <button type="button" class="btn btn-primary mini" data-bbarchive="pkg" ${sentPkg.length ? "" : "disabled"}>📦 Arsipkan ${BB.pkg} terkirim (${bbNum(sentPkg.length)})</button>
            <button type="button" class="btn btn-ghost mini" data-bbarchive="all" ${BB.sent.length ? "" : "disabled"}>📦 Arsipkan semua paket (${bbNum(BB.sent.length)})</button>
            <button type="button" class="btn btn-ghost mini" data-bbcopy="sent-pkg" ${sentPkg.length ? "" : "disabled"}>📋 Salin</button>
        </div>
        ${sentPkg.length ? `<details data-bbdet="sent:${BB.pkg}" ${bbCardHtml.open && bbCardHtml.open.has("sent:" + BB.pkg) ? "open" : ""}><summary>Lihat ${bbNum(sentPkg.length)} tagar terkirim</summary>
            <ol class="bb-list">${sentPkg.map(e => `<li class="sent"><button type="button" class="copy-chip" data-copy="${escapeHtml(e.tagar)}" title="Klik untuk menyalin">${escapeHtml(e.tagar)}</button> <small>${escapeHtml(e.username)} · ${bbWaktu(e.sent_at)}</small>
                <button type="button" class="btn btn-ghost mini" data-bbundo="${e.id}" title="Kembalikan ke batch (belum dikirim)">↩</button></li>`).join("")}</ol></details>`
            : `<div class="rn-empty" style="display:block;">Belum ada tagar ${BB.pkg} terkirim yang menunggu diarsip.</div>`}
    </section>
    <section class="panel table-section"><div class="panel-title">🧾 Pesanan Aktif <span class="panel-hint">sudah di-ACC & belum selesai dikirim</span></div>
        <div class="table-wrap"><table style="min-width:720px;"><thead><tr><th>Pesanan</th><th>Pelanggan</th><th>Paket</th><th>Tagar</th><th>Terkirim</th><th>Aksi</th></tr></thead><tbody>
        ${BB.orders.map(o => `<tr><td>#${o.id}<br><small>${bbWaktu(o.processed_at)}</small></td><td><b>${escapeHtml(o.username)}</b></td>
            <td>${o.dashboard === "BULK" ? "🧺 BULK" : escapeHtml(o.dashboard) + " Bot"}</td><td>${bbNum(o.n_total)}</td>
            <td>${o.n_sent ? `<span class="badge badge-warn">⏳ ${bbNum(o.n_sent)}/${bbNum(o.n_total)}</span>` : "—"}<br><small>${bbRp(o.total_harga)}</small></td>
            <td>${o.n_sent ? `<small>sebagian sudah dikirim — tidak bisa dibatalkan</small>` : `<button type="button" class="btn btn-danger mini" data-bbcancel="${o.id}">✖ Batalkan & kembalikan koin</button>`}</td></tr>`).join("")}
        </tbody></table></div>
        ${BB.orders.length ? "" : `<div class="rn-empty" style="display:block;">Tidak ada pesanan aktif.</div>`}
    </section>`;
    if (!BB.bound) { BB.bound = true; pane.addEventListener("click", bbOnClick); }
}
const bbWaktu = iso => iso ? new Date(iso).toLocaleString("id-ID", { day: "2-digit", month: "short", hour: "2-digit", minute: "2-digit" }) : "-";

function bbCardHtml(pkg, no, list) {
    const open = bbCardHtml.open && bbCardHtml.open.has(pkg + ":" + no + ":" + list[0].id);
    return `<div class="bb-card">
        <div class="bb-card-head"><b>Batch ${no}</b><span>${bbNum(list.length)} tagar${list.length < BB.size ? ` <small>(isi ${list.length}/${BB.size})</small>` : ""}</span></div>
        <div class="bb-card-state">⏳ Belum dikirim</div>
        <button type="button" class="btn btn-success btn-block bb-mark" data-bbmark="${pkg}:${no}" ${BB.busy ? "disabled" : ""}>✅ Tandai sudah dikirim</button>
        <div class="bb-card-actions"><button type="button" class="btn btn-ghost mini" data-bbcopy="batch" data-pkg="${pkg}" data-no="${no}">📋 Salin batch</button></div>
        <details ${open ? "open" : ""} data-bbdet="${pkg}:${no}:${list[0].id}"><summary>Lihat tagar</summary>
            <ol class="bb-list">${list.map(e => `<li><button type="button" class="copy-chip" data-copy="${escapeHtml(e.tagar)}" title="Klik untuk menyalin">${escapeHtml(e.tagar)}</button> <small>${escapeHtml(e.username)}</small></li>`).join("")}</ol></details>
    </div>`;
}

async function bbCopy(text, label) {
    try { await navigator.clipboard.writeText(text); }
    catch (_) { const ta = document.createElement("textarea"); ta.value = text; ta.style.position = "fixed"; ta.style.opacity = "0"; document.body.appendChild(ta); ta.select(); try { document.execCommand("copy"); } catch (__) {} ta.remove(); }
    showToast(`${label} tersalin`, "success");
}
async function bbOnClick(e) {
    const pk = e.target.closest("[data-bbpkg]"); if (pk) { BB.pkg = pk.dataset.bbpkg; bbRender(); return; }
    const det = e.target.closest("details[data-bbdet]");
    if (det && e.target.closest("summary")) { bbCardHtml.open = bbCardHtml.open || new Set(); const k = det.dataset.bbdet; setTimeout(() => { if (det.open) bbCardHtml.open.add(k); else bbCardHtml.open.delete(k); }, 0); return; }
    const c = e.target.closest("[data-bbcopy]");
    if (c) {
        const k = c.dataset.bbcopy, all = BB.entries;
        if (k === "unsent-all") bbCopy(bbTags(all), `${bbNum(all.length)} tagar`);
        else if (k === "unsent-pkg") { const l = all.filter(x => x.dashboard === BB.pkg); bbCopy(bbTags(l), `${bbNum(l.length)} tagar ${BB.pkg}`); }
        else if (k === "sent-pkg") { const l = BB.sent.filter(x => x.dashboard === BB.pkg); bbCopy(bbTags(l), `${bbNum(l.length)} tagar terkirim ${BB.pkg}`); }
        else if (k === "batch") { const b = bbBatches(c.dataset.pkg).find(([no]) => no === Number(c.dataset.no)); if (b) bbCopy(bbTags(b[1]), `Batch ${c.dataset.no} (${bbNum(b[1].length)} tagar)`); }
        return;
    }
    const mk = e.target.closest("[data-bbmark]"); if (mk) { bbMarkBatch(mk); return; }
    const un = e.target.closest("[data-bbundo]"); if (un) { bbUndo(Number(un.dataset.bbundo), un); return; }
    const ar = e.target.closest("[data-bbarchive]"); if (ar) { bbArchive(ar.dataset.bbarchive === "pkg" ? BB.pkg : null); return; }
    if (e.target.closest("#bbSaveSize")) { bbSaveSize(); return; }
    if (e.target.closest("#bbZip")) { bbDownloadZip(); return; }
    const cx = e.target.closest("[data-bbcancel]"); if (cx) bbCancel(Number(cx.dataset.bbcancel));
}

/* perbarui data lokal setelah tagar berpindah status (tanpa memuat ulang dari server) */
function bbApplyLocal(ids, toSent) {
    const set = new Set(ids), now = new Date().toISOString(), delta = new Map();
    const from = toSent ? BB.entries : BB.sent, moved = from.filter(x => set.has(x.id));
    if (toSent) { BB.entries = BB.entries.filter(x => !set.has(x.id)); BB.sent = moved.map(x => ({ ...x, sent_at: now })).concat(BB.sent); }
    else { BB.sent = BB.sent.filter(x => !set.has(x.id)); BB.entries = BB.entries.concat(moved.map(({ sent_at, ...x }) => x)); }
    moved.forEach(x => delta.set(x.order_id, (delta.get(x.order_id) || 0) + 1));
    BB.orders.forEach(o => { if (delta.has(o.id)) o.n_sent = Math.max(0, o.n_sent + (toSent ? 1 : -1) * delta.get(o.id)); });
    BB.orders = BB.orders.filter(o => o.n_sent < o.n_total);
}
async function bbMarkBatch(btn) {
    if (BB.busy) return;
    const [pkg, no] = btn.dataset.bbmark.split(":"), b = bbBatches(pkg).find(([n]) => n === Number(no));
    if (!b) return;
    const ids = b[1].map(x => x.id);
    BB.busy = true; btn.disabled = true; btn.textContent = "Menyimpan…";
    const { data, error } = await bbRpc("bq_mark", { p_ids: ids, p_sent: true });
    BB.busy = false;
    if (error) { btn.disabled = false; btn.textContent = "✅ Tandai sudah dikirim"; return; }
    if (data !== ids.length) {           // sebagian sudah diubah di tempat lain -> ambil data terbaru
        showToast(`${bbNum(data)} dari ${bbNum(ids.length)} tagar ditandai terkirim (sisanya sudah berubah). Data dimuat ulang.`, "info");
        bbInit(); return;
    }
    bbApplyLocal(ids, true); bbRender();
    showToast(`Batch ${no} ${pkg} (${bbNum(ids.length)} tagar) ditandai terkirim`, "success");
}
async function bbUndo(id, btn) {
    if (BB.busy) return;
    BB.busy = true; btn.disabled = true;
    const { error } = await bbRpc("bq_mark", { p_ids: [id], p_sent: false });
    BB.busy = false;
    if (error) { btn.disabled = false; return; }
    bbApplyLocal([id], false); bbRender();
    showToast("Tagar dikembalikan ke batch (belum dikirim)", "success");
    bbInit();      // pesanan yang tadinya selesai bisa aktif lagi -> segarkan daftar Pesanan Aktif
}
function bbArchive(pkg) {
    const n = BB.sent.filter(x => !pkg || x.dashboard === pkg).length; if (!n) return;
    openConfirmModal({ icon: "📦", iconClass: "info", title: "Arsipkan tagar terkirim?",
        body: `<b>${bbNum(n)} tagar</b> terkirim${pkg ? " " + pkg : " (semua paket)"} diarsipkan. Pesanan yang semua tagarnya sudah terkirim ikut masuk Arsip di menu Bot Order.`,
        confirmText: "Ya, Arsipkan", confirmClass: "btn-primary",
        onConfirm: async () => {
            const { data, error } = await bbRpc("bq_archive_sent", { p_dashboard: pkg });
            if (error) return;
            BB.sent = BB.sent.filter(x => pkg && x.dashboard !== pkg); BB.archived += Number(data) || 0; bbRender();
            showToast(`${bbNum(data)} tagar diarsipkan`, "success");
        } });
}
async function bbSaveSize() {
    const n = parseInt(document.getElementById("bbSize").value, 10);
    if (!n || n < 1 || n > 5000) { showToast("Isi per batch harus 1 – 5000", "danger"); return; }
    const { error } = await bbRpc("bq_set_size", { p_size: n });
    if (!error) { BB.size = n; bbRender(); showToast(`Isi per batch = ${n}. Batch pelanggan ikut menyesuaikan.`, "success"); }
}
function bbCancel(id) {
    const o = BB.orders.find(x => x.id === id); if (!o) return;
    openConfirmModal({ icon: "✖", iconClass: "danger", title: "Batalkan pesanan?",
        body: `Pesanan <b>#${o.id}</b> milik <b>${escapeHtml(o.username)}</b> (${bbNum(o.n_total)} tagar) dibatalkan. Tagarnya keluar dari antrian batch, dicatat ditolak, catatan BSL Profit dihapus, dan koin <b>${bbRp(o.koin || o.total_harga)}</b> dikembalikan ke pelanggan.`,
        confirmText: "Ya, Batalkan", confirmClass: "btn-danger",
        onConfirm: async () => {
            const { error } = await bbRpc("bot_cancel_approved", { p_id: id });
            if (error) return;
            BB.entries = BB.entries.filter(x => x.order_id !== id); BB.orders = BB.orders.filter(x => x.id !== id); bbRender();
            showToast("Pesanan dibatalkan, koin dikembalikan", "success");
        } });
}

/* ---------------- ZIP (tanpa pustaka: format "stored") ---------------- */
function bbCrcTable() { const t = new Uint32Array(256); for (let n = 0; n < 256; n++) { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1; t[n] = c >>> 0; } return t; }
function bbZip(files) {
    const enc = new TextEncoder(), table = bbCrcTable(), parts = [], central = []; let offset = 0;
    const d = new Date(), dosTime = (d.getHours() << 11) | (d.getMinutes() << 5) | (d.getSeconds() >> 1), dosDate = ((d.getFullYear() - 1980) << 9) | ((d.getMonth() + 1) << 5) | d.getDate();
    files.forEach(f => {
        const name = enc.encode(f.name), data = enc.encode(f.text); let crc = 0xFFFFFFFF;
        for (let i = 0; i < data.length; i++) crc = table[(crc ^ data[i]) & 0xFF] ^ (crc >>> 8);
        crc = (crc ^ 0xFFFFFFFF) >>> 0;
        const lh = new DataView(new ArrayBuffer(30));
        lh.setUint32(0, 0x04034b50, true); lh.setUint16(4, 20, true); lh.setUint16(6, 0x0800, true); lh.setUint16(8, 0, true);
        lh.setUint16(10, dosTime, true); lh.setUint16(12, dosDate, true); lh.setUint32(14, crc, true); lh.setUint32(18, data.length, true); lh.setUint32(22, data.length, true);
        lh.setUint16(26, name.length, true); lh.setUint16(28, 0, true);
        parts.push(new Uint8Array(lh.buffer), name, data);
        const ch = new DataView(new ArrayBuffer(46));
        ch.setUint32(0, 0x02014b50, true); ch.setUint16(4, 20, true); ch.setUint16(6, 20, true); ch.setUint16(8, 0x0800, true); ch.setUint16(10, 0, true);
        ch.setUint16(12, dosTime, true); ch.setUint16(14, dosDate, true); ch.setUint32(16, crc, true); ch.setUint32(20, data.length, true); ch.setUint32(24, data.length, true);
        ch.setUint16(28, name.length, true); ch.setUint32(42, offset, true);
        central.push(new Uint8Array(ch.buffer), name);
        offset += 30 + name.length + data.length;
    });
    const cdSize = central.reduce((a, b) => a + b.length, 0), end = new DataView(new ArrayBuffer(22));
    end.setUint32(0, 0x06054b50, true); end.setUint16(8, files.length, true); end.setUint16(10, files.length, true); end.setUint32(12, cdSize, true); end.setUint32(16, offset, true);
    return new Blob([...parts, ...central, new Uint8Array(end.buffer)], { type: "application/zip" });
}
function bbDownloadZip() {
    const files = [];
    bbPkgs.forEach(p => bbBatches(p).forEach(([no, list]) => files.push({ name: `${p}/batch-${String(no).padStart(3, "0")}.txt`, text: bbTags(list) + "\n" })));
    if (!files.length) { showToast("Tidak ada tagar untuk diunduh", "danger"); return; }
    const sum = bbPkgs.map(p => `${p}: ${bbBatches(p).length} batch, ${BB.entries.filter(e => e.dashboard === p).length} tagar belum terkirim`).join("\n");
    files.push({ name: "ringkasan.txt", text: `Isi per batch: ${BB.size}\nDibuat: ${new Date().toLocaleString("id-ID")}\nHanya tagar yang belum terkirim\n${sum}\n` });
    const url = URL.createObjectURL(bbZip(files)), a = document.createElement("a");
    a.href = url; a.download = `batch-tagar-${new Date().toISOString().slice(0, 10)}.zip`; document.body.appendChild(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 2000);
    showToast(`ZIP berisi ${files.length - 1} file batch diunduh`, "success");
}

/* cegah request ganda (klik cepat / auto-refresh bersamaan) */
bbInit = dedupeAsync(bbInit);
