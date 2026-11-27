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
K9sbK7ffNva355cAVhurq+L7de1DtbBZXfnYXVztX20drnTW13cOC1eHf/R2v4xri62LVvHN1sL+
5Pq4sOX0111/ZXuuddnKzzVvL27Wq3OfvYX9+cX2cSHvdk8KX07f9NuNpT/W3xTmxgu7F0drK0fb
1XmEYWvturaSv/5cq15vfuis8Vw/7B/W1i6q2ysdb7TSqdWqJ5+8487mynaV4N6qcZ1VIOjXH3Du
e4WLlZXO9bpXPfze++CubK7vnq77F693P9W+L3ivB9sfjo+3N69XOyebf3inm98vCtDf9trpdfX6
tLp5vX283Vr/OL/ijLe2vpy82d2b1JYG3rdGo3q6ezrI29XR8e3B9Xr1tP3H6NP3m/XS1Sfv4067
+PpwtdUpHm9UL1auj4vfW0tHG99OLr/1ATLr366Ln2/3L0bF7x/bw4/bS6+LI5jr/qet7d1Puxd/
TNzjC+8wPzw8dDaW9q77wC+tdE/XL3cGnegp9fx5/jx/nj/Pn+fP8+f58/x5/jx/nj/Pn+fP8+f5
8/z5//Lz6fTk8+5b9/Yyv3k8+uRefBkvvikdbn3f3up9Wz88qs0f//H2y8jZ6V9+XrNL317vVier
O9fu0dGg+fab17/dXa8edXdX/lj69KH1eTKZqw53q/bQa52+rbzL63fC7/LhbTFew7//+VZJUfsP
9v3qjvu9n9fHA/5fCwtzhaj/19zC4rP9xz/xeffL2u7qwcmnmoFr/j71Dv8YPXvQqZjOwMQHjt16
T5ZzZLuA/ukj3xlXzMOD9dxb08irL9Gfv2KisQjFyjOEC0vFZDuQloMe4WwUgiH9XEyBk/Obds+p
FMOmxu6457znoCIcauBdnp/xezKRHjk9DNJ523P8ruNAX92R066YmgNj2CSHNzH8URMq0XdZ7AJK
tdAPDPcYvYFJ53nW79C0UbTQcq8Mt1Ux2ZbT5BR74c+u22o5A2gDyr1PiU7Z9+d94ERFjYiKqmOQ
GRahYt3Sezlv+Kq/E4b5YwyGYvIPkwZmt1orY1iyakv4x7/L82ulfx5d8HMoB4OuQ+b7Ne96QEk+
DJ+87MeeIYK/vPSl03zHQ9sWG02gDVhcTiAgQrdwWetdfqj0wY4wOEB22j/A39EJj0Ms05/Dqoy7
73cArQAFuvSjyqkBg9/75OcQ/OQveaipd5FP6OMdu/aEg1uBn+a0cWD4zp4/tAcVcz5Yf/LUMN9v
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
__QBT_SAMBA_PAYLOAD_END__
)"

main "$@"
