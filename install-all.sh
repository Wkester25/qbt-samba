#!/usr/bin/env bash
# qBittorrent stack installer: qBittorrent-nox + a torrent indexer (Jackett or
# Prowlarr) + the qbt-samba Samba Shares add-on, in one go.
#
# Run as root inside a Debian or Ubuntu LXC/VM, from the extracted qbt-samba folder:
#   bash install-all.sh                  ask a few questions (sensible defaults)
#   bash install-all.sh -y               take every default, no questions
#
# Options (all optional, also settable as environment variables):
#   -y, --yes                 unattended: use defaults / environment values
#   --indexer NAME            jackett (default), prowlarr, both or none   [INDEXER]
#   --no-samba                skip the Samba Shares add-on                [SAMBA=no]
#   --webui-user NAME         qBittorrent WebUI username (admin)          [QBT_WEBUI_USER]
#   --webui-pass PASS         WebUI password (random if not given)        [QBT_WEBUI_PASS]
#   --webui-port PORT         WebUI port (8090)                           [QBT_WEBUI_PORT]
#   --downloads DIR           default save folder (/srv/downloads)        [DOWNLOAD_DIR]
#   --qbt-tag TAG             qbittorrent-nox-static release tag to pin,
#                             e.g. release-5.0.3_v2.0.11 (latest)         [QBT_TAG]
#
# Safe to run again: anything already installed is kept and its settings are
# left alone. An existing qBittorrent service (for example one made by the
# community-scripts qBittorrent LXC) is detected and reused.
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG=/var/log/qbt-stack-install.log

# ----------------------------------------------------------------- defaults
ASSUME_YES=0
INDEXER="${INDEXER:-jackett}"
SAMBA="${SAMBA:-yes}"
QBT_WEBUI_USER="${QBT_WEBUI_USER:-admin}"
QBT_WEBUI_PASS="${QBT_WEBUI_PASS:-}"
QBT_WEBUI_PORT="${QBT_WEBUI_PORT:-8090}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-/srv/downloads}"
QBT_TAG="${QBT_TAG:-}"

QBT_SVC_USER=qbittorrent
QBT_DIR=/opt/qbittorrent
QBT_UNIT=qbittorrent-nox.service
JACKETT_PORT=9117
PROWLARR_PORT=9696
JACKETT_API_KEY=""
PASS_WAS_SET=0

# ------------------------------------------------------------------ styling
if [ -t 1 ]; then
  RD=$'\e[01;31m'; GN=$'\e[1;92m'; YW=$'\e[33m'; BL=$'\e[36m'; BLD=$'\e[1m'; CL=$'\e[m'
  BOL=$'\r\e[K'
else
  RD=""; GN=""; YW=""; BL=""; BLD=""; CL=""; BOL=""
fi
CM="${GN}✓${CL}"; CROSS="${RD}✗${CL}"; INFO="${YW}…${CL}"

header() {
  [ -t 1 ] && { clear 2>/dev/null || true; }
  cat <<EOF
${BL}
   ┌──────────────────────────────────────────────────────────────┐
   │   qBittorrent stack                                          │
   │   qBittorrent-nox  +  Jackett / Prowlarr  +  Samba Shares    │
   └──────────────────────────────────────────────────────────────┘
${CL}
EOF
}

msg_info()  { [ -n "$BOL" ] && printf ' %s %s' "$INFO" "$1"; return 0; }
msg_ok()    { printf '%s %s %s\n' "$BOL" "$CM" "$1"; }
msg_warn()  { printf ' %s%s%s\n' "$YW" "! $1" "$CL"; }
msg_error() { printf '%s %s %s%s%s\n' "$BOL" "$CROSS" "$RD" "$1" "$CL"; }

# run "message" command...   output goes to the log; the log tail is shown on failure
run() {
  local m="$1"; shift
  msg_info "$m"
  echo "### $m: $*" >>"$LOG"
  if "$@" >>"$LOG" 2>&1; then
    msg_ok "$m"
  else
    msg_error "$m failed. Last lines of $LOG:"
    tail -n 15 "$LOG" | sed 's/^/     /'
    exit 1
  fi
}

on_error() {
  local code=$? line=$1
  msg_error "Stopped at line $line (exit $code). Full log: $LOG"
  exit "$code"
}
trap 'on_error $LINENO' ERR

die() { msg_error "$1"; exit 1; }

