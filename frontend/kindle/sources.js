(function () {
    var postLog = ZenUtils.postLog;

    var state = { editingName: null };

    var el = {
        repoList:      document.getElementById("repoList"),
        repoName:      document.getElementById("repoName"),
        repoURL:       document.getElementById("repoURL"),
        repoPriority:  document.getElementById("repoPriority"),
        saveRepoBtn:   document.getElementById("saveRepoBtn"),
        cancelEditBtn: document.getElementById("cancelEditBtn"),
        repoStatus:    document.getElementById("repoStatus"),
        formTitle:     document.getElementById("formTitle")
    };

    window.onerror = function (msg, src, line) {
        postLog("[sources.js] JS ERROR: " + msg + " (" + (src || "?") + ":" + (line || "?") + ")");
        return false;
    };

    postLog("[sources.js] script loaded");

    function setStatus(msg, isError) {
        el.repoStatus.textContent = msg;
        el.repoStatus.style.color = isError ? "var(--danger)" : "";
    }

    function loadRepos() {
        postLog("[sources.js] loadRepos");
        el.repoList.innerHTML = "<p class='hint'>Loading\u2026</p>";
        ZenUtils.xhrJSON("GET", "/repos", null,
            function (data) { renderRepos(Array.isArray(data) ? data : []); },
            function (err) {
                postLog("[sources.js] loadRepos error: " + String(err));
                el.repoList.innerHTML = "<p class='hint'>Failed to load: " + String(err) + "</p>";
            }
        );
    }

    function renderRepos(repos) {
        el.repoList.innerHTML = "";
        if (!repos.length) {
            el.repoList.innerHTML = "<p class='hint'>No repositories configured.</p>";
            return;
        }
        for (var _i = 0; _i < repos.length; _i++) {
            (function (r) {
                var row = document.createElement("div");
                row.className = "repo-row";

                var info = document.createElement("div");
                info.className = "repo-info";

                var name = document.createElement("strong");
                name.textContent = r.name;

                var urlEl = document.createElement("div");
                urlEl.className = "repo-url";
                urlEl.textContent = r.url;

                var meta = document.createElement("div");
                meta.className = "repo-meta";
                meta.textContent = "priority: " + r.priority + " \u2022 trust: " + r.trust;

                info.appendChild(name);
                info.appendChild(urlEl);
                info.appendChild(meta);

                var actions = document.createElement("div");
                actions.className = "repo-actions";

                var editBtn = document.createElement("button");
                editBtn.type = "button";
                editBtn.className = "warn";
                editBtn.textContent = "Edit";
                editBtn.onclick = function () { startEdit(r); };

                var removeBtn = document.createElement("button");
                removeBtn.type = "button";
                removeBtn.className = "danger";
                removeBtn.textContent = "Remove";
                removeBtn.onclick = function () { removeRepo(r.name); };

                actions.appendChild(editBtn);
                actions.appendChild(removeBtn);
                row.appendChild(info);
                row.appendChild(actions);
                el.repoList.appendChild(row);
            })(repos[_i]);
        }
    }

    function startEdit(r) {
        postLog("[sources.js] startEdit: " + r.name);
        state.editingName = r.name;
        el.repoName.value = r.name;
        el.repoName.disabled = true; // name is the key, cannot be changed
        el.repoURL.value = r.url;
        el.repoPriority.value = r.priority;
        el.formTitle.textContent = "Edit Repository";
        el.saveRepoBtn.textContent = "Save Changes";
        el.cancelEditBtn.style.display = "";
        setStatus("");
        el.repoURL.focus();
    }

    function cancelEdit() {
        state.editingName = null;
        el.repoName.disabled = false;
        el.repoName.value = "";
        el.repoURL.value = "";
        el.repoPriority.value = "100";
        el.formTitle.textContent = "Add Repository";
        el.saveRepoBtn.textContent = "Add Repository";
        el.cancelEditBtn.style.display = "none";
        setStatus("");
    }

    function saveRepo() {
        var name = (el.repoName.value || "").trim();
        var url = (el.repoURL.value || "").trim();
        var priority = parseInt(el.repoPriority.value, 10);
        if (isNaN(priority) || priority < 0) priority = 100;

        if (!name || !url) { setStatus("Name and URL are required.", true); return; }

        postLog("[sources.js] saveRepo: " + (state.editingName ? "PUT " + state.editingName : "POST " + name));
        setStatus("Saving\u2026");
        el.saveRepoBtn.disabled = true;

        function onDone() { el.saveRepoBtn.disabled = false; cancelEdit(); loadRepos(); }
        function onFail(err) {
            postLog("[sources.js] saveRepo error: " + String(err));
            el.saveRepoBtn.disabled = false;
            setStatus("Error: " + String(err), true);
        }

        if (state.editingName) {
            ZenUtils.xhrJSON("PUT", "/repos/" + encodeURIComponent(state.editingName),
                { url: url, priority: priority, trust: "warn-unsigned" },
                function () { setStatus("Saved."); onDone(); },
                onFail
            );
        } else {
            ZenUtils.xhrJSON("POST", "/repos",
                { name: name, url: url, priority: priority, trust: "warn-unsigned" },
                function () { setStatus("Added."); onDone(); },
                onFail
            );
        }
    }

    function removeRepo(name) {
        postLog("[sources.js] removeRepo: " + name);
        ZenUtils.xhrJSON("DELETE", "/repos/" + encodeURIComponent(name), null,
            function () { loadRepos(); },
            function (err) {
                postLog("[sources.js] removeRepo error: " + String(err));
                setStatus("Error: " + String(err), true);
            }
        );
    }

    function setupChrome() {
        var k = ZenUtils.getKindle();
        postLog("[sources.js] setupChrome: kindle=" + (k ? "yes" : "no") + " messaging=" + (k && k.messaging ? "yes" : "no"));
        if (!k || !k.messaging) return;

        var systemMenu = {
            "clientParams": {
                "profile": {
                    "name": "default",
                    "items": [
                        { "id": "ZENREPO_REFRESH", "state": "enabled", "handling": "notifyApp", "label": "Refresh", "position": 0 }
                    ],
                    "selectionMode": "none",
                    "closeOnUse": true
                }
            }
        };

        k.messaging.receiveMessage("systemMenuItemSelected", function (property, data) {
            postLog("[sources.js] systemMenuItemSelected: p=" + property + " d=" + data);
            if (data === "ZENREPO_REFRESH") loadRepos();
        });

        if (k.chrome && k.chrome.isDecanterChromeEnabled) {
            postLog("[sources.js] setupChrome: decanter (KPP)");
            k.messaging.sendMessage("com.lab126.chromebar", "configureChrome", {
                "appId": ZenUtils.APP_ID,
                "topNavBar": {
                    "template": "title",
                    "title": "Zen PM - Sources",
                    "buttons": [
                        { "id": "KPP_MORE",  "state": "enabled", "handling": "system" },
                        { "id": "KPP_CLOSE", "state": "enabled", "handling": "system" }
                    ]
                },
                "systemMenu": systemMenu
            });
        } else {
            postLog("[sources.js] setupChrome: pillow");
            k.messaging.sendMessage("com.lab126.pillow", "configureChrome", {
                "appId": ZenUtils.APP_ID,
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

    function bindEvents() {
        el.saveRepoBtn.addEventListener("click", saveRepo);
        el.cancelEditBtn.addEventListener("click", cancelEdit);
    }

    var _inited = false;
    function init() {
        if (_inited) return;
        _inited = true;
        postLog("[sources.js] init");
        bindEvents();
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

    // Also attempt chrome setup at load time — ongo may not re-fire on sub-page navigation.
    setTimeout(function () { trySetupChrome(); init(); }, 0);
})();
