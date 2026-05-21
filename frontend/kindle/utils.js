// Shared WAF utilities — loaded before every page script.
var ZenUtils = (function () {
    var API    = "http://127.0.0.1:8080";
    var APP_ID = "com.zenpm.waf";

    function getKindle() {
        try { return window.kindle || top.kindle; } catch (_e) { return window.kindle; }
    }

    // Fire-and-forget POST to /log/client — bridges WAF diagnostics into zenpm.log.
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

    // Navigate back to index — same mechanism as forward navigation from index.
    function goBack() {
        window.location.href = "index.html";
    }

    return {
        API:        API,
        APP_ID:     APP_ID,
        getKindle:  getKindle,
        postLog:    postLog,
        xhrJSON:    xhrJSON,
        xhrText:    xhrText,
        goBack:     goBack
    };
})();
