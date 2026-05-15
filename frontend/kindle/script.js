(function () {
    var APP_ID = "com.zenpm.waf";
    var DEFAULT_API = "http://127.0.0.1:8080";
    var STORAGE_KEY = "zenpm.api.base";
    var POLL_DELAY = 3500;

    var state = {
        packages: [],
        busy: false,
        apiBase: DEFAULT_API,
        connected: false
    };

    var el = {
        runtimeStatus: document.getElementById("runtimeStatus"),
        saveCmdBtn:    document.getElementById("saveCmdBtn"),
        cmdPath:       document.getElementById("cmdPath"),
        hint:          document.getElementById("hint"),
        packages:      document.getElementById("packages"),
        busyState:     document.getElementById("busyState")
    };

    // Fire-and-forget POST to /log/client — bridges WAF diagnostics into zenpm.log.
    // Wrapped in try/catch: old mesquite may reject XHR creation before ongo fires.
    function postLog(msg) {
        try {
            var xhr = new XMLHttpRequest();
            xhr.open("POST", state.apiBase + "/log/client", true);
            xhr.setRequestHeader("Content-Type", "application/json");
            xhr.send(JSON.stringify({"message": msg}));
        } catch (_e) {}
    }

    // Mirror diagnostic events to server log (zenpm.log) via fire-and-forget POST.
    function dbg(msg) {
        postLog(msg);
    }

    // Surface uncaught JS errors into the hint element (no output panel on main page).
    window.onerror = function (msg, src, line) {
        var text = "JS ERROR: " + msg + " (" + (src || "?") + ":" + (line || "?") + ")";
        if (el.hint) el.hint.textContent = text;
        postLog(text);
        return false;
    };

    dbg("script loaded");

    function setBusy(flag, message) {
        state.busy = flag;
        el.busyState.textContent = message || (flag ? "Working" : "Idle");
    }

    // Pure callback XHR - no Promises, compatible with all Kindle WebKit versions.
    function xhrJSON(method, path, body, onSuccess, onError) {
        var xhr = new XMLHttpRequest();
        xhr.open(method, state.apiBase + path, true);
        if (body !== null && body !== undefined) {
            xhr.setRequestHeader("Content-Type", "application/json");
        }
        xhr.onreadystatechange = function () {
            if (xhr.readyState !== 4) return;
            if (xhr.status >= 200 && xhr.status < 300) {
                try { onSuccess(JSON.parse(xhr.responseText)); }
                catch (_e) { onSuccess(xhr.responseText); }
            } else if (xhr.status === 0) {
                onError(new Error("Network error - is daemon running?"));
            } else {
                onError(new Error("HTTP " + xhr.status + ": " + xhr.responseText));
            }
        };
        xhr.send(body !== null && body !== undefined ? JSON.stringify(body) : null);
    }

    function xhrText(method, path, onSuccess, onError) {
        var xhr = new XMLHttpRequest();
        xhr.open(method, state.apiBase + path, true);
        xhr.onreadystatechange = function () {
            if (xhr.readyState !== 4) return;
            if (xhr.status >= 200 && xhr.status < 300) {
                onSuccess(xhr.responseText || "");
            } else if (xhr.status === 0) {
                onError(new Error("Network error"));
            } else {
                onError(new Error("HTTP " + xhr.status));
            }
        };
        xhr.send(null);
    }

    function loadPackages(onDone) {
        xhrJSON("GET", "/packages?platform=kindle", null,
            function (data) {
                state.packages = Array.isArray(data) ? data : [];
                renderPackages();
                if (onDone) onDone();
            },
            function (err) {
                el.hint.textContent = "Failed to load packages.";
                postLog("Error loading packages: " + String(err));
                if (onDone) onDone();
            }
        );
    }

    var _retryCount = 0;
    var MAX_RETRIES = 8;
    var RETRY_DELAY = 3000;

    function detectRuntime() {
        setBusy(true, "Connecting...");
        dbg("GET /health -> " + state.apiBase + " (attempt " + (_retryCount + 1) + ")");
        xhrJSON("GET", "/health", null,
            function (data) {
                _retryCount = 0;
                state.connected = true;
                el.runtimeStatus.textContent = "ZenPM v" + (data.version || "?");
                loadPackages(function () { setBusy(false, "Idle"); });
            },
            function (err) {
                if (_retryCount < MAX_RETRIES) {
                    _retryCount++;
                    el.runtimeStatus.textContent = "Connecting (" + _retryCount + "/" + MAX_RETRIES + ")...";
                    dbg("Retry in " + (RETRY_DELAY / 1000) + "s: " + String(err));
                    setTimeout(detectRuntime, RETRY_DELAY);
                } else {
                    _retryCount = 0;
                    setBusy(false, "Idle");
                    el.runtimeStatus.textContent = "Server not running";
                    el.hint.textContent = "ZenPM daemon not found. Re-run ZenPM.sh to start it.";
                    postLog("Daemon unreachable after " + MAX_RETRIES + " retries: " + String(err));
                }
            }
        );
    }

    function readSavedApiBase() {
        try {
            var saved = window.localStorage.getItem(STORAGE_KEY);
            if (saved && saved.trim()) state.apiBase = saved.trim();
        } catch (_e) {}
        el.cmdPath.value = state.apiBase;
    }

    function saveApiBase() {
        var value = (el.cmdPath.value || "").trim();
        if (!value) return;
        state.apiBase = value;
        try { window.localStorage.setItem(STORAGE_KEY, value); } catch (_e) {}
        postLog("API base saved: " + value);
        detectRuntime();
    }

    function refreshPackages() {
        if (state.busy) return;
        if (!state.connected) { detectRuntime(); return; }
        setBusy(true, "Refreshing...");
        xhrJSON("POST", "/repo/refresh", null,
            function () {
                loadPackages(function () { setBusy(false, "Idle"); });
            },
            function (err) {
                postLog("Refresh failed: " + String(err));
                el.hint.textContent = "Refresh failed.";
                setBusy(false, "Idle");
            }
        );
    }

    function pollAfterOp() {
        setTimeout(function () {
            loadPackages(function () { setBusy(false, "Idle"); });
        }, POLL_DELAY);
    }

    function performPackageAction(pkg) {
        if (!state.connected || state.busy) return;
        var action = pkg.installed ? "uninstall" : "install";
        setBusy(true, (action === "install" ? "Installing " : "Uninstalling ") + pkg.name);
        xhrJSON("POST", "/packages/" + encodeURIComponent(pkg.id) + "/" + action, null,
            function () {
                pollAfterOp();
            },
            function (err) {
                postLog("Failed to start " + action + ": " + String(err));
                el.hint.textContent = "Failed to " + action + " " + pkg.name + ".";
                setBusy(false, "Idle");
            }
        );
    }

    function renderPackages() {
        el.packages.innerHTML = "";
        if (!state.packages.length) {
            el.hint.textContent = "No packages found. Try Refresh Packages.";
            return;
        }
        el.hint.textContent = "Showing " + state.packages.length + " package(s).";
        for (var _i = 0; _i < state.packages.length; _i++) {
            (function (pkg) {
                var card = document.createElement("article");
                card.className = "package-card";

                var title = document.createElement("h3");
                title.className = "package-name";
                title.textContent = pkg.name;

                var meta = document.createElement("p");
                meta.className = "package-meta";
                meta.textContent = pkg.id + " | v" + pkg.version;

                var badges = document.createElement("div");
                badges.className = "badges";

                var platBadge = document.createElement("span");
                platBadge.className = "badge";
                platBadge.textContent = Array.isArray(pkg.platforms)
                    ? pkg.platforms.join(", ")
                    : String(pkg.platforms || "");
                badges.appendChild(platBadge);

                var instBadge = document.createElement("span");
                instBadge.className = "badge " + (pkg.installed ? "installed" : "missing");
                instBadge.textContent = pkg.installed ? "installed" : "not installed";
                badges.appendChild(instBadge);

                var actionBtn = document.createElement("button");
                actionBtn.type = "button";
                actionBtn.className = pkg.installed ? "danger" : "primary";
                actionBtn.textContent = pkg.installed ? "Uninstall" : "Install";
                actionBtn.disabled = state.busy;
                actionBtn.onclick = function () { performPackageAction(pkg); };

                card.appendChild(title);
                card.appendChild(meta);
                card.appendChild(badges);
                card.appendChild(actionBtn);
                el.packages.appendChild(card);
            })(state.packages[_i]);
        }
    }

    // Register native Kindle OS system chrome (3-dot menu).
    // Mirrors KindleForge: decanter (KPP/newer) vs pillow (older).
    function setupChrome() {
        var k;
        try { k = window.kindle || top.kindle; } catch (_e) { k = window.kindle; }
        if (!k) { dbg("setupChrome: no window.kindle"); return; }
        if (!k.messaging) { dbg("setupChrome: no kindle.messaging"); return; }

        var systemMenu = {
            "clientParams": {
                "profile": {
                    "name": "default",
                    "items": [
                        { "id": "ZENPM_REFRESH",  "state": "enabled", "handling": "notifyApp", "label": "Refresh Packages", "position": 0 },
                        { "id": "ZENPM_DEBUGLOG", "state": "enabled", "handling": "notifyApp", "label": "Debug Logs",        "position": 1 }
                    ],
                    "selectionMode": "none",
                    "closeOnUse": true
                }
            }
        };

        k.messaging.receiveMessage("systemMenuItemSelected", function (eventType, id) {
            if      (id === "ZENPM_REFRESH")  refreshPackages();
            else if (id === "ZENPM_DEBUGLOG") window.location.href = "log.html";
        });

        if (k.chrome && k.chrome.isDecanterChromeEnabled) {
            dbg("setupChrome: decanter (KPP)");
            k.messaging.sendMessage("com.lab126.chromebar", "configureChrome", {
                "appId": APP_ID,
                "topNavBar": {
                    "template": "title",
                    "title": "Zen Package Manager",
                    "buttons": [
                        { "id": "KPP_MORE",  "state": "enabled", "handling": "system" },
                        { "id": "KPP_CLOSE", "state": "enabled", "handling": "system" }
                    ]
                },
                "systemMenu": systemMenu
            });
        } else {
            dbg("setupChrome: pillow");
            k.messaging.sendMessage("com.lab126.pillow", "configureChrome", {
                "appId": APP_ID,
                "searchBar": {
                    "clientParams": {
                        "profile": {
                            "name": "default",
                            "buttons": [
                                { "id": "menu", "state": "enabled", "handling": "system" }
                            ]
                        }
                    }
                },
                "systemMenu": systemMenu
            });
        }
    }

    function bindEvents() {
        el.saveCmdBtn.addEventListener("click", saveApiBase);
    }

    // Guard so init() fires exactly once.
    var _inited = false;
    function init() {
        if (_inited) return;
        _inited = true;
        dbg("init");
        readSavedApiBase();
        bindEvents();
        detectRuntime();
    }

    // setupChrome MUST run inside ongo — the messaging bridge isn't live until
    // the WAF framework calls ongo. Sending configureChrome before that silently drops.
    var _k;
    try { _k = window.kindle || top.kindle; } catch (_e) { _k = window.kindle; }
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
