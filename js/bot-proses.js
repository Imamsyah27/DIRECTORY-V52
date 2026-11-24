/**
 * PROSES PENGIRIMAN BOT ORDER (admin) — Price -> panel "Proses Pengiriman Bot (1F / 2F)".
 * Butuh migrations/007_bot_proses_1f_2f.sql. Tiap proses: nama, notes/rules (tampil di form pelanggan),
 * aktif/nonaktif proses, dan PER KOMBINASI (1F-BEM, 1F-SEM, 1F-LEM, 2F-BEM, …): harga per tagar + saklar Dibuka / Ditutup.
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
/** status 1 kombinasi untuk ditampilkan admin */
function bpkState(pro) {
    const aktif = bpkEl("bpkAktif_" + pro).checked;
    BPK_DASH.forEach(d => {
        const harga = parseInt(bpkEl(`bpkHarga_${pro}_${d}`).value, 10) || 0, buka = bpkEl(`bpkBuka_${pro}_${d}`).checked, el = bpkEl(`bpkSt_${pro}_${d}`);
        const [txt, cls] = !aktif ? ["⛔ Proses nonaktif", "off"] : !buka ? ["🔒 Ditutup", "off"] : harga <= 0 ? ["⚠️ Harga 0 — belum bisa dipesan", "warn"] : ["✅ Dibuka", "on"];
        el.textContent = txt; el.className = "bpk-st " + cls;
    });
}
function bpkRender() {
    const box = bpkEl("prBotProses"); if (!box) return;
    box.innerHTML = `<div class="bpk-grid">${BPK.rows.map(r => `
        <div class="bpk-card ${r.aktif ? "on" : ""}">
            <div class="bpk-head"><b>${escapeHtml(r.proses)}</b>
                <label class="pr-check"><input type="checkbox" id="bpkAktif_${r.proses}" data-bpkpro="${r.proses}" ${r.aktif ? "checked" : ""}> <span>Proses aktif</span></label></div>
            <div class="field"><label for="bpkNama_${r.proses}">Nama tampil</label><input type="text" maxlength="60" id="bpkNama_${r.proses}" value="${escapeHtml(r.nama)}"></div>
            <div class="table-wrap"><table class="pr-table bpk-table"><thead><tr><th>Kombinasi</th><th>Harga / tagar (Rp)</th><th>Pemesanan</th><th>Status</th></tr></thead><tbody>
                ${BPK_DASH.map(d => { const k = d.toLowerCase(); return `<tr>
                    <td><b>${escapeHtml(r.proses)} · ${d}</b></td>
                    <td><input type="number" min="0" max="100000000" inputmode="numeric" id="bpkHarga_${r.proses}_${d}" data-bpkpro="${r.proses}" value="${Number(r["harga_" + k]) || 0}"></td>
                    <td><label class="pr-check"><input type="checkbox" id="bpkBuka_${r.proses}_${d}" data-bpkpro="${r.proses}" ${r["buka_" + k] !== false ? "checked" : ""}> <span>Dibuka</span></label></td>
                    <td><span class="bpk-st" id="bpkSt_${r.proses}_${d}"></span></td></tr>`; }).join("")}
            </tbody></table></div>
            <small class="muted-note">Pelanggan hanya bisa memesan kombinasi yang <b>Dibuka</b> dan harganya lebih dari 0. Ketersediaan BEM / SEM / LEM di panel "Ketersediaan" tetap berlaku sebagai saklar utama.</small>
            <div class="field"><label for="bpkNotes_${r.proses}">Notes / rules untuk pelanggan</label>
                <textarea id="bpkNotes_${r.proses}" rows="4" maxlength="2000" placeholder="Contoh: proses 1x24 jam, pastikan akun tidak sedang dipakai, …">${escapeHtml(r.notes || "")}</textarea></div>
            <button type="button" class="btn btn-primary" data-bpksave="${r.proses}">💾 Simpan ${escapeHtml(r.proses)}</button>
        </div>`).join("")}</div>`;
    BPK.rows.forEach(r => bpkState(r.proses));
    if (!BPK.bound) {
        BPK.bound = true;
        box.addEventListener("click", e => { const b = e.target.closest("[data-bpksave]"); if (b) bpkSave(b.dataset.bpksave, b); });
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
