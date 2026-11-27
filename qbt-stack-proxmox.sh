#!/usr/bin/env bash
# qBittorrent stack for Proxmox VE: run on the Proxmox host shell as root.
#
#   bash qbt-stack-proxmox.sh
#
# Creates a Debian LXC and installs, inside it:
#   - qBittorrent-nox (WebUI on port 8090)
#   - Jackett (port 9117), wired into qBittorrent's Search tab
#   - the Samba Shares add-on (save downloads straight to SMB/CIFS shares)
#
# The container is privileged with CIFS mounts allowed by default, because
# Linux won't let an unprivileged container mount Samba shares.
# Everything the container needs is bundled in this one file.
#
# Unattended: VAR=value ... bash qbt-stack-proxmox.sh -y   (see "Settings" below)
set -Eeuo pipefail

# ------------------------------------------------------------------ settings
# Any of these can be set in the environment before running.
CTID="${CTID:-}"                       # empty = next free ID
CT_HOSTNAME="${CT_HOSTNAME:-qbittorrent}"
CT_CORES="${CT_CORES:-2}"
CT_RAM="${CT_RAM:-2048}"               # MiB
CT_SWAP="${CT_SWAP:-512}"              # MiB
CT_DISK="${CT_DISK:-8}"                # GiB
CT_STORAGE="${CT_STORAGE:-}"           # empty = ask / only one available
TMPL_STORAGE="${TMPL_STORAGE:-}"       # empty = ask / only one available
CT_OS="${CT_OS:-13}"                   # Debian 13 (trixie); 12 also works
CT_BRIDGE="${CT_BRIDGE:-vmbr0}"
CT_IP="${CT_IP:-dhcp}"                 # dhcp or e.g. 192.168.1.50/24
CT_GW="${CT_GW:-}"                     # gateway, only with a static IP
CT_VLAN="${CT_VLAN:-}"
CT_PRIVILEGED="${CT_PRIVILEGED:-yes}"  # yes = Samba shares can mount
CT_ROOT_PASS="${CT_ROOT_PASS:-}"       # empty = console logs in automatically
QBT_WEBUI_USER="${QBT_WEBUI_USER:-admin}"
QBT_WEBUI_PASS="${QBT_WEBUI_PASS:-}"   # empty = random, shown at the end
QBT_WEBUI_PORT="${QBT_WEBUI_PORT:-8090}"
INDEXER="${INDEXER:-jackett}"          # jackett, prowlarr, both, none
SAMBA="${SAMBA:-yes}"

ASSUME_YES=0
[ "${1:-}" = "-y" ] || [ "${1:-}" = "--yes" ] && ASSUME_YES=1
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  echo "Run on the Proxmox host as root. Settings can be given as environment variables"
  echo "(CTID, CT_HOSTNAME, CT_CORES, CT_RAM, CT_DISK, CT_STORAGE, CT_IP, CT_PRIVILEGED,"
  echo "QBT_WEBUI_PASS, INDEXER, SAMBA, ...); -y uses them without asking."
  exit 0
fi

# ------------------------------------------------------------------- styling
if [ -t 1 ]; then
  RD=$'\e[01;31m'; GN=$'\e[1;92m'; YW=$'\e[33m'; BL=$'\e[36m'; BLD=$'\e[1m'; CL=$'\e[m'; BOL=$'\r\e[K'
else
  RD=""; GN=""; YW=""; BL=""; BLD=""; CL=""; BOL=""
fi
CM="${GN}✓${CL}"; CROSS="${RD}✗${CL}"; INFO="${YW}…${CL}"
TITLE="qBittorrent stack LXC"
WORK="$(mktemp -d)"
CT_CREATED=0

msg_info()  { [ -n "$BOL" ] && printf ' %s %s' "$INFO" "$1"; return 0; }
msg_ok()    { printf '%s %s %s\n' "$BOL" "$CM" "$1"; }
msg_warn()  { printf ' %s%s%s\n' "$YW" "! $1" "$CL"; }
msg_error() { printf '%s %s %s%s%s\n' "$BOL" "$CROSS" "$RD" "$1" "$CL"; }
die() { msg_error "$1"; exit 1; }

