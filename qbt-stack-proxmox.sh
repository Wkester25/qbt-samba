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
lHEdEX2A9fy2cra9sr2xcvd142B7fglgtbG6Kr7f1D5UC5vVlY/dxdX+9dbRSmd9feeocH30R2/3
87i22LpsFd9sLRxMbk4KW05/3fVXtudaV638XPPu8na9OvfJWziYX2yfFPJu97Tw+exNv91Y+mP9
TWFuvLB7eby2crxdnUcYttZuaiv5m0+16s3mh84az/XDwVFt7bK6vdLxRiudWq16uueddDZXtqsE
91aN66wCQb/5gHPfL1yurHRu1r3q0bfeB3dlc333bN2/fL27V/u24L0ebH84OdnevFntnG7+4Z1t
frssQH/ba2c31Zuz6ubN9sl2a/3j/Ioz3tr6fPpmd39SWxp4XxuN6tnu2SBvV0cnd4c369Wz9h+j
vW+366XrPe/jTrv4+mi11SmebFQvV25Oit9aS8cbX0+vvvYBMutfb4qf7g4uR8VvH9vDj9tLr4sj
mOvB3tb27t7u5R8T9+TSO8oPj46cjaX9mz7wSyvds/WrnUEnekr9/Pz8/Pz8/Pz8/Pz8/Pz8/Pz8
/Pz8/Pz8/Pz8/Pz8/Pz8/H/52Ts7/bT71r27ym+ejPbcy8/jxTelo61v21u9r+tHx7X5kz/efh45
O/2rT2t26evr3epkdefGPT4eNN9+9fp3u+vV4+7uyh9Lex9anyaTuepwt2oPvdbZ28q7vH4n/C4f
3hbjNfz7H2+VFLX/YN+v7rjf+3F9POL/tbAwV4j6f80tLP60//gnPu9+WdtdPTzdqxm45u9T7/CP
0bMHnYrpDEx84Nit92Q5R7YLGJ9m5Dvjinl0uJ57axp59SXG86mYaCxCsXIN4cJSMdkOpOWgAzYb
hWBIXxdT4OX8pt1zKsWwqbE77jnv1cAT7/L8jN+TifTI6WGQ7rue43cdB/rqjpx2xdQcGMMmObyZ
4Y+aUIm+y2KXUKqFfmC4x+gNTDrPs36Hpo2ihZZ7bbitism2nCan2A1/dt1WyxlAG1DufUp0yr4/
7wMnKmpEVFQdg8ywCBXrlt7LecNX/Z0wzB9jMDSTf5g0MLvVWhnDklVbIj7Ouzy/Vvrn0QU/h3Iw
6DpkvpcRBtBFH6PsjD1DBH976cugOR0PbVtsNIE2YHE57IcI3cZlrXf5odIHO8LgANmd/xB/Ryc8
DrFMfw6rMu6+3wG0AhTo0o8qpwYOfh+Qn0Pwk7/koabeRT6hj3fs2hMObgV+mtPGgeG7e/7QHlTM
+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
__QBT_SAMBA_PAYLOAD_END__
)"

main "$@"
