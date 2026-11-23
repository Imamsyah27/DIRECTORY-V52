/**
 * AUTO-REFRESH (admin) — memuat ulang data halaman yang sedang dibuka saat ada perubahan
 * (pesanan baru dari pelanggan, perubahan dari admin lain, dll). Butuh sql/koin-usdt-21-autorefresh.sql;
 * migrations/005_hemat_egress.sql membuat versinya per tabel sehingga yang dimuat ulang lebih sedikit.
 * Tidak menimpa pekerjaan: ditunda bila kotak dialog terbuka, sedang mengetik, atau Mode Edit List-Farm aktif.
 *
 * Hemat egress:
 *  - cek versi tiap 20 dtk (dulu 12 dtk), hanya saat tab terlihat; berhenti total saat tab disembunyikan.
 *  - lencana menu = 1 request kecil (admin_badges), bukan 6 daftar penuh tiap menit.
 *  - hanya bagian yang tabelnya berubah yang dimuat ulang.
 */
(function () {
    const INTERVAL = 20000;
    let last = null, pending = new Set(), busyFetch = false, fails = 0, timer = null;

    // tabel -> kelompok lama (untuk database yang belum menjalankan migrasi 005, kunci = nama kelompok)
    const GROUP = {
        orders: "orders", archives: "orders", customer_order_labels: "orders",
        renewal_requests: "requests", bot_orders: "requests", order_requests: "requests", catalog_orders: "requests", preorder_orders: "requests",
        supply_orders: "requests", farm_sales: "requests", hav_sales: "requests", coin_topups: "requests",
        bot_queue: "batch", bot_batch_settings: "batch",
        coin_ledger: "coin",
        farm_batches: "catalog", farm_tokens: "catalog", hav_batches: "catalog", hav_keys: "catalog", supply_batches: "catalog", supply_accounts: "catalog",
        catalog_items: "catalog", catalog_categories: "catalog", preorder_items: "catalog",
        announcements: "announce"
    };

    const safe = fn => { try { const r = typeof fn === "function" ? fn() : null; if (r && r.catch) r.catch(e => console.warn("autorefresh:", e)); } catch (e) { console.warn("autorefresh:", e); } };
    const modalOpen = () => { const m = document.getElementById("modalOverlay"); return !!(m && m.classList.contains("show")); };
    const typing = () => {
        const a = document.activeElement; if (!a) return false;
        if (a.tagName === "TEXTAREA" || a.tagName === "SELECT") return true;
        return a.tagName === "INPUT" && !["checkbox", "radio", "button", "submit", "search"].includes(a.type);
    };
    const blocked = () => modalOpen() || typing() || (typeof produkEditAll !== "undefined" && produkEditAll);
    const page = () => { const b = document.querySelector("#pageNav button.active"); return b ? b.dataset.page : "dashboard"; };

    /* ---------- lencana menu: 1 request ---------- */
    let badgeRpcOk = true;
    const setBadge = (id, n) => { const b = document.getElementById(id); if (b) { b.textContent = n; b.style.display = n ? "inline-block" : "none"; } };
    async function legacyBadges() {          // sebelum migrasi 005: cara lama (daftar penuh per modul)
        safe(typeof boRefreshBadge === "function" && boRefreshBadge); safe(typeof kcRefreshBadges === "function" && kcRefreshBadges);
        safe(typeof kmRefreshBadge === "function" && kmRefreshBadge); safe(typeof poRefreshBadge === "function" && poRefreshBadge);
    }
    async function adminBadges() {
        const pin = sessionStorage.getItem("akun_admin_pin");
        if (!pin || document.visibilityState !== "visible") return;
        if (!badgeRpcOk) return legacyBadges();
        const { data, error } = await supabaseClient.rpc("admin_badges", { p_pin: pin });
        if (error) {
            if (/does not exist|schema cache|Could not find the function/i.test(error.message || "")) { badgeRpcOk = false; return legacyBadges(); }
            return;
        }
        const d = data || {};
        setBadge("boNavBadge", d.bot || 0); setBadge("bkNavBadge", d.bulk || 0); setBadge("boDashBadge", (d.bot || 0) + (d.bulk || 0));
        if ("topup" in d) setBadge("kmNavBadge", d.topup);
        if ("koin" in d) setBadge("coBadge-koin", d.koin);
        if ("voucher" in d) setBadge("coBadge-voucher", d.voucher);
        if ("supply" in d) setBadge("coBadge-supply", d.supply);
        if ("pre" in d) setBadge("coBadge-pre", d.pre);
    }
    window.adminBadges = dedupeAsync(adminBadges);

    /* ---------- tab Order yang sedang dibuka -> tabel yang memengaruhinya ---------- */
    const ORD_TABLES = {
        bot: ["bot_orders"], bulk: ["bot_orders"], batch: ["bot_queue", "bot_batch_settings", "bot_orders"],
        akun: ["coin_topups"], koin: ["catalog_orders"], voucher: ["catalog_orders"], supply: ["supply_orders"],
        pre: ["preorder_orders"], farm: ["farm_sales"], hav: ["hav_sales"]
    };

    function apply(changed) {
        const tb = (...t) => t.some(x => changed.has(x));
        const grp = (...g) => [...changed].some(k => g.includes(GROUP[k] || k));
        const p = page();
        const run = (cond, fn) => { if (cond && typeof fn === "function") safe(fn); };

        // lencana / notifikasi (selalu, tapi hanya bila tabelnya berubah)
        if (tb("bot_orders", "coin_topups", "catalog_orders", "supply_orders", "preorder_orders") || changed.has("requests")) safe(window.adminBadges);
        const ordersChanged = tb("orders") || changed.has("orders");
        if (ordersChanged) safe(typeof resetDailyUTC === "function" && resetDailyUTC);
        const dashReload = p === "dashboard" && (ordersChanged || tb("renewal_requests") || changed.has("requests"));
        if (!dashReload) {                       // loadData sudah memanggil keduanya
            run(tb("renewal_requests") || changed.has("requests"), typeof loadRenewals === "function" ? loadRenewals : null);
            run(ordersChanged, typeof loadUncheckedStats === "function" ? loadUncheckedStats : null);
        }
        run(tb("order_requests") || changed.has("requests"), () => typeof orqRefresh === "function" && orqRefresh(true));

        // halaman yang sedang dibuka
        if (dashReload) run(true, loadData);
        else if (p === "arsip") run(tb("archives") || changed.has("orders"), typeof renderArchivePage === "function" ? () => renderArchivePage() : null);
        else if (p === "akun") run(tb("coin_ledger", "coin_topups", "orders") || grp("coin"), typeof initAkunPelangganPage === "function" ? initAkunPelangganPage : null);
        else if (p === "supply") run(tb("supply_orders", "supply_batches", "supply_accounts", "preorder_items", "preorder_orders") || changed.has("requests") || changed.has("catalog"), typeof initSupplyPage === "function" ? initSupplyPage : null);
        else if (p === "order") {
            const cur = typeof ordCur !== "undefined" ? ordCur : "bot";
            run(tb(...(ORD_TABLES[cur] || [])) || changed.has("requests") || changed.has("coin") || changed.has("catalog"), typeof initOrderPage === "function" ? initOrderPage : null);
        }
        else if (p === "farmsell") run(tb("farm_batches", "farm_tokens", "farm_sales") || changed.has("catalog"), typeof initFarmSellPage === "function" ? initFarmSellPage : null);
        else if (p === "havsell") run(tb("hav_batches", "hav_keys", "hav_sales") || changed.has("catalog"), typeof initHavSellPage === "function" ? initHavSellPage : null);
        else if (p === "kvcatalog") run(tb("catalog_items", "catalog_categories", "catalog_orders") || changed.has("catalog"), typeof initKvPage === "function" ? initKvPage : null);
        else if (p === "statistik") run(tb("orders", "archives") || changed.has("orders"), typeof initGrafikPage === "function" ? initGrafikPage : null);
        else if (p === "pengumuman") run(tb("announcements") || changed.has("announce"), typeof initAnnouncePage === "function" ? initAnnouncePage : null);
        // halaman dengan formulir (Price, Panel, CashFlow, BSL, Modal, Custom Price, ...) sengaja TIDAK dimuat ulang otomatis
    }

    async function tick() {
        if (busyFetch || document.visibilityState !== "visible" || typeof supabaseClient === "undefined") return;
        busyFetch = true;
        try {
            const { data, error } = await supabaseClient.rpc("sync_get");
            if (error || !data) { if (++fails >= 3) stop(); return; }
            fails = 0; window.__syncActive = true;
            if (last === null) { last = data; return; }                       // pembacaan pertama = acuan
            Object.keys(data).forEach(k => { if (data[k] !== last[k]) pending.add(k); });
            last = data;
            if (pending.size && !blocked()) { const s = pending; pending = new Set(); apply(s); }
        } finally { busyFetch = false; }
    }
    function start() { if (!timer) timer = setInterval(tick, INTERVAL); tick(); }
    function stop() { if (timer) clearInterval(timer); timer = null; window.__syncActive = false; }
    document.addEventListener("visibilitychange", () => {
        if (document.visibilityState === "visible") { if (!timer && fails < 3) start(); else tick(); }
        else if (timer) { clearInterval(timer); timer = null; }          // tab disembunyikan: berhenti total
    });
    window.addEventListener("online", tick);
    document.addEventListener("DOMContentLoaded", () => {
        setTimeout(start, 2500);
        setTimeout(() => window.adminBadges(), 1500);                    // lencana awal (dulu 6 request terpisah)
        // cadangan bila auto-refresh tidak aktif (SQL 21 belum dijalankan): lencana tiap 2 menit
        pollVisible(() => { if (!window.__syncActive) window.adminBadges(); }, 120000);
    });
})();
