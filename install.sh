#!/usr/bin/env bash
# Installs qbt-samba inside the qBittorrent LXC. Run as root inside the container:
#   bash install.sh
set -euo pipefail
cd "$(dirname "$0")"

[ "$(id -u)" -eq 0 ] || { echo "Run as root."; exit 1; }

echo "==> Checking the container can mount Samba shares"
if awk '$1==0 && $2!=0 {exit 0} END{exit 1}' /proc/self/uid_map 2>/dev/null; then
  echo "WARNING: this LXC is unprivileged, so it can't mount Samba shares."
  echo "         Convert it to privileged and enable the cifs mount feature on the Proxmox host"
  echo "         (see README.md, 'Proxmox setup'). Installing anyway."
fi

echo "==> Installing packages"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cifs-utils python3 e2fsprogs >/dev/null

echo "==> Finding qBittorrent"
QBT_UNIT="$(systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -i qbittorrent | head -n1 || true)"
if [ -z "$QBT_UNIT" ]; then
  echo "Couldn't find a qBittorrent systemd service. Is qbittorrent-nox installed?"; exit 1
fi
QBT_USER="$(systemctl show -p User --value "$QBT_UNIT")"; QBT_USER="${QBT_USER:-root}"
QBT_UID="$(id -u "$QBT_USER")"; QBT_GID="$(id -g "$QBT_USER")"
QBT_HOME="$(getent passwd "$QBT_USER" | cut -d: -f6)"
QBT_CONF="$QBT_HOME/.config/qBittorrent/qBittorrent.conf"
# Read a WebUI setting from qBittorrent.conf: [WebUI] Key (5.x) or [Preferences] WebUI\Key (4.x).
qbt_webui_pref() {
  python3 - "$QBT_CONF" "$1" <<'PY2' 2>/dev/null || true
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
PY2
}
QBT_PORT="$(qbt_webui_pref Port)"
QBT_PORT="${QBT_PORT:-8090}"
QBT_HTTPS="$(qbt_webui_pref 'HTTPS\Enabled')"
SCHEME=http; [ "$QBT_HTTPS" = "true" ] && SCHEME=https
echo "    service: $QBT_UNIT, runs as: $QBT_USER ($QBT_UID:$QBT_GID), WebUI: $SCHEME port $QBT_PORT"

echo "==> Installing files"
install -d -m 755 /opt/qbt-samba
install -m 755 qbt_samba/server.py /opt/qbt-samba/server.py
install -d -m 700 /etc/qbt-samba
install -d -m 755 /mnt/samba
if [ ! -f /etc/qbt-samba/config.json ]; then
  cat > /etc/qbt-samba/config.json <<JSON
{
  "listen_host": "0.0.0.0",
  "listen_port": 8099,
  "qbt_url": "$SCHEME://127.0.0.1:$QBT_PORT",
  "allowed_origins": [],
  "mount_root": "/mnt/samba",
  "uid": $QBT_UID,
  "gid": $QBT_GID,
  "file_mode": "0664",
  "dir_mode": "0775",
  "watch_interval": 60,
  "tls_cert": "",
  "tls_key": ""
}
JSON
  chmod 600 /etc/qbt-samba/config.json
else
  echo "    keeping existing /etc/qbt-samba/config.json"
fi

install -m 644 systemd/qbt-samba.service /etc/systemd/system/qbt-samba.service
install -m 644 systemd/qbt-samba-mount.service /etc/systemd/system/qbt-samba-mount.service

# Start qBittorrent only after the shares are mounted.
install -d -m 755 "/etc/systemd/system/$QBT_UNIT.d"
cat > "/etc/systemd/system/$QBT_UNIT.d/qbt-samba.conf" <<UNIT
[Unit]
After=qbt-samba-mount.service
Wants=qbt-samba-mount.service
UNIT
grep -q "^Before=$QBT_UNIT" /etc/systemd/system/qbt-samba-mount.service || \
  sed -i "/^Wants=network-online.target/a Before=$QBT_UNIT" /etc/systemd/system/qbt-samba-mount.service

systemctl daemon-reload
systemctl enable --now qbt-samba-mount.service qbt-samba.service

bash ./install-webui.sh

echo
echo "Done. In the WebUI, open Tools > Samba Shares... to add a share."
echo "Shares will be mounted under /mnt/samba/<name>."
echo "Check it with: systemctl status qbt-samba   and   journalctl -u qbt-samba -f"