on_error() {
  local code=$? line=$1
  msg_error "Stopped at line $line (exit $code)."
  if [ "$CT_CREATED" = 1 ]; then
    msg_warn "Container $CTID was created and left as it is so you can look at it."
    msg_warn "Remove it with:  pct stop $CTID; pct destroy $CTID"
  fi
  exit "$code"
}
trap 'on_error $LINENO' ERR
trap 'rm -rf "$WORK"' EXIT

header() {
  [ -t 1 ] && { clear 2>/dev/null || true; }
  cat <<EOF
${BL}
   ┌──────────────────────────────────────────────────────────────┐
   │   qBittorrent stack LXC for Proxmox VE                       │
   │   qBittorrent-nox  +  Jackett  +  Samba Shares               │
   └──────────────────────────────────────────────────────────────┘
${CL}
EOF
}

# ------------------------------------------------------------------- prompts
INTERACTIVE=1
{ [ "$ASSUME_YES" = 1 ] || ! [ -t 0 ]; } && INTERACTIVE=0

wt() { whiptail --backtitle "Proxmox VE: qBittorrent stack" --title "$TITLE" "$@" 3>&1 1>&2 2>&3; }

# ask VAR "question" default
ask() {
  local __v="$1" ans
  ans="$(wt --inputbox "$2" 10 70 "$3")" || die "Cancelled. Nothing was created."
  printf -v "$__v" '%s' "${ans:-$3}"
}
ask_secret() {
  local __v="$1" ans
  ans="$(wt --passwordbox "$2" 10 70)" || die "Cancelled. Nothing was created."
  printf -v "$__v" '%s' "$ans"
}

# pick_storage VAR content "label"
pick_storage() {
  local __v="$1" content="$2" label="$3" list=() n=0 name type avail
  [ -n "${!__v}" ] && return 0
  while read -r name type _ _ _ avail _; do
    list+=("$name" "$(printf '%-10s %s free' "$type" "$(numfmt --to=iec --from-unit=1024 "$avail" 2>/dev/null || echo "$avail KiB")")")
    n=$((n + 1))
  done < <(pvesm status -content "$content" 2>/dev/null | awk 'NR>1 && $3=="active"')
  [ "$n" -gt 0 ] || die "No active storage can hold $label (content type '$content')."
  if [ "$n" -eq 1 ] || [ "$INTERACTIVE" = 0 ]; then
    printf -v "$__v" '%s' "${list[0]}"
  else
    printf -v "$__v" '%s' "$(wt --menu "Storage for $label" 16 70 6 "${list[@]}")" || die "Cancelled. Nothing was created."
  fi
}

settings_summary() {
  cat <<EOF
Container ID:   $CTID
Hostname:       $CT_HOSTNAME
OS:             Debian $CT_OS
CPU / RAM:      $CT_CORES cores / $CT_RAM MiB (+$CT_SWAP MiB swap)
Disk:           $CT_DISK GiB on $CT_STORAGE
Network:        $CT_BRIDGE, $CT_IP${CT_GW:+ via $CT_GW}${CT_VLAN:+, VLAN $CT_VLAN}
Privileged:     $CT_PRIVILEGED$([ "$CT_PRIVILEGED" = yes ] && echo " (Samba shares can mount)")
WebUI:          port $QBT_WEBUI_PORT, user $QBT_WEBUI_USER
Search tool:    $INDEXER
Samba Shares:   $SAMBA
EOF
}