# ---------------------------------------------------------------- arguments
usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }
while [ $# -gt 0 ]; do
  case "$1" in
    -y|--yes) ASSUME_YES=1; shift ;;
    --indexer) INDEXER="$2"; shift 2 ;;
    --no-samba) SAMBA=no; shift ;;
    --webui-user) QBT_WEBUI_USER="$2"; shift 2 ;;
    --webui-pass) QBT_WEBUI_PASS="$2"; shift 2 ;;
    --webui-port) QBT_WEBUI_PORT="$2"; shift 2 ;;
    --downloads) DOWNLOAD_DIR="$2"; shift 2 ;;
    --qbt-tag) QBT_TAG="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) die "Unknown option: $1 (try --help)" ;;
  esac
done

# ------------------------------------------------------------- ask helpers
INTERACTIVE=1
{ [ "$ASSUME_YES" = 1 ] || ! [ -t 0 ]; } && INTERACTIVE=0
USE_WHIPTAIL=0
[ "$INTERACTIVE" = 1 ] && command -v whiptail >/dev/null 2>&1 && USE_WHIPTAIL=1
TITLE="qBittorrent stack installer"

# ask_input VAR "question" default
ask_input() {
  local __var="$1" q="$2" def="$3" ans
  if [ "$USE_WHIPTAIL" = 1 ]; then
    ans="$(whiptail --title "$TITLE" --inputbox "$q" 10 70 "$def" 3>&1 1>&2 2>&3)" || exit 1
  else
    read -r -p " $q [$def]: " ans || true
  fi
  printf -v "$__var" '%s' "${ans:-$def}"
}

# ask_secret VAR "question"   (empty answer keeps the current value)
ask_secret() {
  local __var="$1" q="$2" ans
  if [ "$USE_WHIPTAIL" = 1 ]; then
    ans="$(whiptail --title "$TITLE" --passwordbox "$q" 10 70 3>&1 1>&2 2>&3)" || exit 1
  else
    read -r -s -p " $q: " ans || true; echo
  fi
  [ -n "$ans" ] && printf -v "$__var" '%s' "$ans"
  return 0
}

# ask_yesno "question" default(yes|no) -> returns 0 for yes
ask_yesno() {
  local q="$1" def="$2" ans
  if [ "$USE_WHIPTAIL" = 1 ]; then
    if [ "$def" = yes ]; then whiptail --title "$TITLE" --yesno "$q" 10 70
    else whiptail --title "$TITLE" --defaultno --yesno "$q" 10 70; fi
    return
  fi
  read -r -p " $q [$([ "$def" = yes ] && echo Y/n || echo y/N)]: " ans || true
  ans="${ans:-$def}"
  [[ "$ans" =~ ^[Yy] ]]
}

# ask_indexer -> sets INDEXER
ask_indexer() {
  if [ "$USE_WHIPTAIL" = 1 ]; then
    INDEXER="$(whiptail --title "$TITLE" --default-item "$INDEXER" --menu \
      "Torrent search tool to install" 15 78 4 \
      jackett  "Jackett - plugs straight into qBittorrent's Search tab (recommended)" \
      prowlarr "Prowlarr - for Sonarr/Radarr users; not wired into qBittorrent Search" \
      both     "Both" \
      none     "Neither" 3>&1 1>&2 2>&3)" || exit 1
  else
    echo " Torrent search tool: jackett (recommended, shows up in qBittorrent's Search tab),"
    echo "                      prowlarr (for Sonarr/Radarr), both, or none"
    ask_input INDEXER "Which one" "$INDEXER"
  fi
}

# ------------------------------------------------------------------- checks
preflight() {
  [ "$(id -u)" -eq 0 ] || die "Run this as root."
  # shellcheck disable=SC1091
  [ -r /etc/os-release ] && . /etc/os-release
  case "${ID:-}:${ID_LIKE:-}" in
    debian:*|ubuntu:*|*:*debian*) ;;
    *) die "This installer supports Debian and Ubuntu only (found ${PRETTY_NAME:-unknown})." ;;
  esac
  [ -d /run/systemd/system ] || die "systemd isn't running here. This installer needs systemd."
  case "$(uname -m)" in
    x86_64) QBT_ARCH=x86_64; JACKETT_ARCH=LinuxAMDx64; PROWLARR_ARCH=x64 ;;
    aarch64) QBT_ARCH=aarch64; JACKETT_ARCH=LinuxARM64; PROWLARR_ARCH=arm64 ;;
    armv7l) QBT_ARCH=armv7; JACKETT_ARCH=LinuxARM32; PROWLARR_ARCH=arm ;;
    *) die "Unsupported CPU type $(uname -m)." ;;
  esac
  case "$INDEXER" in jackett|prowlarr|both|none) ;; *) die "--indexer must be jackett, prowlarr, both or none." ;; esac
  [[ "$QBT_WEBUI_PORT" =~ ^[0-9]+$ ]] || die "WebUI port must be a number."
  : >>"$LOG"; chmod 600 "$LOG"
}

