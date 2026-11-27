// qbt-samba: adds "Samba Shares..." to the stock qBittorrent WebUI
// (Tools menu and toolbar). Loaded from private/index.html.
(function () {
    "use strict";

    function openSamba(e) {
        if (e) { e.preventDefault(); e.stopPropagation(); }
        if (typeof MochaUI === "undefined" || !MochaUI.Window) {
            window.open("samba.html", "_blank");
            return;
        }
        var id = "sambaSharesPage";
        if (document.getElementById(id)) {
            if (MochaUI.focusWindow) MochaUI.focusWindow(document.getElementById(id));
            return;
        }
        new MochaUI.Window({
            id: id,
            title: "Samba Shares",
            loadMethod: "iframe",
            contentURL: "samba.html",
            addClass: "windowFrame",
            scrollbars: true,
            maximizable: false,
            closable: true,
            paddingVertical: 0,
            paddingHorizontal: 0,
            width: Math.min(760, window.innerWidth - 40),
            height: Math.min(620, window.innerHeight - 80)
        });
    }

    function icon(size, cls) {
        var img = document.createElement("img");
        img.src = "images/samba-share.svg";
        img.width = size; img.height = size; img.className = cls; img.alt = "Samba Shares";
        return img;
    }

    function inject() {
        if (document.getElementById("sambaSharesLink")) return;
        var prefs = document.getElementById("preferencesLink");
        if (prefs && prefs.parentNode && prefs.parentNode.parentNode) {
            var li = document.createElement("li");
            var a = document.createElement("a");
            a.id = "sambaSharesLink";
            a.href = "#";
            a.appendChild(icon(16, "MyMenuIcon"));
            a.appendChild(document.createTextNode("Samba Shares..."));
            a.addEventListener("click", openSamba);
            li.appendChild(a);
            prefs.parentNode.parentNode.insertBefore(li, prefs.parentNode.nextSibling);
        }
        var btn = document.getElementById("preferencesButton");
        if (btn && btn.parentNode) {
            var b = document.createElement("a");
            b.id = "sambaSharesButton";
            b.href = "#";
            b.title = "Samba Shares";
            var img = icon(24, "mochaToolButton");
            img.title = "Samba Shares";
            b.appendChild(img);
            b.addEventListener("click", openSamba);
            btn.parentNode.insertBefore(b, btn.nextSibling);
        }
    }

    window.qbtSambaOpen = openSamba;
    if (document.readyState === "loading") {
        document.addEventListener("DOMContentLoaded", inject);
    } else {
        inject();
    }
    // The stock UI can rebuild the toolbar late; try again once it's settled.
    window.addEventListener("load", function () { setTimeout(inject, 500); });
})();
