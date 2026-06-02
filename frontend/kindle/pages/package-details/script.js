(function () {
    var postLog = ZenUtils.postLog;
    var fetchJSON = ZenUtils.fetchJSON;
    var showModal = ZenUtils.showModal;
    var POLL_DELAY = 3500;
    var MAX_POLL_RETRIES = 20;

    var state = {
        pkg: null,
        packages: [],
        busy: false,
        connected: false,
        pendingOp: null
    };

    var el = {
        backBtn: document.getElementById("backBtn"),
        heading: document.getElementById("detailsHeading"),
        hint: document.getElementById("detailsHint"),
        top: document.getElementById("detailsTop"),
        images: document.getElementById("detailsImages"),
        description: document.getElementById("detailsDescription")
    };

    window.onerror = function (msg, src, line) {
        var text = "[details] JS ERROR: " + msg + " (" + (src || "?") + ":" + (line || "?") + ")";
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

    var packageID = queryValue("id");
    var fromTab = queryValue("from") || "search";

    function setBusy(flag, message) {
        state.busy = flag;
        if (message && el.hint) {
            el.hint.textContent = message;
        }
    }

    function findPackage(packages) {
        for (var i = 0; i < packages.length; i++) {
            if (packages[i].id === packageID || packages[i].name === packageID) {
                return packages[i];
            }
        }
        return null;
    }

    function resolveRepoURL(base, value) {
        if (!value) return "";
        if (/^https?:\/\//.test(value) || value.indexOf("file://") === 0) return value;
        return base.replace(/\/+$/, "") + "/" + value.replace(/^\/+/, "");
    }

    function mergeRepoMetadata(pkg, repoPkg, repoURL) {
        if (!pkg || !repoPkg) return pkg;
        if (repoPkg.name) pkg.name = repoPkg.name;
        if (repoPkg.description) pkg.description = repoPkg.description;
        if (repoPkg.author) pkg.author = repoPkg.author;
        if (repoPkg.version) pkg.version = repoPkg.version;
        if (repoPkg.icon_url) pkg.icon_url = resolveRepoURL(repoURL, repoPkg.icon_url);
        if (repoPkg.featured_image) pkg.featured_image = resolveRepoURL(repoURL, repoPkg.featured_image);
        if (repoPkg.featured) pkg.featured = true;
        postLog("[details] merged repo metadata id=" + (pkg.id || "") + " name=" + (pkg.name || "") + " featured_image=" + (pkg.featured_image || "") + " icon_url=" + (pkg.icon_url || ""));
        return pkg;
    }

    function findRepoURL(repos, repoName) {
        for (var i = 0; i < repos.length; i++) {
            if (repos[i].name === repoName) return repos[i].url;
        }
        return "";
    }

    function enrichPackageFromRepoIndex(pkg) {
        if (!pkg || !pkg.repo) return Promise.resolve(pkg);
        return fetchJSON("GET", "/repos", null).then(function (repos) {
            var repoURL = findRepoURL(Array.isArray(repos) ? repos : [], pkg.repo);
            if (!repoURL) throw new Error("repo URL not found for " + pkg.repo);
            return fetch(repoURL.replace(/\/+$/, "") + "/index.json").then(function (resp) {
                postLog("[details] repo index " + repoURL + "/index.json status=" + resp.status);
                if (!resp.ok) throw new Error("repo index unavailable");
                return resp.json();
            }).then(function (idx) {
                var repoPackages = idx && Array.isArray(idx.packages) ? idx.packages : [];
                for (var i = 0; i < repoPackages.length; i++) {
                    if (repoPackages[i].id === pkg.id) {
                        return mergeRepoMetadata(pkg, repoPackages[i], repoURL);
                    }
                }
                return pkg;
            });
        }).catch(function (err) {
            postLog("[details] repo metadata fallback: " + String(err));
            return pkg;
        });
    }

    function loadPackage() {
        return fetchJSON("GET", "/packages?platform=kindle", null).then(function (data) {
            state.packages = Array.isArray(data) ? data : [];
            state.pkg = findPackage(state.packages);
            return enrichPackageFromRepoIndex(state.pkg);
        }).then(function (pkg) {
            state.pkg = pkg;
            renderDetails();
        }).catch(function (err) {
            el.hint.textContent = "Failed to load package.";
            postLog("[details] Error loading package: " + String(err));
        });
    }

    function pollAfterOp() {
        var op = state.pendingOp;
        var attempt = 0;
        function tryPoll() {
            attempt += 1;
            loadPackage().then(function () {
                if (!state.pendingOp || state.pendingOp.id !== op.id) { return; }
                var pkg = state.pkg;
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
            postLog("[details] " + action + " started for " + pkg.id);
            pollAfterOp();
        }).catch(function (err) {
            postLog("[details] Failed to start " + action + ": " + String(err));
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

    function renderImage(url) {
        var wrap = document.createElement("div");
        wrap.className = "details-image-wrap";

        var img = document.createElement("img");
        img.className = "details-image";
        img.alt = "";
        img.src = url;
        img.onerror = function () {
            if (wrap.parentNode) wrap.parentNode.removeChild(wrap);
        };

        wrap.appendChild(img);
        return wrap;
    }

    function renderFeaturedImage(url) {
        var wrap = document.createElement("div");
        wrap.className = "details-featured-image-wrap";
        wrap.style.backgroundImage = "url(\"" + url.replace(/"/g, "%22") + "\")";
        return wrap;
    }

    function renderImages(pkg) {
        el.images.innerHTML = "";
        if (!pkg.images || !pkg.images.length) {
            return;
        }
        for (var i = 0; i < pkg.images.length; i++) {
            el.images.appendChild(renderImage(pkg.images[i]));
        }
    }

    function renderDetails() {
        el.top.innerHTML = "";
        el.images.innerHTML = "";
        el.description.innerHTML = "";

        if (!state.pkg) {
            el.hint.textContent = "Package not found.";
            return;
        }

        el.hint.textContent = "";
        el.heading.textContent = state.pkg.name;
        var card = ZenUtils.renderPackageCard(state.pkg, performPackageAction, null);
        card.className += " package-details-card";
        if (state.pkg.featured_image) {
            card.className += " package-details-card-featured";
            card.insertBefore(renderFeaturedImage(state.pkg.featured_image), card.firstChild);
        }
        el.top.appendChild(card);

        var h = document.createElement("h3");
        h.textContent = "Description";
        el.description.appendChild(h);

        var p = document.createElement("p");
        p.textContent = state.pkg.description || "No description available.";
        el.description.appendChild(p);

        card.appendChild(el.images);
        card.appendChild(el.description);
        renderImages(state.pkg);
    }

    function setupChrome() {
        ZenUtils.setupPageChrome('ZenPM - Package Details', loadPackage);
    }

    function bindEvents() {
        if (el.backBtn) {
            el.backBtn.onclick = function () {
                if (window.history && window.history.length > 1) {
                    window.history.back();
                } else {
                    window.location.href = "../search/index.html";
                }
            };
        }
    }

    var _inited = false;
    function init() {
        if (_inited) return;
        _inited = true;
        bindEvents();
        ZenUtils.renderNavbar(fromTab);
        if (!packageID) {
            el.hint.textContent = "No package selected.";
            return;
        }
        setBusy(true, "Connecting...");
        fetchJSON("GET", "/health", null).then(function () {
            state.connected = true;
            return loadPackage();
        }).then(function () {
            setBusy(false, "");
        }).catch(function (err) {
            setBusy(false, "");
            el.hint.textContent = ZenUtils.daemonUnavailableMessage();
            postLog("[details] Daemon unreachable: " + String(err));
        });
    }

    var _chromeSetup = false;
    function trySetupChrome() {
        if (_chromeSetup) return;
        _chromeSetup = true;
        try { setupChrome(); } catch (_e) { postLog("[details] setupChrome threw: " + _e); }
    }

    var _k = ZenUtils.getKindle();
    if (_k && _k.appmgr) {
        postLog("[details] ongo registered");
        _k.appmgr.ongo = function () {
            postLog("[details] ongo fired");
            trySetupChrome();
            init();
        };
    } else {
        postLog("[details] no appmgr: " + (typeof _k));
    }

    setTimeout(function () { trySetupChrome(); init(); }, 0);
})();