advanced_settings() {
  ask CTID "Container ID" "$CTID"
  ask CT_HOSTNAME "Hostname" "$CT_HOSTNAME"
  CT_OS="$(wt --default-item "$CT_OS" --menu "Debian version" 12 60 2 13 "Debian 13 (trixie, recommended)" 12 "Debian 12 (bookworm)")" || die "Cancelled. Nothing was created."
  ask CT_CORES "CPU cores" "$CT_CORES"
  ask CT_RAM "RAM in MiB" "$CT_RAM"
  ask CT_DISK "Disk size in GiB" "$CT_DISK"
  CT_STORAGE=""; pick_storage CT_STORAGE rootdir "the container's disk"
  ask CT_BRIDGE "Network bridge" "$CT_BRIDGE"
  ask CT_IP "IPv4 address with mask (e.g. 192.168.1.50/24), or dhcp" "$CT_IP"
  if [ "$CT_IP" != dhcp ]; then ask CT_GW "Gateway" "$CT_GW"; fi
  ask CT_VLAN "VLAN tag (leave empty for none)" "$CT_VLAN"
  if wt --yesno "Make the container privileged?\n\nSamba shares can only be mounted from a privileged container. Say No only if you won't use the Samba Shares add-on." 12 70; then
    CT_PRIVILEGED=yes
  else
    CT_PRIVILEGED=no
  fi
  ask_secret CT_ROOT_PASS "Container root password (leave empty to log in automatically from the Proxmox console)"
  ask QBT_WEBUI_USER "qBittorrent WebUI username" "$QBT_WEBUI_USER"
  ask_secret QBT_WEBUI_PASS "qBittorrent WebUI password (leave empty for a random one)"
  ask QBT_WEBUI_PORT "qBittorrent WebUI port" "$QBT_WEBUI_PORT"
  INDEXER="$(wt --default-item "$INDEXER" --menu "Torrent search tool" 14 78 4 \
    jackett  "Jackett - plugs into qBittorrent's Search tab (recommended)" \
    prowlarr "Prowlarr - for Sonarr/Radarr; not in qBittorrent's Search tab" \
    both     "Both" \
    none     "Neither")" || die "Cancelled. Nothing was created."
  if wt --yesno "Install the Samba Shares add-on?" 8 60; then SAMBA=yes; else SAMBA=no; fi
}

gather() {
  [ -n "$CTID" ] || CTID="$(pvesh get /cluster/nextid)"
  pick_storage CT_STORAGE rootdir "the container's disk"
  pick_storage TMPL_STORAGE vztmpl "container templates"
  if [ "$INTERACTIVE" = 1 ]; then
    if ! wt --yesno "Use these settings?\n\n$(settings_summary)\n\nChoose No to change them." 24 76; then
      advanced_settings
      wt --yesno "Create the container with these settings?\n\n$(settings_summary)" 24 76 || die "Cancelled. Nothing was created."
    fi
  else
    settings_summary | sed 's/^/   /'; echo
  fi
}

# -------------------------------------------------------------------- checks
preflight() {
  [ "$(id -u)" -eq 0 ] || die "Run this as root on the Proxmox host."
  if ! command -v pct >/dev/null 2>&1 || ! command -v pveversion >/dev/null 2>&1; then
    die "This needs to run on a Proxmox VE host. Inside an existing container, use install-all.sh instead."
  fi
  [ "$(dpkg --print-architecture 2>/dev/null || echo amd64)" = amd64 ] || die "Only amd64 Proxmox hosts are supported."
  case "$INDEXER" in jackett|prowlarr|both|none) ;; *) die "INDEXER must be jackett, prowlarr, both or none." ;; esac
  case "$CT_OS" in 12|13) ;; *) die "CT_OS must be 12 or 13." ;; esac
}

validate() {
  [[ "$CTID" =~ ^[0-9]+$ ]] && [ "$CTID" -ge 100 ] || die "Container ID must be a number of 100 or more."
  if pct status "$CTID" >/dev/null 2>&1 || qm status "$CTID" >/dev/null 2>&1; then
    die "ID $CTID is already in use."
  fi
  for v in CT_CORES CT_RAM CT_DISK CT_SWAP QBT_WEBUI_PORT; do
    [[ "${!v}" =~ ^[0-9]+$ ]] || die "$v must be a number."
  done
  [ -z "$CT_VLAN" ] || [[ "$CT_VLAN" =~ ^[0-9]+$ ]] || die "VLAN must be a number."
  [ "$CT_IP" = dhcp ] || [[ "$CT_IP" =~ ^[0-9.]+/[0-9]+$ ]] || die "IP must be dhcp or an address like 192.168.1.50/24."
}