existing_qbt_unit() {
  systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -i qbittorrent | head -n1 || true
}

is_unprivileged_lxc() {
  awk '$1==0 && $2!=0 {exit 0} END{exit 1}' /proc/self/uid_map 2>/dev/null
}

gather_settings() {
  local existing; existing="$(existing_qbt_unit)"
  if [ "$INTERACTIVE" = 1 ]; then
    if [ -n "$existing" ]; then
      ask_yesno "qBittorrent is already installed ($existing). Keep it and add the search tool and Samba Shares to it?" yes \
        || die "Stopped. Nothing was changed."
    else
      ask_input QBT_WEBUI_USER "qBittorrent WebUI username" "$QBT_WEBUI_USER"
      ask_secret QBT_WEBUI_PASS "qBittorrent WebUI password (leave empty for a random one)"
      ask_input QBT_WEBUI_PORT "qBittorrent WebUI port" "$QBT_WEBUI_PORT"
      ask_input DOWNLOAD_DIR "Default download folder" "$DOWNLOAD_DIR"
    fi
    ask_indexer
    if ask_yesno "Install the Samba Shares add-on (save downloads to network shares)?" "$SAMBA"; then SAMBA=yes; else SAMBA=no; fi
  fi
  if [ "$SAMBA" = yes ] && is_unprivileged_lxc; then
    msg_warn "This is an unprivileged LXC, so Samba shares can't be mounted yet."
    msg_warn "The add-on installs anyway; see README.md 'Proxmox setup' to switch the LXC to privileged."
    if [ "$INTERACTIVE" = 1 ]; then
      ask_yesno "Continue anyway?" yes || die "Stopped. Nothing was changed."
    fi
  fi
  if [ "$SAMBA" = yes ] && [ ! -f "$HERE/install.sh" ]; then
    die "Samba Shares needs the rest of the qbt-samba folder next to this script (install.sh not found in $HERE)."
  fi
  if [ -z "$QBT_WEBUI_PASS" ]; then
    QBT_WEBUI_PASS="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16 || true)"
  else
    PASS_WAS_SET=1
  fi
}

# ------------------------------------------------------------- base packages
install_base() {
  export DEBIAN_FRONTEND=noninteractive
  run "Updating package lists" apt-get update
  run "Installing curl, python3 and tools" apt-get install -y --no-install-recommends \
    curl ca-certificates python3 tar gzip procps
}

# The ICU runtime package is versioned per release (libicu72, libicu74, ...).
icu_pkg() { apt-cache pkgnames libicu | grep -E '^libicu[0-9]+$' | sort -V | tail -n1; }

download() { curl -fsSL --retry 3 --retry-delay 2 -o "$2" "$1"; }

# wait_for_url URL seconds
wait_for_url() {
  local i
  for ((i = 0; i < $2; i++)); do
    curl -s -o /dev/null --max-time 2 "$1" && return 0
    sleep 1
  done
  return 1
}

# ---------------------------------------------------------------- qBittorrent
qbt_password_hash() {
  python3 - "$1" <<'PY'
import base64, hashlib, os, sys
salt = os.urandom(16)
key = hashlib.pbkdf2_hmac("sha512", sys.argv[1].encode(), salt, 100000, 64)
print("@ByteArray(%s:%s)" % (base64.b64encode(salt).decode(), base64.b64encode(key).decode()))
PY
}

