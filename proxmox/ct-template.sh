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
__QBT_SAMBA_PAYLOAD__
__QBT_SAMBA_PAYLOAD_END__
)"

main "$@"
