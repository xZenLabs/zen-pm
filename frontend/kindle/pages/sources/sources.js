(function () {
    var postLog = ZenUtils.postLog;
    var REPO_KINDLEFORGE_NAME = ZenUtils.REPO_KINDLEFORGE_NAME;
    var REPO_KINDLEFORGE_HOST = ZenUtils.REPO_KINDLEFORGE_URL.replace(/^https?:\/\//, "").replace(/\/+$/, "");

    var state = {};

    var cardScroll = null;

    var el = {
        repoList:       document.getElementById("repoList"),
        addSourceBtn:   document.getElementById("addSourceBtn"),
        addSourceModal: document.getElementById("addSourceModal"),
        sourceUrlInput: document.getElementById("sourceUrlInput"),
        confirmAddBtn:  document.getElementById("confirmAddBtn"),
        closeAddBtn:    document.getElementById("closeAddBtn"),
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
        el.confirmAddBtn.disabled = false;
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
                    if (url.indexOf(REPO_KINDLEFORGE_HOST) !== -1) {
                        return REPO_KINDLEFORGE_NAME;
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
        if (repo.name === REPO_KINDLEFORGE_NAME) {
            return "../../assets/kindleforge.svg";
        }
        var base = repo.url.replace(/\/+$/, "");
        return base + "/favicon.svg";
    }

    function repoIsVerified(repo) {
        var trust = repo.trust || "";
        return !!repo.default || trust === "trusted" || trust === "signed";
    }

    function repoVerificationIcon(repo) {
        return repoIsVerified(repo) ? "../../assets/verified.svg" : "../../assets/unverified.svg";
    }

    function repoVerificationLabel(repo) {
        return repoIsVerified(repo) ? "Verified" : "Unverified";
    }

    function sourceDetailsURL(repo) {
        return "../source-details/index.html?name=" + encodeURIComponent(repo.name);
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
                var actionBtn = null;

                if (!r.default) {
                    actionBtn = document.createElement("button");
                    actionBtn.type = "button";
                    actionBtn.className = "repo-action danger";
                    actionBtn.textContent = "Remove";
                    actionBtn.onclick = function (e) {
                        if (e && e.stopPropagation) e.stopPropagation();
                        removeRepo(r.name);
                    };
                }

                var row = ZenUtils.renderMediaCard({
                    tagName: "div",
                    className: "repo-row",
                    imageSrc: repoIconURL(r),
                    imageFallback: "../../assets/sources.svg",
                    title: r.name,
                    line2: r.url,
                    action: actionBtn,
                    clickHandler: function () {
                        if (cardScroll) cardScroll.savePosition();
                        window.location.href = sourceDetailsURL(r);
                    }
                });

                // Inline verification icon after the title, matching source-details pattern
                var titleEl = row.querySelector(".media-card-title");
                if (titleEl) {
                    titleEl.textContent = "";
                    var titleSpan = document.createElement("span");
                    titleSpan.textContent = r.name;
                    titleSpan.style.display = "inline-block";
                    titleSpan.style.verticalAlign = "middle";
                    titleEl.appendChild(titleSpan);

                    // Spacer for breathing room between title and icon
                    var spacer = document.createElement("span");
                    spacer.style.display = "inline-block";
                    spacer.style.width = "6px";
                    titleEl.appendChild(spacer);

                    var verifyIcon = document.createElement("img");
                    verifyIcon.src = repoVerificationIcon(r);
                    verifyIcon.alt = repoVerificationLabel(r);
                    verifyIcon.className = "source-title-verification";
                    verifyIcon.width = 38;
                    verifyIcon.height = 38;
                    titleEl.appendChild(verifyIcon);
                }

                el.repoList.appendChild(row);
            })(repos[_i]);
        }
        if (cardScroll) { cardScroll.rebuild(); cardScroll.restorePosition(); }
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
        el.closeAddBtn.addEventListener("click", hideAddModal);
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