install_qbittorrent() {
  QBT_UNIT_FOUND="$(existing_qbt_unit)"
  if [ -n "$QBT_UNIT_FOUND" ]; then
    QBT_UNIT="$QBT_UNIT_FOUND"
    QBT_SVC_USER="$(systemctl show -p User --value "$QBT_UNIT")"; QBT_SVC_USER="${QBT_SVC_USER:-root}"
    local conf; conf="$(qbt_conf)"
    QBT_WEBUI_PORT="$(qbt_webui_pref "$conf" Port)"
    QBT_WEBUI_PORT="${QBT_WEBUI_PORT:-8080}"
    QBT_EXISTING=1
    msg_ok "Using the existing qBittorrent ($QBT_UNIT, runs as $QBT_SVC_USER, WebUI port $QBT_WEBUI_PORT)"
    systemctl is-active --quiet "$QBT_UNIT" || run "Starting qBittorrent" systemctl start "$QBT_UNIT"
    return
  fi
  QBT_EXISTING=0

  if ! id "$QBT_SVC_USER" >/dev/null 2>&1; then
    run "Creating the $QBT_SVC_USER user" useradd --system --create-home --home-dir /var/lib/qbittorrent \
      --shell /usr/sbin/nologin "$QBT_SVC_USER"
  fi
  local url="https://github.com/userdocs/qbittorrent-nox-static/releases/latest/download/${QBT_ARCH}-qbittorrent-nox"
  [ -n "$QBT_TAG" ] && url="https://github.com/userdocs/qbittorrent-nox-static/releases/download/${QBT_TAG}/${QBT_ARCH}-qbittorrent-nox"
  install -d -m 755 "$QBT_DIR"
  run "Downloading qBittorrent-nox${QBT_TAG:+ ($QBT_TAG)}" download "$url" "$QBT_DIR/qbittorrent-nox.new"
  chmod 755 "$QBT_DIR/qbittorrent-nox.new"
  mv -f "$QBT_DIR/qbittorrent-nox.new" "$QBT_DIR/qbittorrent-nox"
  QBT_VERSION="$("$QBT_DIR/qbittorrent-nox" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
  [ -n "$QBT_VERSION" ] || die "The downloaded qbittorrent-nox doesn't run on this system."
  msg_ok "qBittorrent-nox $QBT_VERSION installed in $QBT_DIR"

  local conf; conf="$(qbt_conf)"
  install -d -o "$QBT_SVC_USER" -g "$QBT_SVC_USER" -m 755 "$DOWNLOAD_DIR"
  if [ ! -f "$conf" ]; then
    install -d -o "$QBT_SVC_USER" -g "$QBT_SVC_USER" -m 700 "$(dirname "$conf")"
    local hash; hash="$(qbt_password_hash "$QBT_WEBUI_PASS")"
    cat >"$conf" <<CONF
[LegalNotice]
Accepted=true

[BitTorrent]
Session\DefaultSavePath=$DOWNLOAD_DIR
Session\TempPathEnabled=false

[Preferences]
Downloads\SavePath=$DOWNLOAD_DIR/
Downloads\TempPathEnabled=false
WebUI\Port=$QBT_WEBUI_PORT
WebUI\Username=$QBT_WEBUI_USER
WebUI\Password_PBKDF2="$hash"
WebUI\LocalHostAuth=true
WebUI\UseUPnP=false
CONF
    chown "$QBT_SVC_USER:$QBT_SVC_USER" "$conf"; chmod 600 "$conf"
    QBT_NEW_CONF=1
    msg_ok "Wrote qBittorrent settings (WebUI port $QBT_WEBUI_PORT, downloads in $DOWNLOAD_DIR)"
  else
    QBT_NEW_CONF=0
    msg_ok "Keeping existing qBittorrent settings in $conf"
  fi

  cat >"/etc/systemd/system/$QBT_UNIT" <<UNIT
[Unit]
Description=qBittorrent-nox
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=$QBT_SVC_USER
Group=$QBT_SVC_USER
UMask=0002
ExecStart=$QBT_DIR/qbittorrent-nox
Restart=on-failure
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  run "Starting qBittorrent" systemctl enable --now "$QBT_UNIT"
  wait_for_url "http://127.0.0.1:$QBT_WEBUI_PORT/" 30 || die "qBittorrent's WebUI didn't come up. See: journalctl -u $QBT_UNIT"
  msg_ok "qBittorrent WebUI is answering on port $QBT_WEBUI_PORT"
}

