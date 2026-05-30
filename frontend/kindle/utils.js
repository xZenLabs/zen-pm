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
            fetch(API + "/log/client", {
                method: "POST",
                headers: { "Content-Type": "application/json" },
                body: JSON.stringify({ message: msg })
            });
        } catch (_e) {}
    }

    // Returns a Promise that resolves with parsed JSON (or raw text on parse error).
    function fetchJSON(method, path, body) {
        var opts = { method: method, headers: {} };
        if (body !== null && body !== undefined) {
            opts.headers["Content-Type"] = "application/json";
            opts.body = JSON.stringify(body);
        }
        return fetch(API + path, opts).then(function (resp) {
            if (!resp.ok) {
                return resp.text().then(function (t) {
                    throw new Error("HTTP " + resp.status + ": " + t);
                });
            }
            return resp.text().then(function (t) {
                try { return JSON.parse(t); }
                catch (_e) { return t; }
            });
        });
    }

    // Returns a Promise that resolves with the response body text.
    function fetchText(method, path) {
        return fetch(API + path, { method: method }).then(function (resp) {
            if (!resp.ok) throw new Error("HTTP " + resp.status);
            return resp.text();
        });
    }

    // Backward-compatible callback wrappers — used by pages not yet refactored.
    function xhrJSON(method, path, body, onSuccess, onError) {
        fetchJSON(method, path, body).then(onSuccess, onError);
    }
    function xhrText(method, path, onSuccess, onError) {
        fetchText(method, path).then(onSuccess, onError);
    }

    function goBack() {
        window.location.href = "packages.html";
    }

    // About dialog — triggers native Kindle alert via POST /dialog, falls back to HTML overlay.
    function showAboutModal() {
        postLog("[utils] showAboutModal called");
        fetchJSON("GET", "/health", null).then(function (data) {
            var version = data && data.version ? 'v' + data.version : 'v?';
            postLog("[utils] got version: " + version + ", sending /dialog");
            return fetchJSON("POST", "/dialog", { title: "Zen PM", message: version });
        }).then(function () {
            postLog("[utils] native dialog shown");
        }).catch(function (err) {
            postLog("[utils] dialog/health failed: " + (err && err.message));
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
    // 'home', 'search', 'installed', 'sources', or 'debug'.
    function renderNavbar(activeTab) {
        postLog("[utils] renderNavbar: " + activeTab);
        var tabs = [
            { id: 'home',      label: 'Home',      icon: 'assets/home.svg',      href: 'index.html' },
            { id: 'sources',   label: 'Sources',    icon: 'assets/sources.svg',   href: 'sources.html' },
            { id: 'installed', label: 'Installed',  icon: 'assets/packages.svg',  href: 'installed.html' },
            { id: 'debug',     label: 'Debug',      icon: 'assets/debug.svg',     href: 'log.html' },
            { id: 'search',    label: 'Search',     icon: 'assets/search.svg',    href: 'packages.html' }
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

    // Shared package card — returns a DOM element. clickHandler receives the pkg object.
    function renderPackageCard(pkg, clickHandler) {
        var card = document.createElement("article");
        card.className = "package-card";

        var title = document.createElement("h3");
        title.className = "package-name";
        title.textContent = pkg.name;

        var meta = document.createElement("p");
        meta.className = "package-meta";
        meta.textContent = pkg.id + " | v" + pkg.version + " | " + (pkg.repo || "?");

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
        actionBtn.className = pkg.installed ? "danger" : "";
        actionBtn.textContent = pkg.installed ? "Uninstall" : "Install";
        if (clickHandler) {
            actionBtn.addEventListener("click", function () { clickHandler(pkg); }, false);
        }

        card.appendChild(title);
        card.appendChild(meta);
        card.appendChild(badges);
        card.appendChild(actionBtn);
        return card;
    }

    return {
        API:             API,
        APP_ID:          APP_ID,
        getKindle:       getKindle,
        postLog:         postLog,
        fetchJSON:       fetchJSON,
        fetchText:       fetchText,
        xhrJSON:         xhrJSON,
        xhrText:         xhrText,
        goBack:          goBack,
        renderNavbar:    renderNavbar,
        renderPackageCard: renderPackageCard,
        showAboutModal:  showAboutModal,
        setupPageChrome: setupPageChrome
    };
})();
