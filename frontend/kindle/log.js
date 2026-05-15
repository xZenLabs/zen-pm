(function () {
    var APP_ID = "com.zenpm.waf";
    var DEFAULT_API = "http://127.0.0.1:8080";
    var STORAGE_KEY = "zenpm.api.base";
    var REFRESH_INTERVAL = 5000;

    var state = { apiBase: DEFAULT_API };

    var el = {
        logStatus: document.getElementById("logStatus"),
        logOutput: document.getElementById("logOutput")
    };

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

    // Shorten ISO timestamps to HH:MM:SS for the small Kindle screen.
    function trimTimestamps(text) {
        return text.replace(/\d{4}-\d{2}-\d{2}T(\d{2}:\d{2}):\d{2}Z/g, "$1");
    }

    function refreshLog() {
        xhrText("GET", "/log?tail=500",
            function (log) {
                var lines = trimTimestamps(log).split("\n");
                lines.reverse();
                el.logOutput.textContent = lines.join("\n") || "Log is empty.";
                el.logOutput.scrollTop = 0;
                el.logStatus.textContent = "Live";
            },
            function (err) {
                el.logStatus.textContent = "Error";
                el.logOutput.textContent = "Could not read log: " + String(err);
            }
        );
    }

    function setupChrome() {
        var k;
        try { k = window.kindle || top.kindle; } catch (_e) { k = window.kindle; }
        if (!k || !k.messaging) return;

        var systemMenu = {
            "clientParams": {
                "profile": {
                    "name": "default",
                    "items": [
                        { "id": "ZENLOG_REFRESH", "state": "enabled", "handling": "notifyApp", "label": "Refresh Log",       "position": 0 },
                        { "id": "ZENLOG_BACK",    "state": "enabled", "handling": "notifyApp", "label": "Back to Packages", "position": 1 }
                    ],
                    "selectionMode": "none",
                    "closeOnUse": true
                }
            }
        };

        k.messaging.receiveMessage("systemMenuItemSelected", function (eventType, id) {
            if      (id === "ZENLOG_REFRESH") refreshLog();
            else if (id === "ZENLOG_BACK")    window.location.href = "index.html";
        });

        if (k.chrome && k.chrome.isDecanterChromeEnabled) {
            k.messaging.sendMessage("com.lab126.chromebar", "configureChrome", {
                "appId": APP_ID,
                "topNavBar": {
                    "template": "title",
                    "title": "ZenPM \u2014 Logs",
                    "buttons": [
                        { "id": "KPP_MORE",  "state": "enabled", "handling": "system" },
                        { "id": "KPP_CLOSE", "state": "enabled", "handling": "system" }
                    ]
                },
                "systemMenu": systemMenu
            });
        } else {
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

    function init() {
        try {
            var saved = window.localStorage.getItem(STORAGE_KEY);
            if (saved && saved.trim()) state.apiBase = saved.trim();
        } catch (_e) {}
        refreshLog();
        setInterval(refreshLog, REFRESH_INTERVAL);
    }

    var _k;
    try { _k = window.kindle || top.kindle; } catch (_e) { _k = window.kindle; }
    if (_k && _k.appmgr) {
        _k.appmgr.ongo = function () {
            try { setupChrome(); } catch (_e) {}
            init();
        };
    } else {
        setTimeout(init, 0);
    }
})();
