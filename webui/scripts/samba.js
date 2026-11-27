// qbt-samba: the Samba Shares window in the qBittorrent WebUI.
(function () {
    "use strict";

    // The installer replaces this with the configured port.
    var PORT = "__QBT_SAMBA_PORT__";
    if (PORT.indexOf("__") === 0) PORT = "8099";
    var API = location.protocol + "//" + location.hostname + ":" + PORT + "/api";

    var $ = function (id) { return document.getElementById(id); };
    var form = $("shareForm");
    var editing = null; // name of the share being edited, or null when adding

    // ---- HTTP helpers ------------------------------------------------------

    function api(method, path, body) {
        var opts = { method: method, credentials: "include", headers: {} };
        if (body !== undefined) {
            opts.headers["Content-Type"] = "application/json";
            opts.body = JSON.stringify(body);
        }
        return fetch(API + path, opts).then(function (res) {
            return res.json().catch(function () { return {}; }).then(function (data) {
                if (!res.ok) throw new Error(data.error || ("Request failed (" + res.status + ")"));
                return data;
            });
        }, function () {
            throw new Error("Can't reach the Samba service on port " + PORT +
                ". Check it's running: systemctl status qbt-samba");
        });
    }

    // Calls qBittorrent's own API (same origin as this page).
    function qbt(path, params) {
        return fetch("api/v2/" + path, {
            method: "POST",
            credentials: "same-origin",
            headers: { "Content-Type": "application/x-www-form-urlencoded" },
            body: new URLSearchParams(params).toString()
        }).then(function (res) {
            if (!res.ok) return res.text().then(function (t) { throw Object.assign(new Error(t || res.statusText), { status: res.status }); });
        });
    }

    // ---- UI helpers --------------------------------------------------------

    function el(tag, attrs, children) {
        var node = document.createElement(tag);
        Object.keys(attrs || {}).forEach(function (k) {
            if (k === "onclick") node.addEventListener("click", attrs[k]);
            else if (k === "text") node.textContent = attrs[k];
            else node.setAttribute(k, attrs[k]);
        });
        (children || []).forEach(function (c) { if (c) node.appendChild(typeof c === "string" ? document.createTextNode(c) : c); });
        return node;
    }

    function banner(message, kind) {
        var b = $("banner");
        if (!message) { b.hidden = true; return; }
        b.textContent = message;
        b.className = "banner" + (kind ? " " + kind : "");
        b.hidden = false;
    }

    function result(message, ok) {
        var r = $("formResult");
        if (!message) { r.hidden = true; return; }
        r.textContent = message;
        r.className = "result " + (ok ? "ok" : "bad");
        r.hidden = false;
    }

    function busy(button, on, label) {
        if (on) { button.dataset.label = button.textContent; button.textContent = label; button.disabled = true; }
        else { button.textContent = button.dataset.label || button.textContent; button.disabled = false; }
    }

    // ---- Shares table ------------------------------------------------------

    function load() {
        return api("GET", "/shares").then(function (data) {
            banner(null);
            render(data.shares);
        }).catch(function (e) {
            banner(e.message);
            $("sharesBody").replaceChildren(el("tr", {}, [el("td", { colspan: "4", class: "muted", text: "Couldn't load shares." })]));
        });
    }

    function render(shares) {
        var body = $("sharesBody");
        if (!shares.length) {
            body.replaceChildren(el("tr", {}, [el("td", { colspan: "4", class: "muted", text: "No shares yet. Add one to start saving downloads to it." })]));
            return;
        }
        body.replaceChildren.apply(body, shares.map(row));
    }

    function row(s) {
        var status = s.mounted ? el("span", { class: "status on", text: "Mounted" })
            : s.error ? el("span", { class: "status bad", text: "Error" })
                : el("span", { class: "status off", text: s.enabled ? "Not mounted" : "Off" });

        var actions = el("td", { class: "row-actions" }, [
            s.mounted
                ? el("button", { type: "button", class: "link", text: "Unmount", onclick: function (e) { act(e.target, "unmount", s.name); } })
                : el("button", { type: "button", class: "link", text: "Mount", onclick: function (e) { act(e.target, "mount", s.name); } }),
            el("button", { type: "button", class: "link", text: "Use for downloads", title: "Make this share qBittorrent's default save folder", onclick: function (e) { useAsDefault(e.target, s); } }),
            el("button", { type: "button", class: "link", text: "Add category", title: "Create a category that saves to this share", onclick: function (e) { addCategory(e.target, s); } }),
            el("button", { type: "button", class: "link", text: "Edit", onclick: function () { openForm(s); } }),
            el("button", { type: "button", class: "link danger", text: "Remove", onclick: function (e) { remove(e.target, s.name); } })
        ]);

        return el("tr", {}, [
            el("td", {}, [el("strong", { text: s.name }), el("small", { class: "path", text: s.path })]),
            el("td", { class: "addr" }, ["//" + s.server + "/" + s.share, el("small", { text: "as " + s.username })]),
            el("td", {}, [status, s.error ? el("div", { class: "error", text: s.error }) : null]),
            actions
        ]);
    }

    function act(button, action, name) {
        busy(button, true, action === "mount" ? "Mounting..." : "Unmounting...");
        api("POST", "/shares/" + encodeURIComponent(name) + "/" + action)
            .then(load)
            .catch(function (e) { banner(e.message); busy(button, false); });
    }

    function remove(button, name) {
        if (button.dataset.confirm !== "1") {
            button.dataset.confirm = "1";
            button.textContent = "Click again to remove";
            setTimeout(function () { button.dataset.confirm = ""; button.textContent = "Remove"; }, 4000);
            return;
        }
        busy(button, true, "Removing...");
        api("DELETE", "/shares/" + encodeURIComponent(name))
            .then(load)
            .catch(function (e) { banner(e.message); busy(button, false); });
    }

    function useAsDefault(button, s) {
        if (!s.mounted) { banner("Mount " + s.name + " first, so downloads don't fail."); return; }
        busy(button, true, "Saving...");
        qbt("app/setPreferences", { json: JSON.stringify({ save_path: s.path }) })
            .then(function () { banner("New downloads now save to " + s.path + " by default.", "info"); })
            .catch(function (e) { banner("Couldn't change the default save folder: " + e.message); })
            .then(function () { busy(button, false); });
    }

    function addCategory(button, s) {
        busy(button, true, "Adding...");
        var params = { category: s.name, savePath: s.path };
        fetch("api/v2/torrents/categories", { credentials: "same-origin" })
            .then(function (res) { return res.ok ? res.json() : {}; })
            .then(function (cats) {
                var cur = cats[s.name];
                if (!cur) return qbt("torrents/createCategory", params);
                if ((cur.savePath || "").replace(/\/+$/, "") === s.path) return;
                return qbt("torrents/editCategory", params);
            })
            .then(function () { banner("Category \"" + s.name + "\" now saves to " + s.path + ".", "info"); })
            .catch(function (e) { banner("Couldn't create the category: " + e.message); })
            .then(function () { busy(button, false); });
    }

    // ---- Add / edit form ---------------------------------------------------

    function openForm(share) {
        editing = share ? share.name : null;
        form.reset();
        result(null);
        $("formTitle").textContent = share ? "Edit " + share.name : "Add share";
        form.elements.name.disabled = !!share;
        form.elements.password.required = !share;
        $("passwordHint").textContent = share ? "Leave blank to keep the saved password." : "Required.";
        if (share) {
            ["name", "server", "share", "username"].forEach(function (k) { form.elements[k].value = share[k]; });
            form.elements.version.value = share.version || "";
        }
        $("formSection").hidden = false;
        (share ? form.elements.server : form.elements.name).focus();
    }

    function closeForm() {
        $("formSection").hidden = true;
        editing = null;
    }

    function formData() {
        var d = {};
        ["name", "server", "share", "username", "password", "version"].forEach(function (k) { d[k] = form.elements[k].value.trim(); });
        d.password = form.elements.password.value; // passwords may have spaces
        if (editing) d.name = editing;
        return d;
    }

    $("addBtn").addEventListener("click", function () { openForm(null); });
    $("cancelBtn").addEventListener("click", closeForm);

    $("testBtn").addEventListener("click", function () {
        var button = $("testBtn");
        result(null);
        busy(button, true, "Testing...");
        api("POST", "/test", formData())
            .then(function (r) { result(r.message, r.ok); })
            .catch(function (e) { result(e.message, false); })
            .then(function () { busy(button, false); });
    });

    form.addEventListener("submit", function (e) {
        e.preventDefault();
        if (!form.reportValidity()) return;
        var button = $("saveBtn");
        var data = formData();
        result(null);
        busy(button, true, "Saving...");
        var req = editing ? api("PUT", "/shares/" + encodeURIComponent(editing), data) : api("POST", "/shares", data);
        req.then(function (s) {
            if (s.mounted || !s.enabled) { closeForm(); }
            else { result("Saved, but it didn't mount: " + (s.error || "unknown error"), false); editing = s.name; form.elements.name.disabled = true; }
            return load();
        }).catch(function (e) { result(e.message, false); })
            .then(function () { busy(button, false); });
    });

    load();
    setInterval(load, 15000);
})();
