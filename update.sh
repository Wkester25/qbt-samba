#!/usr/bin/env bash
# Updates the Samba Shares add-on in this container to the latest version on
# GitHub. Your shares, passwords and qBittorrent settings are kept.
#
# Inside the container:
#   bash /root/qbt-samba/update.sh
# or from the Proxmox host (replace 105 with the container ID):
#   pct exec 105 -- bash -c "$(curl -fsSL https://raw.githubusercontent.com/Wkester25/qbt-samba/main/update.sh)"
#
# QBT_SAMBA_REF=<branch> picks another branch (default: main).
# QBT_SAMBA_TARBALL=<file> installs from a local .tar.gz instead of GitHub.
set -euo pipefail
REPO="Wkester25/qbt-samba"
REF="${QBT_SAMBA_REF:-main}"
DEST=/root/qbt-samba

[ "$(id -u)" -eq 0 ] || { echo "Run as root."; exit 1; }
command -v curl >/dev/null || { apt-get update -qq && apt-get install -y -qq curl >/dev/null; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
if [ -n "${QBT_SAMBA_TARBALL:-}" ]; then
  tar xzf "$QBT_SAMBA_TARBALL" -C "$TMP"
else
  echo "==> Downloading qbt-samba ($REF)"
  curl -fsSL "https://github.com/$REPO/archive/refs/heads/$REF.tar.gz" | tar xz -C "$TMP"
fi
SRC="$(ls -d "$TMP"/qbt-samba*/ | head -n1)"; SRC="${SRC%/}"

# install.sh is safe to re-run: it keeps /etc/qbt-samba (shares, passwords, config).
bash "$SRC/install.sh"
systemctl restart qbt-samba.service

rm -rf "$DEST.new"; cp -r "$SRC" "$DEST.new"
rm -rf "$DEST"; mv "$DEST.new" "$DEST"

echo
echo "Updated. qBittorrent was restarted, so reload the WebUI page (Ctrl+Shift+R) and log in again."