# Read a WebUI setting: [WebUI] Key (qBittorrent 5.x) or [Preferences] WebUI\Key (4.x).
qbt_webui_pref() {
  python3 - "$1" "$2" <<'PY' 2>/dev/null || true
import re, sys
path, key = sys.argv[1:]
section, found = None, {}
for line in open(path, encoding="utf-8", errors="replace"):
    line = line.rstrip("\r\n")
    m = re.match(r"^\[(.+)\]\s*$", line)
    if m:
        section = m.group(1); continue
    k, _, v = line.partition("=")
    if (section, k) in (("WebUI", key), ("Preferences", "WebUI\\" + key)):
        found[section] = v
print(found.get("WebUI", found.get("Preferences", "")))
PY
}

qbt_home() { getent passwd "$QBT_SVC_USER" | cut -d: -f6; }
qbt_conf() { echo "$(qbt_home)/.config/qBittorrent/qBittorrent.conf"; }

# ------------------------------------------------------------------- Jackett
install_jackett() {
  if ! id jackett >/dev/null 2>&1; then
    run "Creating the jackett user" useradd --system --home-dir /var/lib/jackett --create-home \
      --shell /usr/sbin/nologin jackett
  fi
  if [ ! -x /opt/Jackett/jackett ]; then
    local tmp; tmp="$(mktemp -d)"
    run "Installing Jackett dependencies" apt-get install -y --no-install-recommends "$(icu_pkg)"
    run "Downloading Jackett" download \
      "https://github.com/Jackett/Jackett/releases/latest/download/Jackett.Binaries.${JACKETT_ARCH}.tar.gz" "$tmp/jackett.tgz"
    tar xzf "$tmp/jackett.tgz" -C /opt
    rm -rf "$tmp"
    chown -R jackett:jackett /opt/Jackett
    msg_ok "Jackett installed in /opt/Jackett"
  else
    msg_ok "Jackett is already installed"
  fi
  cat >/etc/systemd/system/jackett.service <<'UNIT'
[Unit]
Description=Jackett (torrent indexer proxy)
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=jackett
Group=jackett
WorkingDirectory=/opt/Jackett
Environment=XDG_CONFIG_HOME=/var/lib/jackett
ExecStart=/opt/Jackett/jackett --NoRestart --DataFolder /var/lib/jackett
Restart=always
RestartSec=5
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  run "Starting Jackett" systemctl enable --now jackett.service

  local i
  msg_info "Waiting for Jackett to create its API key"
  for ((i = 0; i < 90; i++)); do
    JACKETT_API_KEY="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("APIKey",""))' \
      /var/lib/jackett/ServerConfig.json 2>/dev/null || true)"
    [ -n "$JACKETT_API_KEY" ] && break
    sleep 1
  done
  [ -n "$JACKETT_API_KEY" ] || die "Jackett didn't start. See: journalctl -u jackett"
  msg_ok "Jackett is running on port $JACKETT_PORT"
}

# qBittorrent's Search tab runs its plugins with python3 from PATH. qBittorrent
# 5.3+ needs Python 3.13 (3.9 before that); Debian 12 and Ubuntu 24.04 ship
# older ones. If so, put a self-contained Python in /opt/qbt-python (from
# python-build-standalone, checksum verified) and point only qBittorrent at it.
qbt_bin() {
  local b
  b="$(systemctl show -p ExecStart --value "$QBT_UNIT" 2>/dev/null | sed -n 's/.*path=\([^ ;]*\).*/\1/p')"
  [ -x "$b" ] || b="$(command -v qbittorrent-nox || true)"
  echo "$b"
}