# ------------------------------------------------------------------ template
get_template() {
  msg_info "Updating the container template list"
  pveam update >/dev/null 2>&1 || true
  msg_ok "Updated the container template list"
  TEMPLATE="$(pveam available --section system 2>/dev/null | awk '{print $2}' \
    | grep -E "^debian-${CT_OS}-standard_.*_amd64\.tar\.(zst|xz|gz)$" | sort -V | tail -n1 || true)"
  [ -n "$TEMPLATE" ] || die "Couldn't find a Debian $CT_OS template. Check the host's internet access."
  if pveam list "$TMPL_STORAGE" 2>/dev/null | grep -q "$TEMPLATE"; then
    msg_ok "Template $TEMPLATE is already downloaded"
  else
    msg_info "Downloading $TEMPLATE"
    pveam download "$TMPL_STORAGE" "$TEMPLATE" >"$WORK/pveam.log" 2>&1 || { cat "$WORK/pveam.log"; die "Template download failed."; }
    msg_ok "Downloaded $TEMPLATE"
  fi
}

# ----------------------------------------------------------------- container
create_ct() {
  local net="name=eth0,bridge=$CT_BRIDGE,ip=$CT_IP"
  [ -n "$CT_GW" ] && net+=",gw=$CT_GW"
  [ -n "$CT_VLAN" ] && net+=",tag=$CT_VLAN"
  local args=(
    "$CTID" "$TMPL_STORAGE:vztmpl/$TEMPLATE"
    --hostname "$CT_HOSTNAME" --cores "$CT_CORES" --memory "$CT_RAM" --swap "$CT_SWAP"
    --rootfs "$CT_STORAGE:$CT_DISK" --net0 "$net" --ostype debian --onboot 1
    --tags "qbittorrent;jackett" --description "qBittorrent-nox + Jackett + Samba Shares"
  )
  if [ "$CT_PRIVILEGED" = yes ]; then
    args+=(--unprivileged 0 --features "nesting=1,mount=cifs")
  else
    args+=(--unprivileged 1 --features "nesting=1")
  fi
  [ -n "$CT_ROOT_PASS" ] && args+=(--password "$CT_ROOT_PASS")
  msg_info "Creating container $CTID"
  pct create "${args[@]}" >"$WORK/create.log" 2>&1 || { cat "$WORK/create.log"; die "Creating the container failed."; }
  CT_CREATED=1
  msg_ok "Created container $CTID ($CT_HOSTNAME)"
  msg_info "Starting container $CTID"
  pct start "$CTID"
  msg_ok "Started container $CTID"

  local i
  msg_info "Waiting for the container's network"
  for ((i = 0; i < 60; i++)); do
    pct exec "$CTID" -- getent hosts github.com >/dev/null 2>&1 && break
    sleep 2
  done
  [ "$i" -lt 60 ] || die "The container has no internet access. Check the bridge and IP settings."
  msg_ok "Container network is up"

  if [ -z "$CT_ROOT_PASS" ]; then
    # shellcheck disable=SC2016  # expanded inside the container
    pct exec "$CTID" -- bash -c '
      d=/etc/systemd/system/container-getty@1.service.d
      mkdir -p "$d"
      printf "[Service]\nExecStart=\nExecStart=-/sbin/agetty --autologin root --noclear --keep-baud tty%%I 115200,38400,9600 \$TERM\n" > "$d/override.conf"
      systemctl daemon-reload; systemctl restart container-getty@1.service' >/dev/null 2>&1 || true
    msg_ok "Console logs in as root automatically (set a password with: pct exec $CTID -- passwd)"
  fi
}

# ------------------------------------------------------------------- install
install_stack() {
  base64 -d >"$WORK/qbt-samba.tar.gz" <<<"$PAYLOAD"
  pct push "$CTID" "$WORK/qbt-samba.tar.gz" /root/qbt-samba.tar.gz
  pct exec "$CTID" -- tar xzf /root/qbt-samba.tar.gz -C /root
  # Settings go in through a root-only file, so passwords never appear on a command line.
  {
    printf 'QBT_WEBUI_USER=%q\n' "$QBT_WEBUI_USER"
    printf 'QBT_WEBUI_PASS=%q\n' "$QBT_WEBUI_PASS"
    printf 'QBT_WEBUI_PORT=%q\n' "$QBT_WEBUI_PORT"
    printf 'INDEXER=%q\n' "$INDEXER"
    printf 'SAMBA=%q\n' "$SAMBA"
  } >"$WORK/stack.env"
  chmod 600 "$WORK/stack.env"
  pct push "$CTID" "$WORK/stack.env" /root/.qbt-stack.env --perms 600
  echo
  echo " ${BLD}Installing inside container $CTID${CL}"
  pct exec "$CTID" -- bash -c 'set -a; . /root/.qbt-stack.env; set +a; rm -f /root/.qbt-stack.env
    export DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8
    bash /root/qbt-samba/install-all.sh -y' 2>&1 | sed 's/^/  /'
  [ "${PIPESTATUS[0]}" -eq 0 ] || die "The install inside container $CTID failed. Log: pct exec $CTID -- cat /var/log/qbt-stack-install.log"
}

