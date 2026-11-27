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
iV/dXDFaY84oLnyTs/y11XDethfNvDKOYgkYXmxzaRs6LXaLJXq0dF3S5tq0h3KqULvvjG0Mjvf+
Hc6xLOf3vlqtHnf6w2LjeBO+Vh178Hl8trF919yoVWufqp868PBrpzrfn6utnX77eHP6CR6snDWx
3Cm+rLW+to6LV/BuDO/2qyur8HD1a3XNbTQ/7RSb/flFqnc47J5t7LhnG5ul7dVC6ezw6NvW4f7l
7uHV+PRwe277oFDY+bbe3T6uFbcPT2931mo4nrVeKRjbUI7t9GQ7eWwHC93m3E6vOdgfNkoL37BS
desWx+fi1/0NbGv/8rS/dFddgflhs3941d2P49taieY8sY8XBs3+5yv7+POktbpQ2r6hVk6h/W/2
zpE319/44+jb67e7bwvb9uJptfjhCgFyc1r6eN38ujOE8S2eQfuN4/VC47g3Pj1u9bbmdkpnd+P5
xvHtV2j/W2tjfXJa+vxx/0PHdzaKN7v93vBsbdjfvjyD/z5fnq0Wu6eHnxA+/d212vi0f3p7ele8
PD0+Kp4e77jbl51vuxtnPozTPz3hudobvRv7w0oXnk1ataU+Dmo+WNeVFYbdjtuY24zC7lDC7nSO
29oanN7RrFe6l9uDHW9x78Od03e+Fbb3SwX7erJ7Ult4g3A56xEsvX4rqNv5+rEPYyzYx0sTW8C0
MbfSayBMBzi+9fHZyT6s0W7XLvUmZ3Mfe2cbvV5jsP+tY3+8bJ189J3V4rez49v+Jq39x/7eMbdz
erLz7ezkI7XdvFuCsa10t/pqG58mrcudK3tj/Zu93ul86859PN35ZB9vzC023nTmG2ftpY/e6063
5zv5P0afP5zsb3pnt61ioXR11l+/bG30rhuDTuu0tDTe6q9PWhvdOxj78PRu4bKxsV482ziaND98
vG71e1dnx/tfmxvrd6fHxV5r4/Ndc3F9/kNp57oBcIS5eM3+0o19vA1z/zg8g3luHcO7/hngx2dc
+0HreGHU6C/NNfrjq7OTnctmv3fD/Xf7n0q33dbxfm/zwwr0T3WuNj/se/bJdues3/PPDla6rdWV
gr1x1IH1vm0df/4Gv6/P3JXu5ofPAKPNzunxwtXmRrHrHKx4pydnvc2NnbszwMmz408dwIFO43gJ
cBzaht8wT3h/NmxAezB3mDfg0AcY+8nO9dlgf+705GPvE+BxY3AAexjmd/w5GCOsp9+oSdjtfGz0
d3x8frZ3hNt3M6QTK0wncJ90InRif0esZbfbLHUmZxvrBaIzwb5b7yy9WZr0ev1xflg8u+58++o4
uO9Wq7zvPsPeuB2cAa6eHm4Wd/o7N6fH+9vVyOdsA9vvnm7urDW3V/K96sfq3vWGfXCy/XG0UCs5
/e1uv9e8Oxp/3NvsbldPRqu1SzHfCc2jfwpwWwcacdZrzu1/PTvpXjYA3oSP8xsurGMBYFXY+LTx
8ax/CzjfKtgrV84Kdn65ENChjyWmQ9sAqygdqoo9cwrwtY8LgM9E+1bXSrh3/+idltb9s9IZ7Pfa
3c7h2bBZ6g0a/fUC7JueU4vsmwOxR+Y+3zUuh/R9t7+Oa3B1enl6s3V41ts53B7vbGwv7B4Uu9vf
mrdbh5/mgAbfnh4e3e5c1grbso0B0LbSQrf14TPg0XAIa10AHLs8O+rVnNXb+cZJddE+7l3t9mu3
22u1O6Drxa3js6vtw83xztrpHNA09+xwv7t1vFncXutenh1/dM8uj76dffgIuP+5Czh3dVJa/9Ys
fb5jXNpd8/p4ftzOb53s9Bobp5diDZaSaP3WNPpd2gf83/GOV9d2PzR7nSJs50Z7eD1Z6457+UL/
cnF14/j2zduv46NWq+Z2B+tzJ4cBHRo+gw7JPbANa/YxoEFru4f7J59Xbws1Z/x2caX/bbuw5C2t
LP2xtddd2Xw7GvSLHybVxduTpb57iuv0oQNr+tk/c3cIX84ui7J9BTbb1wIGNLet/j7Abz3oc368
dv3t6GT+E2yS9viytHb3YeXjdnv/7ORt6VPD8aqdy9HZ7vBkf75VYDwrts9KnycwJ2hn6e4E6XL/
tcT960/HCwUb6F5zo3e5WUM6ATRmDvYA4ATAvrd9MH+zdbkyagKdPy0qz935wtYlniPV+YAOrHYl
v3DZvInxC3FcI36jukn7fPxH7fjT5oHXqfU3VtfPqh3vptPZ3Nje3Fy5tKtr1U5ttdrdry7Y1T/e
+JsLha3F+U7e2/jUOVo6Kx4dQok/Vjqdr92ry929T5/Wqt8ALPvNm/VPp2ufP336o3azsKLQbn9z
fWX107faZHv1ZqNaPKpVb7d7OiyApg/28dzpfKIzCHBuo9dtfNjuHPWXroEmr306rDrrN4W7ncvq
/PZa83Z37dM32Lc2Pttdw2ent7uH/Gy79ul2/Vv180pn5/NK1Ttcu1LPoJvOUe3j2vbB1Q2sPI4X
dtmKOt5OcG4o4zoi+gDr+W3lbHtle2Pl7uvGwfb8EsBqY3VVfL+pfagWNqsrH7uLq/3rraOVzvr6
zlHh+uiP3u7ncW2xddkqvtlaOJjcnBS2nP66669sz7WuWvm55t3l7Xp17pO3cDC/2D4p5N3uaeHz
2Zt+u7H0x/qbwtx4YffyeG3leLs6jzBsrd3UVvI3n2rVm80PnTWe64eDo9raZXV7peONVjq1WvV0
zzvpbK5sVwnurRrXWQWCfvMB575fuFxZ6dyse9Wjb70P7srm+u7Zun/5enev9m3Bez3Y/nBysr15
s9o53fzDO9v8dlmA/rbXzm6qN2fVzZvtk+3W+sf5FWe8tfX59M3u/qS2NPC+NhrVs92zQd6ujk7u
Dm/Wq2ftP0Z7327XS9d73seddvH10WqrUzzZqF6u3JwUv7WWjje+nl597QNk1r/eFD/dHVyOit8+
tocft5deF0cw14O9re3dvd3LPybuyaV3lB8eHTkbS/s3feCXVrpn61c7g070lPr5+fn5+fn5+fn5
+fn5+fn5+fn5+fn5+fn5+fn5+fn5+fn5//Kzd3b6afete3eV3zwZ7bmXn8eLb0pHW9+2t3pf14+O
a/Mnf7z9PHJ2+lef1uzS19e71cnqzo17fDxovv3q9e9216vH3d2VP5b2PrQ+TSZz1eFu1R56rbO3
lXd5/U74XT68LcZr+Pc/3iopav/Bvl/dcb/34/p4xP9rYWGuEPX/mltY/Gn/8U983v2ytrt6eLpX
M3DN36fe4R+jZw86FdMZmPjAsVvvyXKObBcwPs3Id8YV8+hwPffWNPLqS3T6rphoLEKxcg3hwlIx
2Q6k5aCrNRuFYEhfF1Pg5fym3XMqxbCpsTvuOe/VwBPv8vyM35OJ9MjpYZDuu57jdx0H+uqOnHbF
1BwYwyY5vJnhj5pQib7LYpdQqoV+YLjH6A1MOs+zfoemjaKFlnttuK2KybacJqfYDX923VbLGUAb
UO59SnTKvj/vAycqakRUVB2DzLAIFeuW3st5w1f9nTDMRzd76J1+mDQwu9VaGcOSVVsiPs67PL9W
+ufRBT+HcjDoOmS+lxEG0Bkfo+yMPUMEf3vpy6A5HQ9tW2w0gTZgcTnshwjdxmWtd/mh0gc7wuAA
2XH/EH9HJzwOsUx/Dqsy7r7fAbQCFOjSjyqnBg5+H5CfQ/CTv+Shpt5FPqGPd+zaEw5uBX6a08aB
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
__QBT_SAMBA_PAYLOAD_END__
)"

main "$@"