ensure_search_python() {
  local ver need have tag sums asset sum tmp pyarch
  ver="$("$(qbt_bin)" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -n1 || true)"
  need="3.9"
  if [ -n "$ver" ] && [ "$(printf '%s\n5.3\n' "$ver" | sort -V | head -n1)" = "5.3" ]; then need="3.13"; fi
  have="$(python3 -c 'import sys;print("%d.%d" % sys.version_info[:2])' 2>/dev/null || echo 0)"
  if [ "$(printf '%s\n%s\n' "$need" "$have" | sort -V | head -n1)" = "$need" ]; then
    msg_ok "Python $have is new enough for qBittorrent search"
    return
  fi
  case "$(uname -m)" in
    x86_64) pyarch=x86_64 ;; aarch64) pyarch=aarch64 ;;
    *) msg_warn "qBittorrent ${ver:-} needs Python $need for search, but this system has $have. Search won't work until you install Python $need."; return ;;
  esac
  if ! /opt/qbt-python/bin/python3 -c "import sys;sys.exit(sys.version_info[:2] < tuple(map(int, '$need'.split('.'))))" 2>/dev/null; then
    tmp="$(mktemp -d)"
    run "Finding a standalone Python $need" download \
      "https://raw.githubusercontent.com/astral-sh/python-build-standalone/latest-release/latest-release.json" "$tmp/latest.json"
    tag="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["tag"])' "$tmp/latest.json")"
    download "https://github.com/astral-sh/python-build-standalone/releases/download/$tag/SHA256SUMS" "$tmp/SHA256SUMS"
    sums="$(grep -E "cpython-${need//./\\.}\.[0-9]+\+${tag}-${pyarch}-unknown-linux-gnu-install_only_stripped\.tar\.gz$" "$tmp/SHA256SUMS" | sort -V -k2 | tail -n1)"
    [ -n "$sums" ] || die "Couldn't find a Python $need build for $pyarch in release $tag."
    sum="${sums%% *}"; asset="${sums##* }"
    run "Downloading Python $(echo "$asset" | grep -oE "3\.[0-9]+\.[0-9]+")" download \
      "https://github.com/astral-sh/python-build-standalone/releases/download/$tag/${asset//+/%2B}" "$tmp/py.tgz"
    echo "$sum  $tmp/py.tgz" | sha256sum -c --status || die "The Python download's checksum didn't match."
    tar xzf "$tmp/py.tgz" -C "$tmp"
    rm -rf /opt/qbt-python; mv "$tmp/python" /opt/qbt-python
    chmod -R a+rX /opt/qbt-python
    rm -rf "$tmp"
  fi
  install -d -m 755 "/etc/systemd/system/$QBT_UNIT.d"
  cat >"/etc/systemd/system/$QBT_UNIT.d/search-python.conf" <<UNIT
# Python for qBittorrent's search plugins (the system one is older than $need).
[Service]
Environment="PATH=/opt/qbt-python/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
UNIT
  systemctl daemon-reload
  QBT_NEEDS_RESTART=1
  msg_ok "qBittorrent search will use Python $(/opt/qbt-python/bin/python3 -c 'import platform;print(platform.python_version())') from /opt/qbt-python"
}

# Put qBittorrent's official Jackett search plugin in place, pointed at Jackett.
wire_jackett_into_qbt() {
  local home engines tmp
  home="$(qbt_home)"
  engines="$home/.local/share/qBittorrent/nova3/engines"
  tmp="$(mktemp)"
  run "Downloading qBittorrent's Jackett search plugin" download \
    "https://raw.githubusercontent.com/qbittorrent/search-plugins/master/nova3/engines/jackett.py" "$tmp"
  install -d -o "$QBT_SVC_USER" -g "$QBT_SVC_USER" -m 755 \
    "$home/.local" "$home/.local/share" "$home/.local/share/qBittorrent" \
    "$home/.local/share/qBittorrent/nova3" "$engines"
  install -o "$QBT_SVC_USER" -g "$QBT_SVC_USER" -m 644 "$tmp" "$engines/jackett.py"
  rm -f "$tmp"
  python3 - "$engines/jackett.json" "$JACKETT_API_KEY" "http://127.0.0.1:$JACKETT_PORT" <<'PY'
import json, sys
path, key, url = sys.argv[1:]
try:
    data = json.load(open(path))
except Exception:
    data = {}
data.update({"api_key": key, "url": url})
data.setdefault("tracker_first", False)
data.setdefault("thread_count", 20)
json.dump(data, open(path, "w"), indent=4, sort_keys=True)
PY
  chown "$QBT_SVC_USER:$QBT_SVC_USER" "$engines/jackett.json"
  chmod 600 "$engines/jackett.json"
  QBT_NEEDS_RESTART=1
  msg_ok "Jackett added to qBittorrent's Search tab"
}