main() {
  header
  preflight
  gather
  validate
  get_template
  create_ct
  install_stack
  echo
  msg_ok "Container $CTID is ready."
  echo "     Open a shell in it:   pct enter $CTID"
  echo "     Add-on files:         /root/qbt-samba inside the container (install-all.sh, uninstall.sh, README.md)"
  echo
}

PAYLOAD="$(cat <<'__QBT_SAMBA_PAYLOAD_END__'
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
Ep0J9t16Z+nN0qTX648Lw9LpVef7N8fBfbda4333BfbGzeAUcPXkYLO009+5Pjna265FPqcb2H73
ZHNnrbW9UujVPtY+XW1Y+8fbH0cL9bLT3+72e63bw/HHT5vd7drxaLV+IeY7oXn0TwBu60AjTnut
ub1vp8fdiybAm/BxfsOFdSwCrIobnzc+nvZvAOftorVy6axg5xcLAR36WGY6tA2witKhmtgzJwBf
66gI+Ey0b3WtjHv3j95Jed0/LZ/Cfq/f7hycDlvl3qDZXy/Cvuk59ci+2Rd7ZO7LbfNiSN93++u4
BpcnFyfXWwenvZ2D7fHOxvbC7n6pu/29dbN18HkOaPDNycHhzc5Fvbgt2xgAbSsvdO0PXwCPhkNY
6yLg2MXpYa/urN7MN49ri9ZR73K3X7/ZXqvfAl0vbR2dXm4fbI531k7mgKa5pwd73a2jzdL2Wvfi
9Oije3px+P30w0fA/S9dwLnL4/L691b5yy3j0u6a18fz42Z+63in19w4uRBrsJRE67em0e/yHuD/
jne0urb7odXrlGA7N9vDq8lad9wrFPsXi6sbRzdv3n4bH9p23e0O1ueODwI6NHwCHZJ7YBvW7GNA
g9Z2D/aOv6zeFOvO+O3iSv/7dnHJW1pZ+mPrU3dl8+1o0C99mNQWb46X+u4JrtOHDqzpF//U3SF8
Ob0oyfYV2GxfCRjQ3Lb6ewC/9aDP+fHa1ffD4/nPsEna44vy2u2HlY/b7b3T47flz03Hq3UuRqe7
w+O9ebvIeFZqn5a/TGBO0M7S7THS5f5riftXn48WihbQvdZG72KzjnQCaMwc7AHACYB9b3t//nrr
YmXUAjp/UlKeu/PFrQs8R2rzAR1Y7Up+4aJ1HeMX4rhG/EZtk/b5+I/60efNfa9T72+srp/WOt51
p7O5sb25uXJh1dZqnfpqrbtXW7Bqf7zxNxeKW4vznYK38blzuHRaOjyAEn+sdDrfupcXu58+f16r
fQew7LWu1z+frH35/PmP+vXCikK7/c31ldXP3+uT7dXrjVrpsF672e7psACaPtjDc6fzmc4gwLmN
Xrf5Ybtz2F+6Apq89vmg5qxfF293Lmrz22utm921z99h31r4bHcNn53c7B7ws+3655v177UvK52d
Lys172DtUj2DrjuH9Y9r2/uX17DyOF7YZSvqeDvBuaGM65DoA6zn95XT7ZXtjZXbbxv72/NLAKuN
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
WjnlAOABAA==
__QBT_SAMBA_PAYLOAD_END__
)"

main "$@"
