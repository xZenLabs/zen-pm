(function () {
    var postLog = ZenUtils.postLog;
    var dbg     = ZenUtils.postLog;
    var POLL_DELAY = 3500;

    var state = {
        packages:  [],
        busy:      false,
        connected: false,
        pendingOp: null
    };

    var el = {
        hint:               document.getElementById("hint"),
        installedList:      document.getElementById("installedList"),
        installedHeading:   document.getElementById("installedHeading"),
        installedSearch:    document.getElementById("installedSearch"),
        installedSearchClear: document.getElementById("installedSearchClear")
    };

    window.onerror = function (msg, src, line) {
        var text = "JS ERROR: " + msg + " (" + (src || "?") + ":" + (line || "?") + ")";
        if (el.hint) el.hint.textContent = text;
        postLog(text);
        return false;
    };

    dbg("[installed] script loaded");

    function setBusy(flag, message) {
        state.busy = flag;
        if (message && el.hint) {
            el.hint.textContent = message;
        }
    }

    var showModal = ZenUtils.showModal;
    var hideModal = ZenUtils.hideModal;
    var fetchJSON = ZenUtils.fetchJSON;
    var setupCardScroll = ZenUtils.setupCardScroll;

    var cardScroll = null;

    function loadPackages() {
        return fetchJSON("GET", "/packages?platform=kindle", null).then(function (data) {
            state.packages = Array.isArray(data) ? data : [];
            renderInstalled();
        }).catch(function (err) {
            el.hint.textContent = "Failed to load packages.";
            postLog("[installed] Error loading packages: " + String(err));
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
        dbg("[installed] GET /health (attempt " + (_retryCount + 1) + ")");
        fetchJSON("GET", "/health", null).then(function (data) {
            _retryCount = 0;
            state.connected = true;
            dbg("[installed] ZenPM v" + (data.version || "?"));
            return loadPackages();
        }).then(function () {
            setBusy(false, "");
        }).catch(function (err) {
            if (_retryCount < MAX_RETRIES) {
                _retryCount++;
                setTimeout(_tryConnect, RETRY_DELAY);
            } else {
                _retryCount = 0;
                setBusy(false, "");
                el.hint.textContent = "ZenPM daemon not found. Re-run ZenPM.sh to start it.";
                postLog("[installed] Daemon unreachable after " + MAX_RETRIES + " retries");
            }
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
        dbg("[installed] performPackageAction: " + pkg.id + " connected=" + state.connected + " busy=" + state.busy);
        if (!state.connected) {
            el.hint.textContent = "Not connected to daemon. Try reopening the page.";
            return;
        }
        if (state.busy) {
            el.hint.textContent = "Another operation is in progress. Please wait.";
            return;
        }
        var action = pkg.installed ? "uninstall" : "install";
        dbg("[installed] POST /packages/" + pkg.id + "/" + action);
        setBusy(true, (action === "install" ? "Installing " : "Uninstalling ") + pkg.name);
        state.pendingOp = { id: pkg.id, action: action, wasInstalled: pkg.installed };
        var actionLabel = action === "install" ? "Installing" : "Uninstalling";
        showModal(actionLabel, pkg.name + "\n\nDownloading... Please wait.");
        fetchJSON("POST", "/packages/" + encodeURIComponent(pkg.id) + "/" + action, null).then(function () {
            dbg("[installed] " + action + " started for " + pkg.id);
            pollAfterOp();
        }).catch(function (err) {
            postLog("[installed] Failed to start " + action + ": " + String(err));
            showModal("Error", "Failed to " + action + " " + pkg.name + ".\n\n" + String(err));
            state.pendingOp = null;
            setBusy(false, "");
        });
    }

    function renderInstalled() {
        el.installedList.innerHTML = "";
        var query = el.installedSearch ? el.installedSearch.value.toLowerCase().trim() : "";
        var installed = state.packages.filter(function (p) { return p.installed; });
        var visible = query
            ? installed.filter(function (p) { return p.name.toLowerCase().indexOf(query) !== -1; })
            : installed;
        el.installedHeading.textContent = "Installed (" + visible.length + (query ? "/" + installed.length : "") + ")";
        if (!visible.length) {
            el.hint.textContent = query ? "No installed packages match \"" + query + "\"." : "No packages installed. Browse Search to find packages.";
            if (cardScroll) cardScroll.rebuild();
            return;
        }
        el.hint.textContent = "";
        for (var _i = 0; _i < visible.length; _i++) {
            el.installedList.appendChild(ZenUtils.renderPackageCard(visible[_i], performPackageAction));
        }
        if (cardScroll) cardScroll.rebuild();
    }

    function setupChrome() {
        ZenUtils.setupPageChrome('ZenPM - Installed', loadPackages);
    }

    var _chromeSetup = false;
    function trySetupChrome() {
        if (_chromeSetup) return;
        _chromeSetup = true;
        try { setupChrome(); } catch (_e) { postLog("[installed] setupChrome threw: " + _e); }
    }

    function bindEvents() {
        if (el.installedSearch) {
            el.installedSearch.addEventListener("input", function () {
                if (el.installedSearchClear) el.installedSearchClear.style.visibility = el.installedSearch.value ? "visible" : "hidden";
                renderInstalled();
            });
        }
        if (el.installedSearchClear) {
            el.installedSearchClear.onclick = function () {
                el.installedSearch.value = "";
                el.installedSearchClear.style.visibility = "hidden";
                renderInstalled();
                el.installedSearch.focus();
            };
        }
    }

    var _inited = false;
    function init() {
        if (_inited) return;
        _inited = true;
        postLog("[installed] init");
        bindEvents();
        cardScroll = setupCardScroll(".package-scroll", "package-card");
        detectRuntime();
    }

    var _k = ZenUtils.getKindle();
    if (_k && _k.appmgr) {
        postLog("[installed] ongo registered");
        _k.appmgr.ongo = function () {
            postLog("[installed] ongo fired");
            trySetupChrome();
            init();
        };
    } else {
        postLog("[installed] no appmgr: " + (typeof _k));
    }

    setTimeout(function () { trySetupChrome(); init(); }, 0);
})();
