/**
 * PROSES PENGIRIMAN BOT ORDER (admin) — Price -> panel "Proses Pengiriman Bot (1F / 2F)".
 * Butuh migrations/007_bot_proses_1f_2f.sql. Tiap proses: nama, notes/rules (tampil di form pelanggan),
 * aktif/nonaktif, dan harga per tagar untuk BEM / SEM / LEM (harga per kombinasi).
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
function bpkRender() {
    const box = bpkEl("prBotProses"); if (!box) return;
    const num = id => `type="number" min="0" max="100000000" inputmode="numeric" id="${id}"`;
    box.innerHTML = `<div class="bpk-grid">${BPK.rows.map(r => `
        <div class="bpk-card ${r.aktif ? "on" : ""}">
            <div class="bpk-head"><b>${escapeHtml(r.proses)}</b>
                <label class="pr-check"><input type="checkbox" id="bpkAktif_${r.proses}" ${r.aktif ? "checked" : ""}> <span>Aktif (pelanggan bisa memilih)</span></label></div>
            <div class="field"><label for="bpkNama_${r.proses}">Nama tampil</label><input type="text" maxlength="60" id="bpkNama_${r.proses}" value="${escapeHtml(r.nama)}"></div>
            <div class="table-wrap"><table class="pr-table"><thead><tr><th>BEM / tagar (Rp)</th><th>SEM / tagar (Rp)</th><th>LEM / tagar (Rp)</th></tr></thead><tbody><tr>
                <td><input ${num("bpkBem_" + r.proses)} value="${Number(r.harga_bem) || 0}"></td>
                <td><input ${num("bpkSem_" + r.proses)} value="${Number(r.harga_sem) || 0}"></td>
                <td><input ${num("bpkLem_" + r.proses)} value="${Number(r.harga_lem) || 0}"></td></tr></tbody></table></div>
            <small class="muted-note">0 = jenis itu tidak bisa dipesan dengan proses ini.</small>
            <div class="field"><label for="bpkNotes_${r.proses}">Notes / rules untuk pelanggan</label>
                <textarea id="bpkNotes_${r.proses}" rows="4" maxlength="2000" placeholder="Contoh: proses 1x24 jam, pastikan akun tidak sedang dipakai, …">${escapeHtml(r.notes || "")}</textarea></div>
            <button type="button" class="btn btn-primary" data-bpksave="${r.proses}">💾 Simpan ${escapeHtml(r.proses)}</button>
        </div>`).join("")}</div>`;
    if (!BPK.bound) { BPK.bound = true; box.addEventListener("click", e => { const b = e.target.closest("[data-bpksave]"); if (b) bpkSave(b.dataset.bpksave, b); }); }
}
async function bpkSave(pro, btn) {
    if (BPK.busy) return;
    const n = id => { const v = parseInt(bpkEl(id).value, 10); return Number.isFinite(v) && v >= 0 ? v : 0; };
    const payload = { p_pin: bpkPin(), p_proses: pro, p_nama: bpkEl("bpkNama_" + pro).value.trim(), p_notes: bpkEl("bpkNotes_" + pro).value,
        p_aktif: bpkEl("bpkAktif_" + pro).checked, p_harga_bem: n("bpkBem_" + pro), p_harga_sem: n("bpkSem_" + pro), p_harga_lem: n("bpkLem_" + pro) };
    if (!payload.p_nama) { showToast("Nama proses wajib diisi", "danger"); return; }
    BPK.busy = true; btn.disabled = true;
    const { error } = await supabaseClient.rpc("bot_pkg_save", payload);
    BPK.busy = false; btn.disabled = false;
    if (error) {
        if ((error.message || "").includes("PIN admin salah")) { sessionStorage.removeItem("akun_admin_pin"); showToast("PIN admin tidak valid, masukkan ulang", "danger"); return; }
        showToast("Gagal menyimpan: " + (error.message || ""), "danger"); return;
    }
    showToast(`Proses ${pro} disimpan`, "success");
    bpkLoad();
}
