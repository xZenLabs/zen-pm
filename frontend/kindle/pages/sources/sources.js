(function () {
    var postLog = ZenUtils.postLog;

    var state = {};

    var cardScroll = null;

    var el = {
        repoList:       document.getElementById("repoList"),
        addSourceBtn:   document.getElementById("addSourceBtn"),
        addSourceModal: document.getElementById("addSourceModal"),
        sourceUrlInput: document.getElementById("sourceUrlInput"),
        confirmAddBtn:  document.getElementById("confirmAddBtn"),
        cancelAddBtn:   document.getElementById("cancelAddBtn"),
        addSourceMsg:   document.getElementById("addSourceMsg")
    };

    window.onerror = function (msg, src, line) {
        postLog("[sources.js] JS ERROR: " + msg + " (" + (src || "?") + ":" + (line || "?") + ")");
        return false;
    };

    postLog("[sources.js] script loaded");

    function showAddModal() {
        el.sourceUrlInput.value = "";
        el.addSourceMsg.textContent = "";
        el.addSourceModal.style.display = "";
    }

    function hideAddModal() {
        el.addSourceModal.style.display = "none";
    }

    function addSource() {
        var url = (el.sourceUrlInput.value || "").trim();
        if (!url) {
            el.addSourceMsg.textContent = "Please enter a URL.";
            return;
        }

        el.addSourceMsg.textContent = "Detecting repo...";
        el.confirmAddBtn.disabled = true;

        var base = url.replace(/\/+$/, "") + "/";

        // Try index.json first for ZenPM-format repos.
        fetch(base + "index.json")
            .then(function (resp) {
                if (!resp.ok) throw new Error("no index");
                return resp.text();
            })
            .then(function (text) {
                var data = JSON.parse(text);
                if (data && data.repo && data.repo.name) return data.repo.name;
                throw new Error("no name in index");
            })
            .catch(function () {
                // Fall back to registry.json — KindleForge format.
                return fetch(base + "registry.json").then(function (resp) {
                    if (!resp.ok) throw new Error("no registry");
                    return resp.text();
                }).then(function (text) {
                    var arr = JSON.parse(text);
                    // Only default to "KindleForge" for the known source.
                    if (url.indexOf("penguins184.xyz") !== -1) {
                        return "KindleForge";
                    }
                    if (Array.isArray(arr) && arr.length && arr[0].uri) {
                        return arr[0].uri.split("/")[0];
                    }
                    throw new Error("unknown registry");
                });
            })
            .then(function (name) {
                el.addSourceMsg.textContent = "Adding " + name + "...";
                return ZenUtils.fetchJSON("POST", "/repos", { name: name, url: url });
            })
            .then(function (result) {
                if (result && result.error) {
                    el.addSourceMsg.textContent = "Error: " + result.error;
                    el.confirmAddBtn.disabled = false;
                    return;
                }
                hideAddModal();
                loadRepos();
            })
            .catch(function (err) {
                var msg = (err && err.message) ? err.message : String(err);
                if (msg === "no index" || msg === "no registry" || msg === "unknown registry") {
                    msg = "Could not detect repo format.";
                }
                el.addSourceMsg.textContent = msg;
                el.confirmAddBtn.disabled = false;
            });
    }

    function loadRepos() {
        postLog("[sources.js] loadRepos");
        el.repoList.innerHTML = "<p class='hint'>Loading\u2026</p>";
        ZenUtils.fetchJSON("GET", "/repos", null).then(function (data) {
            renderRepos(Array.isArray(data) ? data : []);
        }).catch(function (err) {
            postLog("[sources.js] loadRepos error: " + String(err));
            el.repoList.innerHTML = "<p class='hint'>Failed to load: " + String(err) + "</p>";
        });
    }

    function repoIconURL(repo) {
        if (repo.name === "KindleForge") {
            return "../../assets/kindleforge.svg";
        }
        var base = repo.url.replace(/\/+$/, "");
        return base + "/favicon.svg";
    }

    function renderRepos(repos) {
        el.repoList.innerHTML = "";
        if (!repos.length) {
            el.repoList.innerHTML = "<p class='hint'>No repositories configured.</p>";
            if (cardScroll) cardScroll.rebuild();
            return;
        }
        for (var _i = 0; _i < repos.length; _i++) {
            (function (r) {
                var row = document.createElement("div");
                row.className = "repo-row";

                var info = document.createElement("div");
                info.className = "repo-info";

                var nameRow = document.createElement("div");
                nameRow.className = "repo-name-row";

                var iconWrap = document.createElement("div");
                iconWrap.className = "repo-icon-wrap";

                var preload = new Image();
                preload.onload = function () {
                    var iconImg = document.createElement("img");
                    iconImg.src = repoIconURL(r);
                    iconImg.alt = "";
                    iconImg.className = "repo-icon";
                    iconImg.width = 64;
                    iconImg.height = 64;
                    iconWrap.appendChild(iconImg);
                };
                preload.onerror = function () {
                    if (preload.src.indexOf('/favicon.svg') !== -1) {
                        preload.src = preload.src.replace('/favicon.svg', '/favicon.ico');
                        return;
                    }
                };
                preload.src = repoIconURL(r);

                nameRow.appendChild(iconWrap);

                var name = document.createElement("strong");
                name.textContent = r.name;
                nameRow.appendChild(name);

                if (r.default) {
                    var defBadge = document.createElement("span");
                    defBadge.className = "badge default-badge";
                    defBadge.textContent = "default";
                    nameRow.appendChild(defBadge);
                } else {
                    var userBadge = document.createElement("span");
                    userBadge.className = "badge user-badge";
                    userBadge.textContent = "user";
                    nameRow.appendChild(userBadge);
                }

                var trustLabel = r.trust || "unknown";
                var trustBadge = document.createElement("span");
                trustBadge.className = "badge trust-badge";
                if (trustLabel === "trusted" || trustLabel === "signed") {
                    trustBadge.className = "badge trust-badge trusted";
                }
                trustBadge.textContent = trustLabel;
                nameRow.appendChild(trustBadge);

                info.appendChild(nameRow);

                var urlEl = document.createElement("div");
                urlEl.className = "repo-url";
                urlEl.textContent = r.url;

                info.appendChild(urlEl);

                var actions = document.createElement("div");
                actions.className = "repo-actions";

                if (!r.default) {
                    var removeBtn = document.createElement("button");
                    removeBtn.type = "button";
                    removeBtn.className = "danger";
                    removeBtn.textContent = "Remove";
                    removeBtn.onclick = function () { removeRepo(r.name); };
                    actions.appendChild(removeBtn);
                }

                row.appendChild(info);
                row.appendChild(actions);
                el.repoList.appendChild(row);
            })(repos[_i]);
        }
        if (cardScroll) cardScroll.rebuild();
    }

    function removeRepo(name) {
        postLog("[sources.js] removeRepo: " + name);
        ZenUtils.fetchJSON("DELETE", "/repos/" + encodeURIComponent(name), null).then(function () {
            loadRepos();
        }).catch(function (err) {
            postLog("[sources.js] removeRepo error: " + String(err));
        });
    }

    function setupChrome() {
        ZenUtils.setupPageChrome('ZenPM - Sources', loadRepos);
    }

    function bindEvents() {
        el.addSourceBtn.addEventListener("click", showAddModal);
        el.confirmAddBtn.addEventListener("click", addSource);
        el.cancelAddBtn.addEventListener("click", hideAddModal);
        el.addSourceModal.addEventListener("click", function (e) {
            if (e.target === el.addSourceModal) hideAddModal();
        });
    }

    var _inited = false;
    function init() {
        if (_inited) return;
        _inited = true;
        postLog("[sources.js] init");
        bindEvents();
        cardScroll = ZenUtils.setupCardScroll(".sources-scroll", "repo-row");
        loadRepos();
    }

    var _chromeSetup = false;
    function trySetupChrome() {
        if (_chromeSetup) return;
        _chromeSetup = true;
        try { setupChrome(); } catch (_e) { postLog("[sources.js] setupChrome threw: " + _e); }
    }

    var _k = ZenUtils.getKindle();
    if (_k && _k.appmgr) {
        postLog("[sources.js] ongo registered");
        _k.appmgr.ongo = function () {
            postLog("[sources.js] ongo fired");
            trySetupChrome();
            init();
        };
    } else {
        postLog("[sources.js] no appmgr: " + (typeof _k));
    }

    setTimeout(function () { trySetupChrome(); init(); }, 0);
})();