# ------------------------------------------------------------------ Prowlarr
install_prowlarr() {
  if ! id prowlarr >/dev/null 2>&1; then
    run "Creating the prowlarr user" useradd --system --home-dir /var/lib/prowlarr --create-home \
      --shell /usr/sbin/nologin prowlarr
  fi
  if [ ! -x /opt/Prowlarr/Prowlarr ]; then
    local tmp; tmp="$(mktemp -d)"
    run "Installing Prowlarr dependencies" apt-get install -y --no-install-recommends "$(icu_pkg)" sqlite3
    run "Downloading Prowlarr" download \
      "https://prowlarr.servarr.com/v1/update/master/updatefile?os=linux&runtime=netcore&arch=${PROWLARR_ARCH}" "$tmp/prowlarr.tgz"
    tar xzf "$tmp/prowlarr.tgz" -C /opt
    rm -rf "$tmp"
    chown -R prowlarr:prowlarr /opt/Prowlarr
    msg_ok "Prowlarr installed in /opt/Prowlarr"
  else
    msg_ok "Prowlarr is already installed"
  fi
  cat >/etc/systemd/system/prowlarr.service <<'UNIT'
[Unit]
Description=Prowlarr (indexer manager)
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=prowlarr
Group=prowlarr
ExecStart=/opt/Prowlarr/Prowlarr -nobrowser -data=/var/lib/prowlarr
Restart=on-failure
TimeoutStopSec=20

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  run "Starting Prowlarr" systemctl enable --now prowlarr.service
  wait_for_url "http://127.0.0.1:$PROWLARR_PORT/" 60 || msg_warn "Prowlarr is slow to start; check: journalctl -u prowlarr"
  msg_ok "Prowlarr is running on port $PROWLARR_PORT"
}

# --------------------------------------------------------------------- Samba
install_samba_addon() {
  echo
  echo " ${BLD}Installing the Samba Shares add-on${CL}"
  # install.sh prints its own progress; it also rebuilds the WebUI and restarts qBittorrent.
  if bash "$HERE/install.sh" 2>&1 | tee -a "$LOG" | sed 's/^/     /'; then
    QBT_NEEDS_RESTART=0
    msg_ok "Samba Shares add-on installed"
  else
    die "The Samba Shares add-on didn't install. Full log: $LOG"
  fi
}

# ------------------------------------------------------------------- summary
summary() {
  local ip; ip="$(hostname -I 2>/dev/null | awk '{print $1}')"; ip="${ip:-<this-machine>}"
  echo
  echo " ${GN}${BLD}All done.${CL}"
  echo
  echo "  ${BLD}qBittorrent WebUI${CL}   http://$ip:$QBT_WEBUI_PORT"
  if [ "$QBT_EXISTING" = 0 ] && [ "${QBT_NEW_CONF:-0}" = 1 ]; then
    echo "      username:  $QBT_WEBUI_USER"
    if [ "$PASS_WAS_SET" = 1 ]; then
      echo "      password:  (the one you chose)"
    else
      echo "      password:  $QBT_WEBUI_PASS   (write it down; change it under Options > Web UI)"
    fi
  fi
  if [ -n "$JACKETT_API_KEY" ]; then
    echo "  ${BLD}Jackett${CL}             http://$ip:$JACKETT_PORT"
    echo "      API key:   $JACKETT_API_KEY"
    echo "      Add your trackers in Jackett, then search from qBittorrent's Search tab"
    echo "      (WebUI menu View > Search Engine if the tab is hidden)."
    echo "      Set an admin password in Jackett: it's open to your network until you do."
  fi
  if [ "$INDEXER" = prowlarr ] || [ "$INDEXER" = both ]; then
    echo "  ${BLD}Prowlarr${CL}            http://$ip:$PROWLARR_PORT   (create its login on first visit)"
  fi
  if [ "$SAMBA" = yes ]; then
    echo "  ${BLD}Samba Shares${CL}        WebUI menu Tools > Samba Shares...   (API on port 8099)"
    is_unprivileged_lxc && echo "      ${YW}Shares won't mount until this LXC is privileged (README.md, 'Proxmox setup').${CL}"
  fi
  echo
  echo "  Install log: $LOG"
}

# ---------------------------------------------------------------------- main
main() {
  header
  preflight
  gather_settings
  echo "=== $(date -Is) install-all.sh indexer=$INDEXER samba=$SAMBA" >>"$LOG"
  install_base
  install_qbittorrent
  QBT_NEEDS_RESTART=0
  case "$INDEXER" in
    jackett|both) install_jackett; wire_jackett_into_qbt; ensure_search_python ;;
  esac
  case "$INDEXER" in
    prowlarr|both) install_prowlarr ;;
  esac
  [ "$SAMBA" = yes ] && install_samba_addon
  if [ "$QBT_NEEDS_RESTART" = 1 ]; then
    run "Restarting qBittorrent to load the search plugin" systemctl restart "$QBT_UNIT"
  fi
  summary
}

main "$@"
