/**
 * PROSES PENGIRIMAN BOT ORDER (admin) — Price -> panel "Proses Pengiriman Bot (1F / 2F)".
 * Butuh migrations/007_bot_proses_1f_2f.sql. Tiap proses: nama, notes/rules (tampil di form pelanggan),
 * aktif/nonaktif proses, dan PER KOMBINASI (1F-BEM, 1F-SEM, 1F-LEM, 2F-BEM, …): harga per tagar + tombol Aktif / Nonaktif
 * (satu-satunya pengaturan ketersediaan Bot Order sejak migrasi 010).
 * Harga custom per pelanggan: menu Custom Price / Harga Pelanggan (item "Bot Order · Proses").
 */
const BPK = { rows: [], loaded: false, bound: false, busy: false };
const bpkPin = () => sessionStorage.getItem("akun_admin_pin");
const bpkEl = id => document.getElementById(id);

async function bpkLoad() {
    const box = bpkEl("prBotProses"); if (!box || !bpkPin()) return;
    const { data, error } = await supabaseClient.rpc("bot_pkg_list", { p_pin: bpkPin() });
    if (error) {
        box.innerHTML = /does not exist|schema cache|Could not find the function/i.test(error.message || "")
            ? `<div class="rn-empty" style="display:block;">Jalankan dulu <b>migrations/007_bot_proses_1f_2f.sql</b>, 008, dan 009 di Supabase SQL Editor.</div>`
            : `<div class="rn-empty" style="display:block;">Gagal memuat: ${escapeHtml(error.message || "")}</div>`;
        return;
    }
    BPK.rows = data || []; BPK.loaded = true; bpkRender();
}
const BPK_DASH = ["BEM", "SEM", "LEM"];
const bpkHM = m => String(Math.floor(m / 60)).padStart(2, "0") + ":" + String(m % 60).padStart(2, "0");
/** status 1 kombinasi untuk ditampilkan admin */
function bpkState(pro) {
    const aktif = bpkEl("bpkAktif_" + pro).checked;
    BPK_DASH.forEach(d => {
        const harga = parseInt(bpkEl(`bpkHarga_${pro}_${d}`).value, 10) || 0, buka = bpkEl(`bpkBuka_${pro}_${d}`).checked, el = bpkEl(`bpkSt_${pro}_${d}`);
        const [txt, cls] = !aktif ? ["⛔ Proses nonaktif", "off"] : !buka ? ["⛔ Nonaktif", "off"] : harga <= 0 ? ["⚠️ Harga 0 — belum bisa dipesan", "warn"] : ["✅ Aktif", "on"];
        el.textContent = txt; el.className = "bpk-st " + cls;
        const tg = bpkEl(`bpkTg_${pro}_${d}`);             // tombol Aktif / Nonaktif
        tg.textContent = buka ? "✅ Aktif" : "⛔ Nonaktif"; tg.className = "btn mini bpk-tg " + (buka ? "btn-success" : "btn-ghost");
        tg.setAttribute("aria-pressed", String(buka));
    });
}
function bpkRender() {
    const box = bpkEl("prBotProses"); if (!box) return;
    box.innerHTML = `<div class="bpk-grid">${BPK.rows.map(r => `
        <div class="bpk-card ${r.aktif ? "on" : ""}">
            <div class="bpk-head"><b>${escapeHtml(r.proses)}</b>
                <label class="pr-check"><input type="checkbox" id="bpkAktif_${r.proses}" data-bpkpro="${r.proses}" ${r.aktif ? "checked" : ""}> <span>Proses aktif</span></label></div>
            <div class="field"><label for="bpkNama_${r.proses}">Nama tampil</label><input type="text" maxlength="60" id="bpkNama_${r.proses}" value="${escapeHtml(r.nama)}"></div>
            <div class="table-wrap"><table class="pr-table bpk-table"><thead><tr><th>Kombinasi</th><th>Harga / tagar (Rp)</th><th>Aktif / Nonaktif</th><th>Status untuk pelanggan</th></tr></thead><tbody>
                ${BPK_DASH.map(d => { const k = d.toLowerCase(); return `<tr>
                    <td><b>${escapeHtml(r.proses)} · ${d}</b></td>
                    <td><input type="number" min="0" max="100000000" inputmode="numeric" id="bpkHarga_${r.proses}_${d}" data-bpkpro="${r.proses}" value="${Number(r["harga_" + k]) || 0}"></td>
                    <td><input type="checkbox" hidden id="bpkBuka_${r.proses}_${d}" data-bpkpro="${r.proses}" ${r["buka_" + k] !== false ? "checked" : ""}>
                        <button type="button" id="bpkTg_${r.proses}_${d}" data-bpktg="${r.proses}_${d}" aria-pressed="false"></button></td>
                    <td><span class="bpk-st" id="bpkSt_${r.proses}_${d}"></span></td></tr>`; }).join("")}
            </tbody></table></div>
            <small class="muted-note">Pelanggan hanya melihat & bisa memesan kombinasi yang <b>Aktif</b> dan harganya lebih dari 0 (dicek juga di server). Tekan <b>Simpan</b> setelah mengubah.</small>
            <div class="field bpk-batas"><label for="bpkBatas_${r.proses}">⏰ Batas kirim hari ini (UTC)</label>
                <div class="bpk-batas-row"><input type="time" step="60" id="bpkBatas_${r.proses}" value="${r.batas_utc != null ? bpkHM(r.batas_utc) : "12:00"}" ${r.batas_utc == null ? "disabled" : ""}>
                    <label class="pr-check"><input type="checkbox" id="bpkTanpa_${r.proses}" data-bpkbatas="${r.proses}" ${r.batas_utc == null ? "checked" : ""}> <span>Tanpa batas</span></label></div>
                <small class="muted-note">Bukan penutup pemesanan: pesanan setelah jam ini tetap diterima (pre order), diberi label <b>📅 Kirim besok</b> (mulai 00:00 UTC, dihitung dari jam server) dan notes pelanggan otomatis berisi saran kirim besok.</small></div>
            <div class="field"><label for="bpkNotes_${r.proses}">Notes / rules untuk pelanggan</label>
                <textarea id="bpkNotes_${r.proses}" rows="4" maxlength="2000" placeholder="Contoh: proses 1x24 jam, pastikan akun tidak sedang dipakai, …">${escapeHtml(r.notes || "")}</textarea></div>
            <button type="button" class="btn btn-primary" data-bpksave="${r.proses}">💾 Simpan ${escapeHtml(r.proses)}</button>
        </div>`).join("")}</div>`;
    BPK.rows.forEach(r => bpkState(r.proses));
    if (!BPK.bound) {
        BPK.bound = true;
        box.addEventListener("click", e => {
            const tb = e.target.closest("[data-bpkbatas]");
            if (tb) { bpkEl("bpkBatas_" + tb.dataset.bpkbatas).disabled = tb.checked; return; }
            const tg = e.target.closest("[data-bpktg]");
            if (tg) { const [pro, d] = tg.dataset.bpktg.split("_"), c = bpkEl(`bpkBuka_${pro}_${d}`); c.checked = !c.checked; bpkState(pro); return; }
            const b = e.target.closest("[data-bpksave]"); if (b) bpkSave(b.dataset.bpksave, b);
        });
        ["input", "change"].forEach(ev => box.addEventListener(ev, e => { const x = e.target.closest("[data-bpkpro]"); if (x) bpkState(x.dataset.bpkpro); }));
    }
}
async function bpkSave(pro, btn) {
    if (BPK.busy) return;
    const n = id => { const v = parseInt(bpkEl(id).value, 10); return Number.isFinite(v) && v >= 0 ? v : 0; };
    const payload = { p_pin: bpkPin(), p_proses: pro, p_nama: bpkEl("bpkNama_" + pro).value.trim(), p_notes: bpkEl("bpkNotes_" + pro).value,
        p_aktif: bpkEl("bpkAktif_" + pro).checked,
        p_harga_bem: n(`bpkHarga_${pro}_BEM`), p_harga_sem: n(`bpkHarga_${pro}_SEM`), p_harga_lem: n(`bpkHarga_${pro}_LEM`),
        p_buka_bem: bpkEl(`bpkBuka_${pro}_BEM`).checked, p_buka_sem: bpkEl(`bpkBuka_${pro}_SEM`).checked, p_buka_lem: bpkEl(`bpkBuka_${pro}_LEM`).checked };
    if (!payload.p_nama) { showToast("Nama proses wajib diisi", "danger"); return; }
    // batas jam (UTC) dalam menit; kosong = tanpa batas
    let batas = null;
    if (!bpkEl("bpkTanpa_" + pro).checked) {
        const m = /^(\d{2}):(\d{2})/.exec(bpkEl("bpkBatas_" + pro).value || "");
        if (!m) { showToast("Isi batas jam (UTC) atau centang Tanpa batas", "danger"); return; }
        batas = Number(m[1]) * 60 + Number(m[2]);
    }
    BPK.busy = true; btn.disabled = true;
    let { error } = await supabaseClient.rpc("bot_pkg_save", payload);
    if (!error) {
        const r2 = await supabaseClient.rpc("bot_pkg_set_batas", { p_pin: bpkPin(), p_proses: pro, p_batas_utc: batas });
        if (r2.error) error = /does not exist|schema cache|Could not find the function/i.test(r2.error.message || "")
            ? { message: "Batas jam belum bisa disimpan — jalankan dulu migrations/011_batas_jam_utc.sql" } : r2.error;
    }
    BPK.busy = false; btn.disabled = false;
    if (error) {
        if ((error.message || "").includes("PIN admin salah")) { sessionStorage.removeItem("akun_admin_pin"); showToast("PIN admin tidak valid, masukkan ulang", "danger"); return; }
        showToast("Gagal menyimpan: " + (error.message || ""), "danger"); return;
    }
    showToast(`Proses ${pro} disimpan`, "success");
    bpkLoad();
}
