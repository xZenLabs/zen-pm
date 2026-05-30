// Shared WAF utilities — loaded before every page script.
var ZenUtils = (function () {
    var API    = "http://127.0.0.1:8080";
    var APP_ID = "com.ZenPM.waf";

    function getKindle() {
        try { return window.kindle || top.kindle; } catch (_e) { return window.kindle; }
    }

    // Fire-and-forget POST to /log/client — bridges WAF diagnostics into ZenPM.log.
    function postLog(msg) {
        try {
            var xhr = new XMLHttpRequest();
            xhr.open("POST", API + "/log/client", true);
            xhr.setRequestHeader("Content-Type", "application/json");
            xhr.send(JSON.stringify({ message: msg }));
        } catch (_e) {}
    }

    function xhrJSON(method, path, body, onSuccess, onError) {
        var xhr = new XMLHttpRequest();
        xhr.open(method, API + path, true);
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
        xhr.open(method, API + path, true);
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

    function goBack() {
        window.location.href = "packages.html";
    }

    // About dialog — triggers native Kindle alert via POST /dialog, falls back to HTML overlay.
    function showAboutModal() {
        postLog("[utils] showAboutModal called");
        xhrJSON("GET", "/health", null, function (data) {
            var version = data && data.version ? 'v' + data.version : 'v?';
            postLog("[utils] got version: " + version + ", sending /dialog");
            xhrJSON("POST", "/dialog",
                { title: "Zen PM", message: version },
                function () { postLog("[utils] native dialog shown"); },
                function (err) { postLog("[utils] native dialog failed: " + (err && err.message)); _renderAboutOverlay(version); }
            );
        }, function (err) {
            postLog("[utils] /health failed: " + (err && err.message));
            _renderAboutOverlay('v?');
        });
    }

    function _renderAboutOverlay(versionText) {
        var overlay = document.createElement('div');
        overlay.className = 'about-overlay';

        var box = document.createElement('div');
        box.className = 'about-modal';

        var logoRow = document.createElement('div');
        logoRow.className = 'about-logo-row';

        var img = document.createElement('img');
        img.src = 'assets/zen.svg';
        img.alt = '';
        img.className = 'about-logo-icon';

        var name = document.createElement('span');
        name.className = 'about-app-name';
        name.textContent = 'Zen PM';

        logoRow.appendChild(img);
        logoRow.appendChild(name);

        var ver = document.createElement('p');
        ver.className = 'about-version';
        ver.textContent = versionText;

        var btn = document.createElement('button');
        btn.textContent = 'Close';
        btn.onclick = function () { document.body.removeChild(overlay); };

        box.appendChild(logoRow);
        box.appendChild(ver);
        box.appendChild(btn);
        overlay.appendChild(box);
        document.body.appendChild(overlay);

        overlay.onclick = function (e) {
            if (e.target === overlay) document.body.removeChild(overlay);
        };
    }

    // Sets up the chrome bar with Refresh + About menu items for any page.
    function setupPageChrome(title, refreshHandler) {
        var k = getKindle();
        if (!k || !k.messaging) return;

        var systemMenu = {
            "clientParams": {
                "profile": {
                    "name": "default",
                    "items": [
                        { "id": "ZEN_REFRESH", "state": "enabled", "handling": "notifyApp", "label": "Refresh", "position": 0 },
                        { "id": "ZEN_ABOUT",   "state": "enabled", "handling": "notifyApp", "label": "About",   "position": 1 }
                    ],
                    "selectionMode": "none",
                    "closeOnUse": true
                }
            }
        };

        k.messaging.receiveMessage("systemMenuItemSelected", function (property, data) {
            if (data === "ZEN_REFRESH" && refreshHandler) refreshHandler();
            if (data === "ZEN_ABOUT") showAboutModal();
        });

        if (k.chrome && k.chrome.isDecanterChromeEnabled) {
            k.messaging.sendMessage("com.lab126.chromebar", "configureChrome", {
                "appId": APP_ID,
                "topNavBar": {
                    "template": "title",
                    "title": title,
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
                            "buttons": [{ "id": "menu", "state": "enabled", "handling": "system" }]
                        }
                    }
                },
                "systemMenu": systemMenu
            });
        }
    }

    // Render universal bottom navbar. Call once per page with the active tab id:
    // 'home', 'sources', 'debug', or 'packages'.
    function renderNavbar(activeTab) {
        postLog("[utils] renderNavbar: " + activeTab);
        var tabs = [
            { id: 'home',     label: 'Home',     icon: 'assets/home.svg',     href: 'index.html' },
            { id: 'packages', label: 'Packages', icon: 'assets/packages.svg', href: 'packages.html' },
            { id: 'sources',  label: 'Sources',  icon: 'assets/sources.svg',  href: 'sources.html' },
            { id: 'debug',    label: 'Debug',    icon: 'assets/debug.svg',    href: 'log.html' }
        ];

        var nav = document.createElement('nav');
        nav.className = 'bottom-nav';

        for (var _i = 0; _i < tabs.length; _i++) {
            var t = tabs[_i];
            var link = document.createElement('a');
            link.href = t.href;
            link.className = 'nav-tab' + (t.id === activeTab ? ' active' : '');
            if (t.id === activeTab) link.setAttribute('aria-current', 'page');

            var img = document.createElement('img');
            img.src = t.icon;
            img.alt = '';
            img.className = 'nav-icon';
            img.width = 32;
            img.height = 32;

            var span = document.createElement('span');
            span.className = 'nav-label';
            span.textContent = t.label;

            link.appendChild(img);
            link.appendChild(span);
            nav.appendChild(link);
        }

        document.body.appendChild(nav);
        postLog("[utils] navbar appended to body, childCount=" + nav.childElementCount);
    }

    return {
        API:             API,
        APP_ID:          APP_ID,
        getKindle:       getKindle,
        postLog:         postLog,
        xhrJSON:         xhrJSON,
        xhrText:         xhrText,
        goBack:          goBack,
        renderNavbar:    renderNavbar,
        showAboutModal:  showAboutModal,
        setupPageChrome: setupPageChrome
    };
})();
