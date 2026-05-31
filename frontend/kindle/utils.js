// Shared WAF utilities — loaded before every page script.
var ZenUtils = (function () {
    var API    = "http://127.0.0.1:8080";
    var APP_ID = "com.zenlabs.zenpm";

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
        var isSub = window.location.pathname.indexOf('/pages/') !== -1;
        window.location.href = (isSub ? '../..' : '.') + '/pages/search/index.html';
    }

    // Trigger self-update via POST /update. The update script handles native alerts.
    function startUpdate() {
        postLog("[utils] startUpdate: triggering update");
        fetchJSON("POST", "/update", null).then(function () {
            postLog("[utils] update accepted, daemon restarting");
        }).catch(function (err) {
            postLog("[utils] update failed: " + (err && err.message));
        });
    }

    // About dialog — triggers native Kindle alert via POST /dialog, falls back to HTML overlay.
    function showAboutModal() {
        postLog("[utils] showAboutModal called");
        fetchJSON("GET", "/health", null).then(function (data) {
            var raw = data && data.version ? data.version : '?';
            var version = raw.replace(/^v/, '');
            postLog("[utils] got version: " + version + ", sending /dialog");
            return fetchJSON("POST", "/dialog", { title: "ZenPM", message: "Version: " + version + "\nAuthor: Anthony Gress (ZenLabs)\n2026" });
        }).then(function () {
            postLog("[utils] native dialog shown");
        }).catch(function (err) {
            postLog("[utils] dialog/health failed: " + (err && err.message));
            _renderAboutOverlay('?');
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
        name.textContent = 'ZenPM';

        logoRow.appendChild(img);
        logoRow.appendChild(name);

        var ver = document.createElement('p');
        ver.className = 'about-version';
        ver.textContent = 'Version: ' + versionText;

        var author = document.createElement('p');
        author.className = 'about-author';
        author.textContent = 'Author: Anthony Gress (ZenLabs)';

        var year = document.createElement('p');
        year.className = 'about-year';
        year.textContent = '2026';

        var btn = document.createElement('button');
        btn.textContent = 'Close';
        btn.onclick = function () { document.body.removeChild(overlay); };

        box.appendChild(logoRow);
        box.appendChild(ver);
        box.appendChild(author);
        box.appendChild(year);
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
                        { "id": "ZEN_UPDATE",  "state": "enabled", "handling": "notifyApp", "label": "Update",  "position": 1 },
                        { "id": "ZEN_ABOUT",   "state": "enabled", "handling": "notifyApp", "label": "About",   "position": 2 }
                    ],
                    "selectionMode": "none",
                    "closeOnUse": true
                }
            }
        };

        k.messaging.receiveMessage("systemMenuItemSelected", function (property, data) {
            if (data === "ZEN_REFRESH" && refreshHandler) refreshHandler();
            if (data === "ZEN_UPDATE") startUpdate();
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

        // Pages inside pages/ are two levels deep — prefix with ../.. for root assets.
        var isSub = window.location.pathname.indexOf('/pages/') !== -1;
        var bp = isSub ? '../..' : '.';

        var tabs = [
            { id: 'home',      label: 'Featured',  icon: bp + '/assets/star.svg',      href: bp + '/index.html' },
            { id: 'sources',   label: 'Sources',    icon: bp + '/assets/sources.svg',   href: bp + '/pages/sources/index.html' },
            { id: 'installed', label: 'Installed',  icon: bp + '/assets/packages.svg',  href: bp + '/pages/installed/index.html' },
            { id: 'debug',     label: 'Debug',      icon: bp + '/assets/debug.svg',     href: bp + '/pages/debug/index.html' },
            { id: 'search',    label: 'Search',     icon: bp + '/assets/search.svg',    href: bp + '/pages/search/index.html' }
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

    // Shared modal overlay — shows a centered box with title + message + Close button.
    function showModal(title, message) {
        hideModal();
        var overlay = document.createElement("div");
        overlay.className = "modal-overlay";
        overlay.id = "zenpm-modal-overlay";

        var box = document.createElement("div");
        box.className = "modal-box";

        var h = document.createElement("h3");
        h.textContent = title;
        box.appendChild(h);

        var p = document.createElement("p");
        p.textContent = message;
        box.appendChild(p);

        var btn = document.createElement("button");
        btn.textContent = "Close";
        btn.onclick = hideModal;
        box.appendChild(btn);

        overlay.appendChild(box);
        document.body.appendChild(overlay);

        overlay.onclick = function (e) {
            if (e.target === overlay) hideModal();
        };
    }

    function hideModal() {
        var ov = document.getElementById("zenpm-modal-overlay");
        if (ov) ov.parentNode.removeChild(ov);
    }

    // Shared package card — returns a DOM element. clickHandler receives the pkg object.
    function renderPackageCard(pkg, clickHandler) {
        var card = document.createElement("article");
        card.className = "package-card";

        // Header row: icon (left) + title (right), inline like home header.
        var headerRow = document.createElement("div");
        headerRow.className = "package-card-header";

        var title = document.createElement("h3");
        title.className = "package-name";
        title.textContent = pkg.name;
        headerRow.appendChild(title);

        // Tag badges inline next to the title.
        if (pkg.tags && pkg.tags.length) {
            for (var _t = 0; _t < pkg.tags.length; _t++) {
                var tagBadge = document.createElement("span");
                tagBadge.className = "badge tag-badge";
                tagBadge.textContent = pkg.tags[_t];
                headerRow.appendChild(tagBadge);
            }
        }

        // Preload icon — only insert into DOM if it actually loads.
        // KindleForge repo has no favicon — use bundled local SVG.
        var iconSrc = pkg.icon_url;
        if (pkg.repo === "KindleForge") {
            var isSub = window.location.pathname.indexOf('/pages/') !== -1;
            iconSrc = (isSub ? '../..' : '.') + '/assets/kindleforge.svg';
        }

        if (iconSrc) {
            var preload = new Image();
            preload.onload = function () {
                var iconImg = document.createElement("img");
                iconImg.src = iconSrc;
                iconImg.alt = "";
                iconImg.className = "package-card-icon";
                iconImg.width = 64;
                iconImg.height = 64;
                headerRow.insertBefore(iconImg, headerRow.firstChild);
            };
            preload.onerror = function () {
                if (preload.src.indexOf('/favicon.svg') !== -1) {
                    preload.src = preload.src.replace('/favicon.svg', '/favicon.ico');
                    return;
                }
            };
            preload.src = iconSrc;
        }

        card.appendChild(headerRow);

        var meta = document.createElement("p");
        meta.className = "package-meta";
        var repoDisplay = pkg.repo || "?";
        if (pkg.version && pkg.version !== "0.0.0") {
            meta.textContent = repoDisplay + " | v" + pkg.version;
        } else {
            meta.textContent = repoDisplay;
        }

        card.appendChild(meta);

        if (pkg.description) {
            var desc = document.createElement("p");
            desc.className = "package-desc";
            desc.textContent = pkg.description;
            card.appendChild(desc);
        }

        var DOWNLOAD_ICON = "<svg class='btn-icon' viewBox='0 0 24 24'><path d='M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4'></path><polyline points='7 10 12 15 17 10'></polyline><line x1='12' y1='15' x2='12' y2='3'></line></svg>";
        var X_ICON       = "<svg class='btn-icon' viewBox='0 0 24 24'><line x1='18' y1='6' x2='6' y2='18'></line><line x1='6' y1='6' x2='18' y2='18'></line></svg>";

        var actionBtn = document.createElement("button");
        actionBtn.type = "button";
        actionBtn.className = pkg.installed ? "package-action danger" : "package-action";
        actionBtn.innerHTML = (pkg.installed ? X_ICON : DOWNLOAD_ICON) + "<span class='btn-label'>" + (pkg.installed ? "Uninstall" : "Install") + "</span>";
        actionBtn.addEventListener("touchstart", function () { this.blur(); }, false);
        actionBtn.addEventListener("touchend", function () { this.blur(); }, false);
        actionBtn.addEventListener("mouseup", function () { this.blur(); }, false);
        if (clickHandler) {
            actionBtn.addEventListener("click", function () {
                this.blur();
                clickHandler(pkg);
            }, false);
        }

        card.appendChild(actionBtn);
        return card;
    }

    // Card-based scroll navigation — intercepts mousewheel to move one card per
    // swipe, matching KindleForge behavior.  Native scroll on Kindle WAF is too
    // sluggish and requires multiple swipes per item.
    function setupCardScroll(scrollSelector, cardClass) {
        var cards = [];
        var cIndex = 0;
        var scrollEl = null;

        function rebuild() {
            cards = [];
            var elems = document.getElementsByClassName(cardClass);
            for (var i = 0; i < elems.length; i++) cards.push(elems[i]);
            if (!scrollEl) scrollEl = document.querySelector(scrollSelector);
        }

        function goCard(index) {
            if (cards.length === 0) return;
            cIndex = Math.max(0, Math.min(cards.length - 1, index));
            if (scrollEl) scrollEl.scrollTop = cards[cIndex].offsetTop - 10;
        }

        window.addEventListener("mousewheel", function (e) {
            if (cards.length === 0) return;
            e.preventDefault();
            if (e.wheelDeltaY > 0) goCard(cIndex - 1);
            else if (e.wheelDeltaY < 0) goCard(cIndex + 1);
        }, false);

        return { rebuild: rebuild, goCard: goCard };
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
        showModal:       showModal,
        hideModal:       hideModal,
        showAboutModal:  showAboutModal,
        setupPageChrome: setupPageChrome,
        setupCardScroll: setupCardScroll
    };
})();
