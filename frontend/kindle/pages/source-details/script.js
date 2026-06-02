(function () {
    var postLog = ZenUtils.postLog;
    var fetchJSON = ZenUtils.fetchJSON;
    var showModal = ZenUtils.showModal;
    var POLL_DELAY = 3500;
    var MAX_POLL_RETRIES = 20;

    var state = {
        repo: null,
        packages: [],
        visible: [],
        busy: false,
        connected: false,
        pendingOp: null
    };

    var el = {
        backBtn: document.getElementById("backBtn"),
        heading: document.getElementById("sourceHeading"),
        hint: document.getElementById("sourceHint"),
        summary: document.getElementById("sourceSummary"),
        packages: document.getElementById("sourcePackages")
    };

    var cardScroll = null;

    window.onerror = function (msg, src, line) {
        var text = "[source-details] JS ERROR: " + msg + " (" + (src || "?") + ":" + (line || "?") + ")";
        if (el.hint) el.hint.textContent = text;
        postLog(text);
        return false;
    };

    function queryValue(name) {
        var query = window.location.search ? window.location.search.substring(1) : "";
        var parts = query.split("&");
        for (var i = 0; i < parts.length; i++) {
            var pair = parts[i].split("=");
            if (decodeURIComponent(pair[0] || "") === name) {
                return decodeURIComponent((pair[1] || "").replace(/\+/g, " "));
            }
        }
        return "";
    }

    var sourceName = queryValue("name");

    function setBusy(flag, message) {
        state.busy = flag;
        if (message && el.hint) {
            el.hint.textContent = message;
        }
    }

    function loadSourceAndPackages() {
        return fetchJSON("GET", "/repos", null).then(function (repos) {
            var list = Array.isArray(repos) ? repos : [];
            state.repo = null;
            for (var i = 0; i < list.length; i++) {
                if (list[i].name === sourceName) {
                    state.repo = list[i];
                    break;
                }
            }
            return fetchJSON("GET", "/packages?platform=kindle", null);
        }).then(function (packages) {
            state.packages = Array.isArray(packages) ? packages : [];
            renderSourceDetails();
        }).catch(function (err) {
            el.hint.textContent = "Failed to load source.";
            postLog("[source-details] load error: " + String(err));
        });
    }

    function pollAfterOp() {
        var op = state.pendingOp;
        var attempt = 0;
        function tryPoll() {
            attempt += 1;
            loadSourceAndPackages().then(function () {
                if (!state.pendingOp || state.pendingOp.id !== op.id) { return; }
                var pkg = null;
                for (var i = 0; i < state.packages.length; i++) {
                    if (state.packages[i].id === op.id) {
                        pkg = state.packages[i];
                        break;
                    }
                }
                var succeeded = op.action === "reinstall" ? (pkg && pkg.installed) : (pkg && pkg.installed !== op.wasInstalled);
                if (succeeded) {
                    state.pendingOp = null;
                    var doneAction = op.action === "install" ? "installed" : (op.action === "reinstall" ? "reinstalled" : "uninstalled");
                    showModal("Done", pkg.name + " " + doneAction + " successfully.");
                    setBusy(false, "");
                } else if (attempt >= MAX_POLL_RETRIES) {
                    state.pendingOp = null;
                    showModal("Failed", op.action + " of " + op.id + " did not complete.\n\nCheck the debug log for details.");
                    setBusy(false, "");
                } else {
                    setTimeout(tryPoll, POLL_DELAY);
                }
            });
        }
        setTimeout(tryPoll, POLL_DELAY);
    }

    function startPackageAction(pkg, action) {
        var backendAction = action === "reinstall" ? "install" : action;
        setBusy(true, (action === "uninstall" ? "Uninstalling " : (action === "reinstall" ? "Reinstalling " : "Installing ")) + pkg.name);
        state.pendingOp = { id: pkg.id, action: action, wasInstalled: pkg.installed };
        var actionLabel = action === "uninstall" ? "Uninstalling" : (action === "reinstall" ? "Reinstalling" : "Installing");
        showModal(actionLabel, pkg.name + "\n\nDownloading... Please wait.", { className: "modal-overlay-clear" });
        fetchJSON("POST", "/packages/" + encodeURIComponent(pkg.id) + "/" + backendAction, null).then(function () {
            postLog("[source-details] " + action + " started for " + pkg.id);
            pollAfterOp();
        }).catch(function (err) {
            postLog("[source-details] Failed to start " + action + ": " + String(err));
            showModal("Error", "Failed to " + action + " " + pkg.name + ".\n\n" + String(err));
            state.pendingOp = null;
            setBusy(false, "");
        });
    }

    function performPackageAction(pkg) {
        if (!state.connected) {
            el.hint.textContent = "Not connected to daemon. Try reopening the page.";
            return;
        }
        if (state.busy) {
            el.hint.textContent = "Another operation is in progress. Please wait.";
            return;
        }
        if (pkg.installed) {
            ZenUtils.showPackageModifyModal(pkg, {
                info: function () { showPackageDetails(pkg); },
                reinstall: function () {
                    ZenUtils.showPackageActionConfirm(pkg, "reinstall", function () { startPackageAction(pkg, "reinstall"); });
                },
                uninstall: function () {
                    ZenUtils.showPackageActionConfirm(pkg, "uninstall", function () { startPackageAction(pkg, "uninstall"); });
                }
            });
            return;
        }
        ZenUtils.showPackageActionConfirm(pkg, "install", function () {
            startPackageAction(pkg, "install");
        });
    }

    function showPackageDetails(pkg) {
        if (!pkg || (!pkg.id && !pkg.name)) return;
        window.location.href = ZenUtils.packageDetailsURL(pkg);
    }

    function repoIconURL(repo) {
        if (repo.name === ZenUtils.REPO_KINDLEFORGE_NAME) {
            return "../../assets/kindleforge.svg";
        }
        return repo.url.replace(/\/+$/, "") + "/favicon.svg";
    }

    function renderSourceSummary() {
        el.summary.innerHTML = "";
        if (!state.repo) return;

        var top = document.createElement("div");
        top.className = "source-summary-main";

        var iconWrap = document.createElement("div");
        iconWrap.className = "source-summary-icon-wrap";

        var icon = document.createElement("img");
        icon.className = "source-summary-icon";
        icon.alt = "";
        icon.width = 96;
        icon.height = 96;
        icon.onerror = function () {
            if (icon.src && icon.src.indexOf('/favicon.svg') !== -1) {
                icon.src = icon.src.replace('/favicon.svg', '/favicon.ico');
            }
        };
        icon.src = repoIconURL(state.repo);
        iconWrap.appendChild(icon);
        top.appendChild(iconWrap);

        var text = document.createElement("div");
        text.className = "source-summary-text";

        var name = document.createElement("h3");
        name.textContent = state.repo.name;
        text.appendChild(name);

        var url = document.createElement("p");
        url.className = "source-summary-url";
        url.textContent = state.repo.url;
        text.appendChild(url);

        var meta = document.createElement("p");
        meta.className = "source-summary-meta";
        meta.textContent = state.visible.length + " package" + (state.visible.length === 1 ? "" : "s") + " \u2022 " + (state.repo.trust || "unknown");
        text.appendChild(meta);

        top.appendChild(text);
        el.summary.appendChild(top);
    }

    function renderSourceDetails() {
        el.packages.innerHTML = "";
        el.summary.innerHTML = "";
        state.visible = [];

        if (!sourceName) {
            el.hint.textContent = "No source selected.";
            return;
        }
        if (!state.repo) {
            el.hint.textContent = "Source not found.";
            return;
        }

        for (var i = 0; i < state.packages.length; i++) {
            if (state.packages[i].repo === state.repo.name) {
                state.visible.push(state.packages[i]);
            }
        }

        el.heading.textContent = state.repo.name;
        el.hint.textContent = state.visible.length ? "" : "No packages found for this source.";
        renderSourceSummary();
        ZenUtils.reconcilePackageCards(el.packages, state.visible, performPackageAction, showPackageDetails);
        if (cardScroll) cardScroll.rebuild();
    }

    function setupChrome() {
        ZenUtils.setupPageChrome('ZenPM - Source Details', loadSourceAndPackages);
    }

    function bindEvents() {
        if (el.backBtn) {
            el.backBtn.onclick = function () {
                if (window.history && window.history.length > 1) {
                    window.history.back();
                } else {
                    window.location.href = "../sources/index.html";
                }
            };
        }
    }

    var _inited = false;
    function init() {
        if (_inited) return;
        _inited = true;
        bindEvents();
        ZenUtils.renderNavbar('sources');
        cardScroll = ZenUtils.setupCardScroll(".source-details-scroll", "package-card");
        if (!sourceName) {
            el.hint.textContent = "No source selected.";
            return;
        }
        setBusy(true, "Connecting...");
        fetchJSON("GET", "/health", null).then(function () {
            state.connected = true;
            return loadSourceAndPackages();
        }).then(function () {
            setBusy(false, "");
        }).catch(function (err) {
            setBusy(false, "");
            el.hint.textContent = ZenUtils.daemonUnavailableMessage();
            postLog("[source-details] Daemon unreachable: " + String(err));
        });
    }

    var _chromeSetup = false;
    function trySetupChrome() {
        if (_chromeSetup) return;
        _chromeSetup = true;
        try { setupChrome(); } catch (_e) { postLog("[source-details] setupChrome threw: " + _e); }
    }

    var _k = ZenUtils.getKindle();
    if (_k && _k.appmgr) {
        postLog("[source-details] ongo registered");
        _k.appmgr.ongo = function () {
            postLog("[source-details] ongo fired");
            trySetupChrome();
            init();
        };
    } else {
        postLog("[source-details] no appmgr: " + (typeof _k));
    }

    setTimeout(function () { trySetupChrome(); init(); }, 0);
})();
