#!/usr/bin/env bash
# Builds the qBittorrent WebUI with the Samba Shares window added, and turns it
# on as qBittorrent's "alternative WebUI". Called by install.sh.
#
#   install-webui.sh                      download the stock WebUI for the installed version
#   install-webui.sh --www <dir>          use an already extracted src/webui/www folder
#   install-webui.sh --build-only <out>   only build into <out>, don't touch qBittorrent
#   install-webui.sh --disable            switch qBittorrent back to its built-in WebUI
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DEST=/opt/qbt-samba/webui
WWW="${QBT_WEBUI_WWW:-}"   # or set QBT_WEBUI_WWW to an extracted src/webui/www folder
BUILD_ONLY=0
DISABLE=0
PORT="$(python3 -c 'import json;print(json.load(open("/etc/qbt-samba/config.json")).get("listen_port",8099))' 2>/dev/null || echo 8099)"

while [ $# -gt 0 ]; do
  case "$1" in
    --www) WWW="$2"; shift 2 ;;
    --build-only) BUILD_ONLY=1; DEST="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --disable) DISABLE=1; shift ;;
    *) echo "Unknown option $1"; exit 1 ;;
  esac
done

find_qbt() {
  QBT_UNIT="$(systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -i qbittorrent | head -n1 || true)"
  [ -n "$QBT_UNIT" ] || { echo "Couldn't find the qBittorrent service."; exit 1; }
  QBT_BIN="$(systemctl show -p ExecStart --value "$QBT_UNIT" | sed -n 's/.*path=\([^ ;]*\).*/\1/p')"
  [ -x "${QBT_BIN:-}" ] || QBT_BIN="$(command -v qbittorrent-nox || true)"
  QBT_USER="$(systemctl show -p User --value "$QBT_UNIT")"; QBT_USER="${QBT_USER:-root}"
  QBT_HOME="$(getent passwd "$QBT_USER" | cut -d: -f6)"
  QBT_CONF="$QBT_HOME/.config/qBittorrent/qBittorrent.conf"
}

# Set a WebUI setting in qBittorrent.conf (qBittorrent must be stopped).
# qBittorrent 4.x keeps these as [Preferences] WebUI\Key; 5.x moved them to
# [WebUI] Key. Write whichever layout the installed version uses, and drop the
# other spelling so it can't shadow it.
set_webui_pref() {
  local major=""
  [ -x "${QBT_BIN:-}" ] && major="$("$QBT_BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 | cut -d. -f1)"
  python3 - "$QBT_CONF" "$1" "$2" "${major:-}" <<'PY2'
import sys, re
path, key, value, major = sys.argv[1:]
try:
    lines = open(path).read().splitlines()
except FileNotFoundError:
    lines = []
sections = {m.group(1) for l in lines for m in [re.match(r"^\[(.+)\]\s*$", l)] if m}
new_layout = (int(major) >= 5) if major.isdigit() else ("WebUI" in sections)
want_sec, want_key = ("WebUI", key) if new_layout else ("Preferences", "WebUI\\" + key)
drop_sec, drop_key = ("Preferences", "WebUI\\" + key) if new_layout else ("WebUI", key)
out, section, done = [], None, False
def flush():
    global done
    if section == want_sec and not done:
        while out and out[-1] == "":
            out.pop()
        out.append(want_key + "=" + value); out.append(""); done = True
for line in lines:
    m = re.match(r"^\[(.+)\]\s*$", line)
    if m:
        flush()
        section = m.group(1)
    elif "=" in line:
        k = line.split("=", 1)[0]
        if (section == want_sec and k == want_key) or (section == drop_sec and k == drop_key):
            continue
    out.append(line)
flush()
if not done:
    out += ["", "[" + want_sec + "]", want_key + "=" + value]
open(path, "w").write("\n".join(out).rstrip("\n") + "\n")
PY2
}

if [ "$DISABLE" = 1 ]; then
  find_qbt
  systemctl stop "$QBT_UNIT"
  set_webui_pref AlternativeUIEnabled false
  systemctl start "$QBT_UNIT"
  echo "qBittorrent is back on its built-in WebUI."
  exit 0
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

if [ -z "$WWW" ]; then
  find_qbt
  VERSION="$("$QBT_BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"
  [ -n "$VERSION" ] || { echo "Couldn't tell which qBittorrent version is installed."; exit 1; }
  echo "==> Downloading the stock WebUI for qBittorrent $VERSION"
  curl -fsSL "https://github.com/qbittorrent/qBittorrent/archive/refs/tags/release-$VERSION.tar.gz" -o "$TMP/src.tgz"
  tar xzf "$TMP/src.tgz" -C "$TMP" --wildcards "*/src/webui/www/*"
  WWW="$(ls -d "$TMP"/*/src/webui/www)"
fi

[ -f "$WWW/private/index.html" ] && [ -d "$WWW/public" ] || { echo "$WWW doesn't look like a qBittorrent WebUI folder."; exit 1; }

echo "==> Building the WebUI with the Samba Shares window"
STAGE="$TMP/webui"
mkdir -p "$STAGE"
cp -r "$WWW/public" "$WWW/private" "$STAGE/"
cp "$HERE/webui/samba.html" "$STAGE/private/"
mkdir -p "$STAGE/private/scripts" "$STAGE/private/css" "$STAGE/private/images"
cp "$HERE/webui/scripts/samba-tab.js" "$HERE/webui/scripts/samba.js" "$STAGE/private/scripts/"
cp "$HERE/webui/css/samba.css" "$STAGE/private/css/"
cp "$HERE/webui/images/samba-share.svg" "$STAGE/private/images/"
# The source files carry translation markers and placeholders that qBittorrent
# only fills in for its built-in WebUI. Fill them in (English text).
python3 - "$STAGE" "${VERSION:-src}" <<'PY'
import os, re, sys
root, version = sys.argv[1:]
tr = re.compile(r"QBT_TR\((.*?)\)QBT_TR\[CONTEXT=[^\]]*\]")
for d, _, files in os.walk(root):
    for f in files:
        if f.endswith((".html", ".js", ".css")):
            p = os.path.join(d, f)
            s = open(p, encoding="utf-8").read()
            t = tr.sub(lambda m: m.group(1), s)
            t = t.replace("${LANG}", "en").replace("${CACHEID}", "qbt-samba-" + version)
            if t != s:
                open(p, "w", encoding="utf-8").write(t)
PY
sed -i "s/__QBT_SAMBA_PORT__/$PORT/" "$STAGE/private/scripts/samba.js"
grep -q 'samba-tab.js' "$STAGE/private/index.html" || \
  sed -i 's#</head>#    <script src="scripts/samba-tab.js"></script>\n</head>#' "$STAGE/private/index.html"
grep -q 'samba-tab.js' "$STAGE/private/index.html" || { echo "Couldn't add the Samba menu to index.html"; exit 1; }

rm -rf "$DEST.new"; mkdir -p "$(dirname "$DEST")"
cp -r "$STAGE" "$DEST.new"
rm -rf "$DEST"; mv "$DEST.new" "$DEST"
chmod -R a+rX "$DEST"
echo "    built in $DEST"
[ "$BUILD_ONLY" = 1 ] && exit 0

echo "==> Turning on the WebUI in qBittorrent"
[ -n "${QBT_UNIT:-}" ] || find_qbt
systemctl stop "$QBT_UNIT"
set_webui_pref AlternativeUIEnabled true
set_webui_pref RootFolder "$DEST"
systemctl start "$QBT_UNIT"
echo "    done. Reload the WebUI and open Tools > Samba Shares..."
