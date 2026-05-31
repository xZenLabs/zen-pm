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
        ZenUtils.fetchText("GET", "/log?tail=500").then(function (log) {
            var lines = trimTimestamps(log).split("\n");
            lines.reverse();
            el.logOutput.textContent = lines.join("\n") || "Log is empty.";
            el.logOutput.scrollTop = 0;
        }).catch(function (err) {
            el.logOutput.textContent = "Could not read log: " + String(err);
        });
    }

    function setupChrome() {
        ZenUtils.setupPageChrome('ZenPM - Debug', refreshLog);
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
