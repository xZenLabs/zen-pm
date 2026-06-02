// Shared WAF utilities — loaded before every page script.
var ZenUtils = (function () {
    var API    = "http://127.0.0.1:8080";
    var APP_ID = "com.zenlabs.zenpm";
    var REPO_ZENLABS_NAME = "ZenLabs";
    var REPO_ZENLABS_URL = "https://xzenlabs.github.io/repo";
    var REPO_KINDLEFORGE_NAME = "KindleForge";
    var REPO_KINDLEFORGE_URL = "https://kf.penguins184.xyz";

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

    function daemonUnavailableMessage() {
        return "ZenPM daemon not reachable. Re-run ZenPM.sh if it is not running. If Airplane Mode is on, Kindle WAF may block local HTTP.";
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

    // Shared modal overlay with optional actions.
    function showBaseModal(options) {
        hideModal();
        options = options || {};
        var overlay = document.createElement("div");
        overlay.className = "modal-overlay";
        if (options.className) overlay.className += " " + options.className;
        overlay.id = "zenpm-modal-overlay";

        var box = document.createElement("div");
        box.className = "modal-box";
        if (options.boxClassName) box.className += " " + options.boxClassName;

        if (options.closeButton !== false) {
            var closeBtn = document.createElement("button");
            closeBtn.type = "button";
            closeBtn.className = "modal-close-btn";
            closeBtn.setAttribute("aria-label", "Close");
            closeBtn.innerHTML = "<svg class='modal-close-icon' viewBox='0 0 24 24' aria-hidden='true'><line x1='18' y1='6' x2='6' y2='18'></line><line x1='6' y1='6' x2='18' y2='18'></line></svg>";
            closeBtn.onclick = hideModal;
            box.appendChild(closeBtn);
        }

        var h = document.createElement("h3");
        h.textContent = options.title || "";
        box.appendChild(h);

        if (options.message) {
            var p = document.createElement("p");
            p.textContent = options.message;
            box.appendChild(p);
        }

        if (options.content) {
            box.appendChild(options.content);
        }

        if (options.actions && options.actions.length) {
            var actions = document.createElement("div");
            actions.className = "modal-actions";
            for (var i = 0; i < options.actions.length; i++) {
                (function (action) {
                    var btn = document.createElement("button");
                    btn.type = "button";
                    btn.textContent = action.label;
                    btn.className = action.primary ? "primary" : "";
                    if (action.danger) btn.className += (btn.className ? " " : "") + "danger";
                    btn.onclick = function () {
                        if (action.close !== false) hideModal();
                        if (action.onClick) action.onClick();
                    };
                    actions.appendChild(btn);
                })(options.actions[i]);
            }
            box.appendChild(actions);
        }

        overlay.appendChild(box);
        document.body.appendChild(overlay);

        overlay.onclick = function (e) {
            if (e.target === overlay) hideModal();
        };
    }

    // Shared status modal — shows a centered box with title + message + Close button.
    function showModal(title, message, options) {
        options = options || {};
        showBaseModal({
            title: title,
            message: message,
            className: options.className,
            boxClassName: options.boxClassName,
            closeButton: options.closeButton,
            actions: [{ label: "Close", primary: true }]
        });
    }

    function showConfirmModal(title, message, confirmLabel, onConfirm, danger) {
        showBaseModal({
            title: title,
            message: message,
            className: "add-source-modal-overlay",
            boxClassName: "confirm-modal-box add-source-modal-box",
            actions: [
                { label: "Cancel" },
                { label: confirmLabel || "OK", primary: true, danger: danger, onClick: onConfirm }
            ]
        });
    }

    function showPackageActionConfirm(pkg, action, onConfirm) {
        var title = "Get Package";
        var question = "Are you sure you want to download " + pkg.name + "?";
        var label = "Get";
        var danger = false;
        if (action === "reinstall") {
            title = "Reinstall Package";
            question = "Are you sure you want to reinstall " + pkg.name + "?";
            label = "Reinstall";
        } else if (action === "uninstall") {
            title = "Uninstall Package";
            question = "Are you sure you want to uninstall " + pkg.name + "?";
            label = "Uninstall";
            danger = true;
        }
        showConfirmModal(title, question, label, onConfirm, danger);
    }

    function showPackageModifyModal(pkg, handlers) {
        handlers = handlers || {};
        var content = document.createElement("div");
        content.className = "modify-options";

        function addOption(label, className, handler) {
            var btn = document.createElement("button");
            btn.type = "button";
            btn.className = "modify-option" + (className ? " " + className : "");
            btn.textContent = label;
            btn.onclick = function () {
                hideModal();
                if (handler) handler();
            };
            content.appendChild(btn);
        }

        if (handlers.info) {
            addOption("Info", "", handlers.info);
        }
        addOption("Reinstall", "", handlers.reinstall);
        addOption("Uninstall", "danger", handlers.uninstall);

        showBaseModal({
            title: pkg.name,
            message: "Modify package",
            className: "add-source-modal-overlay",
            boxClassName: "modify-modal-box add-source-modal-box",
            content: content
        });
    }

    function hideModal() {
        var ov = document.getElementById("zenpm-modal-overlay");
        if (ov) ov.parentNode.removeChild(ov);
    }

    function basePath() {
        return window.location.pathname.indexOf('/pages/') !== -1 ? '../..' : '.';
    }

    function bundledRepoIcon(pkg) {
        if (pkg && pkg.repo === REPO_KINDLEFORGE_NAME) {
            return basePath() + '/assets/kindleforge.svg';
        }
        return pkg && pkg.repo_icon_url ? pkg.repo_icon_url : basePath() + '/assets/packages.svg';
    }

    function firstPackageImage(pkg) {
        if (!pkg) return "";
        if (pkg.icon_url) return pkg.icon_url;
        if (pkg.icon) return pkg.icon;
        if (pkg.image_url) return pkg.image_url;
        if (pkg.images && pkg.images.length) return pkg.images[0];
        if (pkg.image) return pkg.image;
        return bundledRepoIcon(pkg);
    }

    function setImageWithFallback(img, primary, fallback) {
        var triedPrimary = false;
        var triedIco = false;
        img.onerror = function () {
            postLog("[image] load failed src=" + (img.src || "") + " primary=" + (primary || "") + " fallback=" + (fallback || ""));
            if (!triedPrimary && fallback && img.src !== fallback) {
                triedPrimary = true;
                postLog("[image] falling back to " + fallback);
                img.src = fallback;
                return;
            }
            if (!triedIco && img.src && img.src.indexOf('/favicon.svg') !== -1) {
                triedIco = true;
                postLog("[image] trying favicon.ico fallback for " + img.src);
                img.src = img.src.replace('/favicon.svg', '/favicon.ico');
            }
        };
        img.src = primary || fallback || "";
    }

    function packageVersionRepoText(pkg) {
        var repoDisplay = pkg.repo || "?";
        if (pkg.version && pkg.version !== "0.0.0") {
            return "v" + pkg.version + " \u2022 " + repoDisplay;
        }
        return repoDisplay;
    }

    function packageVersionPrefixText(pkg) {
        if (pkg.version && pkg.version !== "0.0.0") {
            return "v" + pkg.version + " \u2022 ";
        }
        return "";
    }

    function packageRepoVerified(pkg) {
        var trust = pkg.repo_trust || "";
        return !!pkg.repo_default || trust === "trusted" || trust === "signed" || pkg.repo === REPO_ZENLABS_NAME || pkg.repo === REPO_KINDLEFORGE_NAME;
    }

    function packageRepoVerificationIcon(pkg) {
        return basePath() + (packageRepoVerified(pkg) ? "/assets/verified.svg" : "/assets/unverified.svg");
    }

    function packageRepoVerificationLabel(pkg) {
        return packageRepoVerified(pkg) ? "Verified" : "Unverified";
    }

    function packageDetailsURL(pkg) {
        var from = "search";
        if (window.location.pathname.indexOf('/pages/installed/') !== -1) from = "installed";
        if (window.location.pathname.indexOf('/pages/source-details/') !== -1) from = "sources";
        if (window.location.pathname.indexOf('/index.html') !== -1 && window.location.pathname.indexOf('/pages/') === -1) from = "home";
        return basePath() + "/pages/package-details/index.html?id=" + encodeURIComponent(pkg.id || pkg.name || "") + "&from=" + encodeURIComponent(from);
    }

    function renderMediaCard(options) {
        options = options || {};
        var card = document.createElement(options.tagName || "article");
        card.className = "media-card";
        if (options.className) card.className += " " + options.className;
        if (options.clickHandler) {
            card.className += " media-card-clickable";
            card.onclick = options.clickHandler;
        }

        var table = document.createElement("div");
        table.className = "media-card-table";

        var iconCell = document.createElement("div");
        iconCell.className = "media-card-icon-cell";

        var icon = document.createElement("img");
        icon.alt = "";
        icon.className = "media-card-icon";
        icon.width = options.iconSize || 96;
        icon.height = options.iconSize || 96;
        setImageWithFallback(icon, options.imageSrc, options.imageFallback);
        iconCell.appendChild(icon);
        table.appendChild(iconCell);

        var textCell = document.createElement("div");
        textCell.className = "media-card-text-cell";

        var titleRow = document.createElement("div");
        titleRow.className = "media-card-title-row";

        var title = document.createElement("h3");
        title.className = "media-card-title";
        title.textContent = options.title || "";
        titleRow.appendChild(title);

        if (options.check || options.titleIconSrc) {
            var checkCell = document.createElement("div");
            checkCell.className = "media-card-check-cell";
            var check = document.createElement("img");
            check.className = "media-card-check";
            if (options.titleIconClass) check.className += " " + options.titleIconClass;
            check.src = options.titleIconSrc || (basePath() + "/assets/checkmark.svg");
            check.alt = options.titleIconAlt || "";
            check.width = options.titleIconSize || 36;
            check.height = options.titleIconSize || 36;
            checkCell.appendChild(check);
            titleRow.appendChild(checkCell);
        }

        textCell.appendChild(titleRow);

        if (options.line2) {
            var line2 = document.createElement("p");
            line2.className = "media-card-line media-card-line-2";
            line2.textContent = options.line2;
            textCell.appendChild(line2);
        }

        if (options.line3) {
            var line3 = document.createElement("p");
            line3.className = "media-card-line media-card-line-3";
            line3.textContent = options.line3;
            textCell.appendChild(line3);
        }
        table.appendChild(textCell);

        if (options.action) {
            var actionCell = document.createElement("div");
            actionCell.className = "media-card-action-cell";
            actionCell.appendChild(options.action);
            table.appendChild(actionCell);
        }

        card.appendChild(table);

        return card;
    }

    // Shared package card — returns a DOM element. clickHandler receives the pkg object.
    function renderPackageCard(pkg, actionHandler, detailHandler) {
        var actionBtn = document.createElement("button");
        actionBtn.type = "button";
        actionBtn.className = pkg.installed ? "package-action modify" : "package-action";
        actionBtn.textContent = pkg.installed ? "Modify" : "Get";
        actionBtn.addEventListener("touchstart", function () { this.blur(); }, false);
        actionBtn.addEventListener("touchend", function () { this.blur(); }, false);
        actionBtn.addEventListener("mouseup", function () { this.blur(); }, false);
        if (actionHandler) {
            actionBtn.addEventListener("click", function (e) {
                if (e && e.stopPropagation) e.stopPropagation();
                this.blur();
                actionHandler(pkg);
            }, false);
        }

        var packageImage = firstPackageImage(pkg);
        var packageFallback = bundledRepoIcon(pkg);
        postLog("[package-card] id=" + (pkg.id || pkg.name || "?") + " icon_url=" + (pkg.icon_url || "") + " image_url=" + (pkg.image_url || "") + " imageSrc=" + (packageImage || "") + " fallback=" + (packageFallback || ""));

        var card = renderMediaCard({
            className: "package-card",
            imageSrc: packageImage,
            imageFallback: packageFallback,
            title: "",
            clickHandler: detailHandler ? function () { detailHandler(pkg); } : null
        });

        var textCell = card.getElementsByClassName("media-card-text-cell")[0];
        if (textCell) {
            textCell.innerHTML = "";

            var titleRow = document.createElement("div");
            titleRow.className = "package-title-row";

            var title = document.createElement("h3");
            title.className = "package-title";
            title.textContent = pkg.name;
            titleRow.appendChild(title);
            textCell.appendChild(titleRow);

            var descRow = document.createElement("div");
            descRow.className = "package-description-row";

            var desc = document.createElement("p");
            desc.className = "package-card-description";
            desc.textContent = pkg.description || "No description";
            descRow.appendChild(desc);
            textCell.appendChild(descRow);

            var metaRow = document.createElement("div");
            metaRow.className = "package-meta-row";

            var meta = document.createElement("p");
            meta.className = "package-meta";
            meta.textContent = packageVersionPrefixText(pkg);
            metaRow.appendChild(meta);

            var repoName = document.createElement("span");
            repoName.className = "package-meta-repo";
            repoName.textContent = pkg.repo || "?";
            metaRow.appendChild(repoName);

            var verifyCell = document.createElement("span");
            verifyCell.className = "package-repo-verification-cell";

            var verify = document.createElement("img");
            verify.className = "package-repo-verification";
            verify.src = packageRepoVerificationIcon(pkg);
            verify.alt = packageRepoVerificationLabel(pkg);
            verify.width = 28;
            verify.height = 28;
            verifyCell.appendChild(verify);
            metaRow.appendChild(verifyCell);

            textCell.appendChild(metaRow);
        }

        if (pkg.installed) {
            var check = document.createElement("img");
            check.className = "package-check";
            check.src = basePath() + "/assets/checkmark.svg";
            check.alt = "";
            check.width = 54;
            check.height = 54;
            card.appendChild(check);
        }

        card.appendChild(actionBtn);

        return card;
    }

    function signatureValue(value) {
        var text = (value === null || typeof value === "undefined") ? "" : String(value);
        return text.length + ":" + text;
    }

    function packageCardSignature(pkg) {
        var tags = "";
        if (pkg.tags && pkg.tags.length) {
            tags = pkg.tags.join(",");
        }
        var parts = [
            pkg.id || "",
            pkg.name || "",
            pkg.repo || "",
            pkg.version || "",
            pkg.description || "",
            pkg.author || "",
            pkg.icon_url || "",
            pkg.repo_icon_url || "",
            pkg.repo_trust || "",
            pkg.repo_default ? "1" : "0",
            pkg.image_url || "",
            pkg.images ? pkg.images.join(",") : "",
            pkg.featured ? "1" : "0",
            pkg.featured_image || "",
            pkg.installed ? "1" : "0",
            tags
        ];
        var sig = "";
        for (var i = 0; i < parts.length; i++) {
            sig += signatureValue(parts[i]);
        }
        return sig;
    }

    function reconcilePackageCards(container, packages, actionHandler, detailHandler) {
        var existing = {};
        var children = container.children;
        var i;
        for (i = 0; i < children.length; i++) {
            var childKey = children[i].getAttribute("data-package-id");
            if (childKey) existing["pkg:" + childKey] = children[i];
        }

        for (i = 0; i < packages.length; i++) {
            var pkg = packages[i];
            var key = String(pkg.id || pkg.name || i);
            var mapKey = "pkg:" + key;
            var sig = packageCardSignature(pkg);
            var card = existing[mapKey];

            if (!card || card._zenpmPackageSignature !== sig) {
                var newCard = renderPackageCard(pkg, actionHandler, detailHandler);
                newCard.setAttribute("data-package-id", key);
                newCard._zenpmPackageSignature = sig;
                if (card && card.parentNode === container) {
                    container.replaceChild(newCard, card);
                }
                card = newCard;
            }

            if (card.parentNode !== container) {
                container.appendChild(card);
            }

            if (container.children[i] !== card) {
                container.insertBefore(card, container.children[i] || null);
            }

            existing[mapKey] = null;
        }

        for (var oldKey in existing) {
            if (Object.prototype.hasOwnProperty.call(existing, oldKey) && existing[oldKey] && existing[oldKey].parentNode === container) {
                container.removeChild(existing[oldKey]);
            }
        }
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
        REPO_ZENLABS_NAME: REPO_ZENLABS_NAME,
        REPO_ZENLABS_URL: REPO_ZENLABS_URL,
        REPO_KINDLEFORGE_NAME: REPO_KINDLEFORGE_NAME,
        REPO_KINDLEFORGE_URL: REPO_KINDLEFORGE_URL,
        getKindle:       getKindle,
        postLog:         postLog,
        fetchJSON:       fetchJSON,
        fetchText:       fetchText,
        xhrJSON:         xhrJSON,
        xhrText:         xhrText,
        goBack:          goBack,
        daemonUnavailableMessage: daemonUnavailableMessage,
        renderNavbar:    renderNavbar,
        renderMediaCard: renderMediaCard,
        renderPackageCard: renderPackageCard,
        reconcilePackageCards: reconcilePackageCards,
        showBaseModal:   showBaseModal,
        showModal:       showModal,
        showConfirmModal: showConfirmModal,
        showPackageActionConfirm: showPackageActionConfirm,
        showPackageModifyModal: showPackageModifyModal,
        hideModal:       hideModal,
        showAboutModal:  showAboutModal,
        setupPageChrome: setupPageChrome,
        setupCardScroll: setupCardScroll,
        packageDetailsURL: packageDetailsURL
    };
})();
