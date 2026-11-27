#!/usr/bin/env bash
# Removes qbt-samba from the LXC. Shares are unmounted; the files on them stay.
set -euo pipefail
cd "$(dirname "$0")"
[ "$(id -u)" -eq 0 ] || { echo "Run as root."; exit 1; }
bash ./install-webui.sh --disable || true
systemctl disable --now qbt-samba.service qbt-samba-mount.service || true
for d in /mnt/samba/*; do
  [ -d "$d" ] || continue
  mountpoint -q "$d" && umount "$d"
  chattr -i "$d" 2>/dev/null || true
  rmdir "$d" 2>/dev/null || true
done
rm -f /etc/systemd/system/qbt-samba.service /etc/systemd/system/qbt-samba-mount.service
rm -f /etc/systemd/system/*qbittorrent*.service.d/qbt-samba.conf
systemctl daemon-reload
rm -rf /opt/qbt-samba
echo "Removed. Saved shares and passwords are still in /etc/qbt-samba; delete that folder to remove them too."
