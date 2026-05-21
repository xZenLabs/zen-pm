(function () {
    var REFRESH_INTERVAL = 5000;
    var postLog = ZenUtils.postLog;

    var el = { logOutput: document.getElementById("logOutput") };

    window.onerror = function (msg, src, line) {
        postLog("[log.js] JS ERROR: " + msg + " (" + (src || "?") + ":" + (line || "?") + ")");
        return false;
    };

    postLog("[log.js] script loaded");

    // Shorten ISO timestamps to HH:MM:SS for the small Kindle screen.
    function trimTimestamps(text) {
        return text.replace(/\d{4}-\d{2}-\d{2}T(\d{2}:\d{2}):\d{2}Z/g, "$1");
    }

    function refreshLog() {
        ZenUtils.xhrText("GET", "/log?tail=500",
            function (log) {
                var lines = trimTimestamps(log).split("\n");
                lines.reverse();
                el.logOutput.textContent = lines.join("\n") || "Log is empty.";
                el.logOutput.scrollTop = 0;
            },
            function (err) {
                el.logOutput.textContent = "Could not read log: " + String(err);
            }
        );
    }

    function setupChrome() {
        var k = ZenUtils.getKindle();
        postLog("[log.js] setupChrome: kindle=" + (k ? "yes" : "no") + " messaging=" + (k && k.messaging ? "yes" : "no"));
        if (!k || !k.messaging) return;

        var systemMenu = {
            "clientParams": {
                "profile": {
                    "name": "default",
                    "items": [
                        { "id": "ZENPM_PACKAGES",  "state": "enabled", "handling": "notifyApp", "label": "Packages",     "position": 0 },
                        { "id": "ZENLOG_REPOS",    "state": "enabled", "handling": "notifyApp", "label": "Repositories", "position": 1 },
                        { "id": "ZENLOG_REFRESH",  "state": "enabled", "handling": "notifyApp", "label": "Refresh Log",  "position": 2 }
                    ],
                    "selectionMode": "none",
                    "closeOnUse": true
                }
            }
        };

        k.messaging.receiveMessage("systemMenuItemSelected", function (property, data) {
            postLog("[log.js] systemMenuItemSelected: p=" + property + " d=" + data);
            if (data === "ZENPM_PACKAGES") ZenUtils.goBack();
            if (data === "ZENLOG_REPOS")    window.location.href = "repos.html";
            if (data === "ZENLOG_REFRESH")  refreshLog();
        });

        if (k.chrome && k.chrome.isDecanterChromeEnabled) {
            postLog("[log.js] setupChrome: decanter (KPP)");
            k.messaging.sendMessage("com.lab126.chromebar", "configureChrome", {
                "appId": ZenUtils.APP_ID,
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
            postLog("[log.js] setupChrome: pillow");
            k.messaging.sendMessage("com.lab126.pillow", "configureChrome", {
                "appId": ZenUtils.APP_ID,
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

    var _inited = false;
    function init() {
        if (_inited) return;
        _inited = true;
        postLog("[log.js] init");
        refreshLog();
        setInterval(refreshLog, REFRESH_INTERVAL);
    }

    var _chromeSetup = false;
    function trySetupChrome() {
        if (_chromeSetup) return;
        _chromeSetup = true;
        try { setupChrome(); } catch (_e) { postLog("[log.js] setupChrome threw: " + _e); }
    }

    var _k = ZenUtils.getKindle();
    if (_k && _k.appmgr) {
        postLog("[log.js] ongo registered");
        _k.appmgr.ongo = function () {
            postLog("[log.js] ongo fired");
            trySetupChrome();
            init();
        };
    } else {
        postLog("[log.js] no appmgr: " + (typeof _k));
    }

    // Also attempt chrome setup at load time — ongo may not re-fire on sub-page navigation.
    setTimeout(function () { trySetupChrome(); init(); }, 0);
})();
