# qbt-samba

Save qBittorrent downloads straight to Samba (SMB/CIFS) shares on your network,
managed from a **Samba Shares** window in the qBittorrent WebUI. Each share
uses a username and password.

Built for qBittorrent installed in a Proxmox LXC with the
[community-scripts qBittorrent script](https://community-scripts.org/scripts/qbittorrent)
(`qbittorrent-nox` running as a systemd service). It should also work on any
Debian or Ubuntu system where qbittorrent-nox runs as a systemd service.

## Install on Proxmox (one command)

Run this in the **Proxmox host shell** (Datacenter > your node > Shell), as root:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Wkester25/qbt-samba/main/qbt-stack-proxmox.sh)"
```

It creates a new Debian 13 LXC and installs qBittorrent-nox, Jackett and the
Samba Shares add-on inside it. Nothing else to download or copy. It first shows
the default settings; choose **No** to change any of them:

| Setting | Default |
| --- | --- |
| Container ID | next free ID |
| Hostname | `qbittorrent` |
| CPU / RAM / disk | 2 cores / 2048 MiB / 8 GiB |
| Storage | asks if you have more than one |
| Network | `vmbr0`, DHCP (static IP and VLAN optional) |
| Privileged | yes, with CIFS mounts allowed (needed for Samba shares) |
| Root password | none; the Proxmox console logs in automatically |
| WebUI login | `admin`, random password shown at the end |
| Search tool | Jackett (Prowlarr, both or none also offered) |

At the end it prints the WebUI address and login, and Jackett's API key.

Unattended: set any of these and add `-y`, for example
`CTID=120 CT_IP=192.168.1.50/24 CT_GW=192.168.1.1 QBT_WEBUI_PASS=secret bash qbt-stack-proxmox.sh -y`.
The variables are listed at the top of `proxmox/ct-template.sh`.

A privileged container is less isolated from the Proxmox host, so only run
software you trust in it. Linux doesn't let unprivileged containers mount Samba
shares, so there's no way around it for this add-on.

Already have a qBittorrent LXC? Skip this and run `install-all.sh` inside it
(next sections).

## What you get

- **Tools > Samba Shares...** in the WebUI menu, plus a toolbar button next to Options.
- Add a share with its server, share name, username and password. **Test connection**
  mounts it briefly and checks it can write before you save.
- Each share is mounted at `/mnt/samba/<name>`, and qBittorrent writes to it directly.
- **Use for downloads** makes a share qBittorrent's default save folder, and turns off
  "Keep incomplete torrents in" so unfinished downloads go to the share too.
  **Add category** creates a category with the same name that saves to the share
  (unfinished downloads included).
- Mount, unmount, edit or remove shares from the same window.

## How it works

- `qbt-samba` is a small service inside the LXC (Python, standard library only).
  It mounts shares with the kernel CIFS client and runs an API on port 8099 for
  the WebUI window.
- Passwords live in `/etc/qbt-samba/credentials/<name>` (root only, mode 600),
  never in qBittorrent's config, the share list, logs or the mount command line.
- Shares mount before qBittorrent starts, and are remounted automatically if the
  connection drops (checked every 60 seconds).
- If a share isn't mounted, its empty folder is locked (`chattr +i`). qBittorrent
  then gets a write error instead of quietly filling the container's own disk.
- The API only answers people logged in to the qBittorrent WebUI: it checks your
  WebUI session cookie with qBittorrent itself, and only accepts changes sent
  from the WebUI's own address.
- The window is added to the stock WebUI using qBittorrent's built-in
  "alternative WebUI" setting. The installer downloads the stock WebUI files that
  match your qBittorrent version and adds the Samba window to them.

## Quick start: everything in one script

`install-all.sh` sets up a whole download box in one go, community-scripts style:

- **qBittorrent-nox** (latest static build, runs as its own `qbittorrent` user, WebUI on port 8090),
- **Jackett** (port 9117), already plugged into qBittorrent's **Search** tab,
- the **Samba Shares** add-on from this folder.

```bash
git clone https://github.com/Wkester25/qbt-samba /root/qbt-samba   # or extract qbt-samba.tar.gz into /root
bash /root/qbt-samba/install-all.sh          # asks a few questions
bash /root/qbt-samba/install-all.sh -y       # takes every default
```

It asks for the WebUI username, password (random if left empty), port, download
folder, which search tool to install, and whether to add Samba Shares. At the end
it prints the URLs, the WebUI login and Jackett's API key. Run it with `--help`
for the unattended options (`--indexer`, `--no-samba`, `--webui-pass`, `--qbt-tag`
and more).

**Why Jackett:** qBittorrent ships an official Jackett search plugin, so every
tracker you add in Jackett shows up in qBittorrent's Search tab with no extra
setup. Prowlarr is the better pick if you also run Sonarr or Radarr, so the
installer offers it too (`--indexer prowlarr` or `both`), but it doesn't plug
into qBittorrent's Search tab.

It's safe to run again. If qBittorrent is already installed (for example by the
community-scripts qBittorrent LXC), it's kept as it is, with its settings and
login, and Jackett and Samba Shares are added to it.

After it finishes:

1. Open Jackett, set an admin password (it's open to your network until you do), and add your trackers.
2. Search from qBittorrent's **Search** tab.
3. Add a share under **Tools > Samba Shares...**. Shares only mount in a privileged LXC (step 1 below).

qBittorrent 5.3 and later need Python 3.13 for the Search tab. Debian 12 and
Ubuntu 24.04 have older ones, so on those the installer puts a self-contained
Python 3.13 in `/opt/qbt-python` (checksum verified) and points only qBittorrent
at it. Debian 13 already has 3.13.

## 1. Proxmox setup (once, on the Proxmox host)

Linux doesn't let unprivileged containers mount Samba shares, and the community
script creates unprivileged containers. Proxmox can't change this in place, so
you back the container up and restore it as privileged. Replace `105` with your
container ID.

```bash
pct stop 105
vzdump 105 --mode stop --storage local --compress zstd
# Restore over the same ID as privileged (use the file name vzdump printed):
pct restore 105 /var/lib/vz/dump/vzdump-lxc-105-<date>.tar.zst --unprivileged 0 --force
# Allow CIFS mounts inside the container:
pct set 105 --features mount=cifs
pct start 105
```

Privileged containers are less isolated from the Proxmox host, so only run
software you trust in this one. Keep the backup until everything works.

## 2. Install (inside the LXC)

Copy `qbt-samba.tar.gz` to the Proxmox host, then:

```bash
pct push 105 qbt-samba.tar.gz /root/qbt-samba.tar.gz
pct enter 105
tar xzf /root/qbt-samba.tar.gz -C /root
bash /root/qbt-samba/install.sh
```

The installer:

1. installs `cifs-utils`,
2. finds your qBittorrent service, the user it runs as and its WebUI port,
3. installs and starts the `qbt-samba` service,
4. makes qBittorrent wait for the shares to mount at startup,
5. downloads the stock WebUI for your qBittorrent version from GitHub, adds the
   Samba window, and switches qBittorrent to it (qBittorrent restarts once).

Then reload the WebUI and open **Tools > Samba Shares...**.

**Check this qBittorrent setting:** under *Options > Web UI > Authentication*,
"Bypass authentication for clients on localhost" must be **off**. If it's on,
the service can't tell who is logged in, so it refuses every request and the
window says why.

### Updating the add-on

Run this on the Proxmox host (replace `105` with your container ID):

```bash
pct exec 105 -- bash -c "$(curl -fsSL https://raw.githubusercontent.com/Wkester25/qbt-samba/main/update.sh)"
```

Or, inside the container, run `bash /root/qbt-samba/update.sh`. Your shares, passwords and
qBittorrent settings are kept. qBittorrent restarts during the update, so reload
the WebUI page afterwards (Ctrl+Shift+R) and log in again.

### After a qBittorrent upgrade

The window is built from the WebUI of the version you had at install time. After
upgrading qBittorrent, run `bash /root/qbt-samba/install-webui.sh` to rebuild it
for the new version.

## Troubleshooting

| What you see | What to do |
| --- | --- |
| "Mount not permitted" | The LXC is still unprivileged, or `mount=cifs` isn't set. See step 1. |
| "Access denied" | Check the username and password. Try them from another computer. |
| "SMB version not supported" | Pick a different SMB version in the share's settings. Very old NAS boxes may need 1.0. |
| "Can't reach the Samba service" | `systemctl status qbt-samba` and `journalctl -u qbt-samba -f` |
| Window or menu item missing | Run `bash /root/qbt-samba/install-webui.sh` again, then hard-reload the browser. |

To go back to the built-in WebUI: `bash /root/qbt-samba/install-webui.sh --disable`.
To remove everything: `bash /root/qbt-samba/uninstall.sh`.

## Notes and limits

- The rebuilt WebUI is in English (the stock WebUI's translations are filled in
  by qBittorrent only for its built-in UI).
- If the WebUI uses HTTPS, set `tls_cert` and `tls_key` in
  `/etc/qbt-samba/config.json` (the same files qBittorrent uses), then
  `systemctl restart qbt-samba`. Otherwise the browser blocks the window's calls.
- Port 8099 must be reachable from your browser, the same way the WebUI port is.
- Tested end to end against qBittorrent 4.6.3 (menu, window, login check, API,
  categories) and 5.3.1 (fresh install with `install-all.sh` on Ubuntu 24.04:
  login, Samba window, Jackett search plugin). Real Samba mounting is covered by
  unit tests but was not tried on a real share yet.
- qBittorrent 5.x moved its WebUI settings to a `[WebUI]` section of
  `qBittorrent.conf`; the installers read and write whichever layout your version uses.

## Files

| Path | Purpose |
| --- | --- |
| `qbt_samba/server.py` | The service: mounting, remount watcher, API |
| `webui/` | The Samba window and the script that adds it to the menu |
| `qbt-stack-proxmox.sh` | Proxmox host script: creates the LXC and runs `install-all.sh` in it (built file, add-on bundled inside) |
| `proxmox/ct-template.sh`, `proxmox/build.sh` | Source of the host script; run `bash proxmox/build.sh` after changing any add-on file |
| `install-all.sh` | One-shot installer inside a container: qBittorrent-nox + Jackett/Prowlarr + this add-on |
| `install.sh`, `install-webui.sh`, `update.sh`, `uninstall.sh` | Add-on setup, update and removal |
| `systemd/` | Service files |
| `tests/test_server.py` | Unit tests: `python3 -m unittest tests.test_server` |

## API

All calls need a qBittorrent WebUI session cookie. Changes must come from the
WebUI's own address.

| Method | Path | What it does |
| --- | --- | --- |
| GET | `/api/shares` | List shares and whether each is mounted |
| POST | `/api/shares` | Add a share: `name, server, share, username, password, version?` |
| PUT | `/api/shares/<name>` | Edit; leave `password` empty to keep the saved one |
| DELETE | `/api/shares/<name>` | Unmount and remove |
| POST | `/api/shares/<name>/mount` | Mount and keep mounted |
| POST | `/api/shares/<name>/unmount` | Unmount and stop remounting |
| POST | `/api/test` | Try settings with a throwaway mount and write test |
| GET | `/api/health` | Liveness check (no login needed) |
