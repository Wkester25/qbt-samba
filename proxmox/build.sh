#!/usr/bin/env bash
# Builds qbt-stack-proxmox.sh: the Proxmox host script with the add-on files
# bundled inside it (base64 tarball), so the host needs only that one file.
#   bash proxmox/build.sh [output]      default output: ./qbt-stack-proxmox.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
OUT="${1:-$ROOT/qbt-stack-proxmox.sh}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

tar czf "$TMP/payload.tgz" -C "$(dirname "$ROOT")" \
  --exclude='__pycache__' --exclude='*/proxmox' --exclude='*/qbt-stack-proxmox.sh' --exclude='*/tests' \
  "$(basename "$ROOT")"
base64 -w 76 "$TMP/payload.tgz" >"$TMP/payload.b64"

awk -v payload="$TMP/payload.b64" '
  $0 == "__QBT_SAMBA_PAYLOAD__" { while ((getline line < payload) > 0) print line; next }
  { print }
' "$HERE/ct-template.sh" >"$OUT.new"
chmod 755 "$OUT.new"
mv "$OUT.new" "$OUT"
echo "Built $OUT ($(wc -c <"$OUT") bytes)"
