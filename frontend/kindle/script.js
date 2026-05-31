(function () {
    var postLog = ZenUtils.postLog;
    var dbg     = ZenUtils.postLog;
    var POLL_DELAY = 3500;

    var state = {
        packages:  [],
        busy:      false,
        connected: false,
        pendingOp: null  // { id, action, wasInstalled }
    };

    var el = {
        hint:            document.getElementById("hint"),
        packages:        document.getElementById("packages"),
        packagesHeading: document.getElementById("packagesHeading"),
        pkgSearch:       document.getElementById("pkgSearch"),
        searchClear:     document.getElementById("searchClear")
    };

    window.onerror = function (msg, src, line) {
        var text = "JS ERROR: " + msg + " (" + (src || "?") + ":" + (line || "?") + ")";
        if (el.hint) el.hint.textContent = text;
        postLog(text);
        return false;
    };

    dbg("script loaded");

    function setBusy(flag, message) {
        state.busy = flag;
        if (message && el.hint) {
            el.hint.textContent = message;
        }
    }

    var showModal = ZenUtils.showModal;
    var hideModal = ZenUtils.hideModal;
    var fetchJSON = ZenUtils.fetchJSON;
    var fetchText = ZenUtils.fetchText;

    function loadPackages() {
        return fetchJSON("GET", "/packages?platform=kindle", null).then(function (data) {
            state.packages = Array.isArray(data) ? data : [];
            renderPackages();
        }).catch(function (err) {
            el.hint.textContent = "Failed to load packages.";
            postLog("Error loading packages: " + String(err));
        });
    }

    var _retryCount = 0;
    var MAX_RETRIES = 8;
    var RETRY_DELAY = 3000;

    function detectRuntime() {
        setBusy(true, "Connecting...");
        _retryCount = 0;
        _tryConnect();
    }

    function _tryConnect() {
        dbg("GET /health -> " + ZenUtils.API + " (attempt " + (_retryCount + 1) + ")");
        fetchJSON("GET", "/health", null).then(function (data) {
            _retryCount = 0;
            state.connected = true;
            dbg("ZenPM v" + (data.version || "?"));
            return loadPackages();
        }).then(function () {
            setBusy(false, "");
        }).catch(function (err) {
            if (_retryCount < MAX_RETRIES) {
                _retryCount++;
                dbg("Connecting (" + _retryCount + "/" + MAX_RETRIES + ")...");
                dbg("Retry in " + (RETRY_DELAY / 1000) + "s: " + String(err));
                setTimeout(_tryConnect, RETRY_DELAY);
            } else {
                _retryCount = 0;
                setBusy(false, "");
                el.hint.textContent = "ZenPM daemon not found. Re-run ZenPM.sh to start it.";
                postLog("Daemon unreachable after " + MAX_RETRIES + " retries: " + String(err));
            }
        });
    }

    function refreshPackages() {
        if (state.busy) return;
        if (!state.connected) { detectRuntime(); return; }
        state.busy = true;
        fetchJSON("POST", "/repo/refresh", null).then(function () {
            return loadPackages();
        }).then(function () {
            setBusy(false, "");
        }).catch(function (err) {
            postLog("Refresh failed: " + String(err));
            el.hint.textContent = "Refresh failed.";
            setBusy(false, "");
        });
    }

    function pollAfterOp() {
        var op = state.pendingOp;
        setTimeout(function () {
            loadPackages().then(function () {
                if (!op) { setBusy(false, ""); return; }
                state.pendingOp = null;
                var pkg = null;
                for (var _j = 0; _j < state.packages.length; _j++) {
                    if (state.packages[_j].id === op.id) { pkg = state.packages[_j]; break; }
                }
                var succeeded = pkg && pkg.installed !== op.wasInstalled;
                if (succeeded) {
                    var doneAction = op.action === "install" ? "installed" : "uninstalled";
                    showModal("Done", pkg.name + " " + doneAction + " successfully.");
                } else {
                    showModal("Failed", op.action + " of " + op.id + " did not complete.\n\nCheck the debug log for details.");
                }
                setBusy(false, "");
            });
        }, POLL_DELAY);
    }

    function performPackageAction(pkg) {
        dbg("performPackageAction: " + pkg.id + " connected=" + state.connected + " busy=" + state.busy);
        if (!state.connected) {
            el.hint.textContent = "Not connected to daemon. Try reopening the page.";
            return;
        }
        if (state.busy) {
            el.hint.textContent = "Another operation is in progress. Please wait.";
            return;
        }
        var action = pkg.installed ? "uninstall" : "install";
        dbg("POST /packages/" + pkg.id + "/" + action);
        setBusy(true, (action === "install" ? "Installing " : "Uninstalling ") + pkg.name);
        state.pendingOp = { id: pkg.id, action: action, wasInstalled: pkg.installed };
        var actionLabel = action === "install" ? "Installing" : "Uninstalling";
        showModal(actionLabel, pkg.name + "\n\nDownloading... Please wait.");
        fetchJSON("POST", "/packages/" + encodeURIComponent(pkg.id) + "/" + action, null).then(function () {
            dbg(action + " started for " + pkg.id);
            pollAfterOp();
        }).catch(function (err) {
            postLog("Failed to start " + action + ": " + String(err));
            showModal("Error", "Failed to " + action + " " + pkg.name + ".\n\n" + String(err));
            state.pendingOp = null;
            setBusy(false, "");
        });
    }

    function renderPackages() {
        el.packages.innerHTML = "";
        var query = el.pkgSearch ? el.pkgSearch.value.toLowerCase().trim() : "";
        var visible = query
            ? state.packages.filter(function (p) { return p.name.toLowerCase().indexOf(query) !== -1; })
            : state.packages;
        el.packagesHeading.textContent = "Search (" + visible.length + (query ? "/" + state.packages.length : "") + ")";
        if (!visible.length) {
            el.hint.textContent = query ? "No packages match \"" + query + "\"." : "No packages found. Try Refresh Packages.";
            return;
        }
        el.hint.textContent = "";
        for (var _i = 0; _i < visible.length; _i++) {
            el.packages.appendChild(ZenUtils.renderPackageCard(visible[_i], performPackageAction));
        }
    }

    function setupChrome() {
        ZenUtils.setupPageChrome('ZenPM - Search', refreshPackages);
    }

    function bindEvents() {
        if (el.pkgSearch) {
            el.pkgSearch.addEventListener("input", function () {
                if (el.searchClear) el.searchClear.style.visibility = el.pkgSearch.value ? "visible" : "hidden";
                renderPackages();
            });
        }
        if (el.searchClear) {
            el.searchClear.onclick = function () {
                el.pkgSearch.value = "";
                el.searchClear.style.visibility = "hidden";
                renderPackages();
                el.pkgSearch.focus();
            };
        }
    }

    // Guard so init() fires exactly once.
    var _inited = false;
    function init() {
        if (_inited) return;
        _inited = true;
        dbg("init");
        bindEvents();
        detectRuntime();
    }

    // setupChrome MUST run inside ongo — the messaging bridge isn't live until
    // the WAF framework calls ongo. Sending configureChrome before that silently drops.
    var _k = ZenUtils.getKindle();
    if (_k && _k.appmgr) {
        dbg("ongo registered");
        _k.appmgr.ongo = function () {
            dbg("ongo fired");
            try { setupChrome(); } catch (_e) { dbg("setupChrome threw: " + _e); }
            init();
        };
    } else {
        dbg("no appmgr: " + (typeof _k));
    }

    // Fallback for browser/non-Kindle context: init data loading without chrome.
    // Does NOT call setupChrome — messaging is unavailable outside of ongo.
    setTimeout(init, 0);
})();
