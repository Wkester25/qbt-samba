#!/usr/bin/env python3
"""qbt-samba: mounts Samba (SMB/CIFS) shares for qBittorrent and exposes a
small HTTP API that the qBittorrent WebUI "Samba" tab talks to.

Runs as root inside the qBittorrent LXC (mounting needs root). Every API
request must carry a valid qBittorrent WebUI session cookie: the service
checks it against qBittorrent's own API, so only people who can log in to
the WebUI can manage shares.

Standard library only, Python 3.9+.
"""

import argparse
import http.client
import ipaddress
import json
import logging
import os
import re
import subprocess
import tempfile
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

log = logging.getLogger("qbt-samba")

DEFAULT_CONFIG = {
    "listen_host": "0.0.0.0",
    "listen_port": 8099,
    # Where qBittorrent's WebUI listens, as seen from inside the LXC.
    "qbt_url": "http://127.0.0.1:8090",
    # Browser origins allowed to call this API (the WebUI address). Empty
    # list means "derive from the request's Host header + qbt port".
    "allowed_origins": [],
    "mount_root": "/mnt/samba",
    # Owner of files on the mounted share; must be the user qbittorrent runs as.
    "uid": 0,
    "gid": 0,
    "file_mode": "0664",
    "dir_mode": "0775",
    # How often (seconds) to check mounts and remount any that dropped.
    "watch_interval": 60,
    "tls_cert": "",
    "tls_key": "",
}

NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$")
HOST_RE = re.compile(r"^(?=.{1,253}$)[A-Za-z0-9]([A-Za-z0-9-]{0,62}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,62}[A-Za-z0-9])?)*$")
# SMB share path: share name plus optional sub folders. No "..", no control chars.
SHARE_RE = re.compile(r"^[^\\/\x00-\x1f\"*:<>?|]+(/[^\\/\x00-\x1f\"*:<>?|]+)*$")
USER_RE = re.compile(r"^[^\x00-\x1f,=]{1,256}$")
VERS_ALLOWED = {"", "default", "1.0", "2.0", "2.1", "3.0", "3.02", "3.1.1", "3"}


class ApiError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


# --------------------------------------------------------------------------
# Validation
# --------------------------------------------------------------------------

def validate_share(data, require_password=True):
    if not isinstance(data, dict):
        raise ApiError(400, "Expected a JSON object")
    name = str(data.get("name", "")).strip()
    server = str(data.get("server", "")).strip()
    share = str(data.get("share", "")).strip().replace("\\", "/").strip("/")
    username = str(data.get("username", ""))
    password = data.get("password")
    version = str(data.get("version", "") or "").strip()

    if not NAME_RE.match(name):
        raise ApiError(400, "Name must be 1-32 letters, numbers, - or _, starting with a letter or number")
    if not _valid_host(server):
        raise ApiError(400, "Server must be a hostname or IP address")
    if not share or not SHARE_RE.match(share) or any(p in (".", "..") for p in share.split("/")):
        raise ApiError(400, "Share must be a share name, optionally followed by /sub/folder")
    if not USER_RE.match(username):
        raise ApiError(400, "Username is required and can't contain commas, = or control characters")
    if password is None:
        if require_password:
            raise ApiError(400, "Password is required")
    else:
        password = str(password)
        if len(password) > 256 or any(c in password for c in "\r\n\x00"):
            raise ApiError(400, "Password can't contain line breaks and must be at most 256 characters")
    if version not in VERS_ALLOWED:
        raise ApiError(400, "SMB version must be one of: " + ", ".join(sorted(v for v in VERS_ALLOWED if v)))
    if version == "default":
        version = ""
    return {
        "name": name,
        "server": server,
        "share": share,
        "username": username,
        "password": password,
        "version": version,
        "enabled": bool(data.get("enabled", True)),
    }


def _valid_host(host):
    try:
        ipaddress.ip_address(host)
        return True
    except ValueError:
        return bool(HOST_RE.match(host))


# --------------------------------------------------------------------------
# Mounting
# --------------------------------------------------------------------------

class Runner:
    """Runs system commands. Replaced by a fake in tests."""

    def run(self, args, timeout=30):
        return subprocess.run(args, capture_output=True, text=True, timeout=timeout)

    def is_mounted(self, path):
        real = os.path.realpath(path)
        try:
            with open("/proc/self/mounts") as f:
                for line in f:
                    parts = line.split()
                    if len(parts) > 2 and _unescape_mount(parts[1]) == real:
                        return True
        except OSError:
            pass
        return False


def _unescape_mount(s):
    return re.sub(r"\\([0-7]{3})", lambda m: chr(int(m.group(1), 8)), s)


def _cifs_error(stderr):
    text = (stderr or "").strip()
    hints = {
        "error(13)": "Access denied: check the username and password",
        "error(2)": "Share not found on that server",
        "error(112)": "Server unreachable (host down)",
        "error(113)": "Server unreachable (no route to host)",
        "error(115)": "Server did not answer in time",
        "error(95)": "SMB version not supported by the server; try another version",
        "error(1)": "Mount not permitted: is the LXC privileged with the cifs mount feature enabled?",
        "Operation not permitted": "Mount not permitted: is the LXC privileged with the cifs mount feature enabled?",
        "wrong fs type": "cifs-utils is missing; run the installer again",
        "unknown filesystem type": "This system can't mount Samba shares (no CIFS support in the kernel or cifs-utils missing)",
    }
    for key, hint in hints.items():
        if key in text:
            detail = [l.strip() for l in text.splitlines() if l.strip() and "dmesg" not in l]
            return hint + (" (" + detail[0] + ")" if detail else "")
    return text or "Mount failed"


class ShareManager:
    def __init__(self, config, state_dir, runner=None):
        self.config = config
        self.state_dir = state_dir
        self.creds_dir = os.path.join(state_dir, "credentials")
        self.shares_file = os.path.join(state_dir, "shares.json")
        self.runner = runner or Runner()
        self.lock = threading.RLock()
        self.last_error = {}
        os.makedirs(self.creds_dir, mode=0o700, exist_ok=True)
        os.chmod(state_dir, 0o700)
        os.chmod(self.creds_dir, 0o700)
        self.shares = self._load()

    # ---- persistence -----------------------------------------------------

    def _load(self):
        try:
            with open(self.shares_file) as f:
                data = json.load(f)
            return {s["name"]: s for s in data.get("shares", [])}
        except FileNotFoundError:
            return {}

    def _save(self):
        _atomic_write(self.shares_file, json.dumps({"shares": list(self.shares.values())}, indent=2))

    def _creds_path(self, name):
        return os.path.join(self.creds_dir, name)

    def _write_creds(self, name, username, password):
        _atomic_write(self._creds_path(name), "username={}\npassword={}\n".format(username, password))

    def mount_point(self, name):
        return os.path.join(self.config["mount_root"], name)

    # ---- public API ------------------------------------------------------

    def list(self):
        with self.lock:
            return [self._public(s) for s in sorted(self.shares.values(), key=lambda s: s["name"])]

    def get(self, name):
        with self.lock:
            share = self.shares.get(name)
            if not share:
                raise ApiError(404, "No share named " + name)
            return share

    def add(self, data):
        share = validate_share(data, require_password=True)
        with self.lock:
            if share["name"] in self.shares:
                raise ApiError(409, "A share named {} already exists".format(share["name"]))
            password = share.pop("password")
            self._write_creds(share["name"], share["username"], password)
            self.shares[share["name"]] = share
            self._save()
            self._prepare_mount_point(share["name"])
            if share["enabled"]:
                self._try_mount(share)
            return self._public(share)

    def update(self, name, data):
        with self.lock:
            old = self.get(name)
            merged = dict(old)
            merged.update({k: v for k, v in data.items() if k != "name"})
            merged["name"] = name
            if not data.get("password"):
                merged["password"] = None
            share = validate_share(merged, require_password=False)
            password = share.pop("password")
            if password is None and share["username"] != old["username"]:
                raise ApiError(400, "Enter the password again when you change the username")
            if self.runner.is_mounted(self.mount_point(name)):
                self._unmount(name)
            if password is not None:
                self._write_creds(name, share["username"], password)
            self.shares[name] = share
            self._save()
            if share["enabled"]:
                self._try_mount(share)
            return self._public(share)

    def delete(self, name):
        with self.lock:
            self.get(name)
            if self.runner.is_mounted(self.mount_point(name)):
                self._unmount(name)
            del self.shares[name]
            self._save()
            try:
                os.remove(self._creds_path(name))
            except FileNotFoundError:
                pass
            self._remove_mount_point(name)
            self.last_error.pop(name, None)

    def mount(self, name):
        with self.lock:
            share = self.get(name)
            share["enabled"] = True
            self._save()
            self._prepare_mount_point(name)
            if not self._try_mount(share):
                raise ApiError(502, self.last_error.get(name, "Mount failed"))
            return self._public(share)

    def unmount(self, name):
        with self.lock:
            share = self.get(name)
            share["enabled"] = False
            self._save()
            if self.runner.is_mounted(self.mount_point(name)):
                self._unmount(name)
            return self._public(share)

    def test(self, data):
        """Try a share's settings with a throwaway mount, without saving them."""
        if isinstance(data, dict) and data.get("name") in self.shares and not data.get("password"):
            # Testing a saved share: reuse its stored password.
            saved = self.shares[data["name"]]
            merged = dict(saved)
            merged.update({k: v for k, v in data.items() if v not in (None, "")})
            merged["password"] = None
            share = validate_share(merged, require_password=False)
            if share["username"] != saved["username"]:
                raise ApiError(400, "Enter the password to test a different username")
            return self._test_mount(share, creds_file=self._creds_path(share["name"]))
        if isinstance(data, dict) and not data.get("name"):
            data = dict(data, name="test")
        share = validate_share(data, require_password=True)
        with tempfile.NamedTemporaryFile("w", dir=self.state_dir, prefix=".test-", delete=False) as f:
            os.chmod(f.name, 0o600)
            f.write("username={}\npassword={}\n".format(share["username"], share["password"]))
            creds = f.name
        try:
            return self._test_mount(share, creds_file=creds)
        finally:
            os.remove(creds)

    def mount_all(self):
        with self.lock:
            for share in self.shares.values():
                if share["enabled"]:
                    self._prepare_mount_point(share["name"])
                    self._try_mount(share)

    def check_mounts(self):
        """Remount enabled shares that dropped (server reboot, network blip)."""
        with self.lock:
            for share in self.shares.values():
                if share["enabled"] and not self.runner.is_mounted(self.mount_point(share["name"])):
                    log.warning("Share %s is not mounted; remounting", share["name"])
                    self._try_mount(share)

    # ---- internals -------------------------------------------------------

    def _public(self, share):
        out = {k: v for k, v in share.items() if k != "password"}
        out["path"] = self.mount_point(share["name"])
        out["mounted"] = self.runner.is_mounted(out["path"])
        out["error"] = None if out["mounted"] else self.last_error.get(share["name"])
        return out

    def _options(self, share, creds_file):
        c = self.config
        opts = [
            "credentials=" + creds_file,
            "uid={}".format(int(c["uid"])),
            "gid={}".format(int(c["gid"])),
            "file_mode=" + c["file_mode"],
            "dir_mode=" + c["dir_mode"],
            "iocharset=utf8",
            "nobrl",  # byte-range locks break some NAS servers with torrent writes
            "_netdev",
        ]
        if share.get("version"):
            opts.append("vers=" + share["version"])
        return ",".join(opts)

    def _source(self, share):
        return "//{}/{}".format(share["server"], share["share"])

    def _mount_cmd(self, share, target, creds_file):
        return ["mount", "-t", "cifs", self._source(share), target, "-o", self._options(share, creds_file)]

    def _try_mount(self, share):
        name = share["name"]
        target = self.mount_point(name)
        if self.runner.is_mounted(target):
            self.last_error.pop(name, None)
            return True
        res = self.runner.run(self._mount_cmd(share, target, self._creds_path(name)))
        if res.returncode == 0:
            log.info("Mounted %s at %s", self._source(share), target)
            self.last_error.pop(name, None)
            return True
        self.last_error[name] = _cifs_error(res.stderr)
        log.error("Mounting %s failed: %s", name, self.last_error[name])
        return False

    def _unmount(self, name):
        res = self.runner.run(["umount", self.mount_point(name)])
        if res.returncode != 0:
            raise ApiError(409, "Couldn't unmount {}: {} (is a download still writing to it?)".format(
                name, (res.stderr or "").strip()))

    def _test_mount(self, share, creds_file):
        target = tempfile.mkdtemp(prefix="test-", dir=self.state_dir)
        try:
            res = self.runner.run(self._mount_cmd(share, target, creds_file))
            if res.returncode != 0:
                return {"ok": False, "message": _cifs_error(res.stderr)}
            try:
                probe = os.path.join(target, ".qbt-samba-write-test")
                with open(probe, "w") as f:
                    f.write("ok")
                os.remove(probe)
                return {"ok": True, "message": "Connected and able to write"}
            except OSError as e:
                return {"ok": False, "message": "Connected, but can't write to the share: " + e.strerror}
            finally:
                self.runner.run(["umount", target])
        finally:
            try:
                os.rmdir(target)
            except OSError:
                pass

    def _prepare_mount_point(self, name):
        path = self.mount_point(name)
        if self.runner.is_mounted(path):
            return
        os.makedirs(path, exist_ok=True)
        # Make the empty mount point immutable so that, if the share is ever
        # not mounted, qBittorrent gets a write error instead of silently
        # filling the container's own disk. Mounting over it still works.
        self.runner.run(["chattr", "+i", path])

    def _remove_mount_point(self, name):
        path = self.mount_point(name)
        self.runner.run(["chattr", "-i", path])
        try:
            os.rmdir(path)
        except OSError:
            pass


def _atomic_write(path, text):
    d = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".tmp-")
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(text)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise


# --------------------------------------------------------------------------
# qBittorrent session check
# --------------------------------------------------------------------------

class QbtAuth:
    """Checks a browser's cookies against qBittorrent's WebUI login."""

    CACHE_SECONDS = 30

    def __init__(self, qbt_url):
        u = urllib.parse.urlsplit(qbt_url)
        self.scheme = u.scheme
        self.host = u.hostname
        self.port = u.port or (443 if u.scheme == "https" else 80)
        self.cache = {}
        self.lock = threading.Lock()

    def _status(self, cookie):
        if self.scheme == "https":
            import ssl
            # The WebUI is reached on the container's own address, often with
            # a self-signed certificate.
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            conn = http.client.HTTPSConnection(self.host, self.port, timeout=5, context=ctx)
        else:
            conn = http.client.HTTPConnection(self.host, self.port, timeout=5)
        headers = {"Cookie": cookie} if cookie else {}
        try:
            conn.request("GET", "/api/v2/app/version", headers=headers)
            return conn.getresponse().status
        finally:
            conn.close()

    def bypassed(self):
        """True if qBittorrent lets this service in without logging in, which
        would make every request look authenticated."""
        return self._status("") == 200

    def check(self, cookie):
        if not cookie:
            return False
        now = time.monotonic()
        with self.lock:
            hit = self.cache.get(cookie)
            if hit and hit > now:
                return True
        try:
            if self.bypassed():
                raise ApiError(503, "qBittorrent lets this service in without a login (authentication bypass "
                                    "for localhost or a whitelisted subnet). Turn that off, or set qbt_url to "
                                    "an address that isn't bypassed.")
            ok = self._status(cookie) == 200
        except OSError as e:
            raise ApiError(503, "Can't reach qBittorrent at {}://{}:{} ({})".format(
                self.scheme, self.host, self.port, e))
        if ok:
            with self.lock:
                self.cache = {k: v for k, v in self.cache.items() if v > now}
                self.cache[cookie] = now + self.CACHE_SECONDS
        return ok


# --------------------------------------------------------------------------
# HTTP API
# --------------------------------------------------------------------------

def make_handler(manager, auth, config):
    qbt_port = urllib.parse.urlsplit(config["qbt_url"]).port or 8090

    class Handler(BaseHTTPRequestHandler):
        server_version = "qbt-samba"
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):
            log.info("%s %s", self.address_string(), fmt % args)

        # ---- CORS / origin ----------------------------------------------

        def _allowed_origin(self):
            origin = self.headers.get("Origin")
            if not origin:
                return None
            allowed = config.get("allowed_origins") or []
            if origin in allowed:
                return origin
            if not allowed:
                # Default: the WebUI on the same host name, qBittorrent's port.
                host = (self.headers.get("Host") or "").rsplit(":", 1)[0]
                for scheme in ("http", "https"):
                    if origin == "{}://{}:{}".format(scheme, host, qbt_port):
                        return origin
            return None

        def _send(self, status, body=None):
            data = b"" if body is None else json.dumps(body).encode()
            self.send_response(status)
            origin = self._allowed_origin()
            if origin:
                self.send_header("Access-Control-Allow-Origin", origin)
                self.send_header("Access-Control-Allow-Credentials", "true")
                self.send_header("Vary", "Origin")
            self.send_header("Content-Type", "application/json")
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_OPTIONS(self):
            origin = self._allowed_origin()
            self.send_response(204 if origin else 403)
            if origin:
                self.send_header("Access-Control-Allow-Origin", origin)
                self.send_header("Access-Control-Allow-Credentials", "true")
                self.send_header("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE")
                self.send_header("Access-Control-Allow-Headers", "Content-Type")
                self.send_header("Access-Control-Max-Age", "600")
                self.send_header("Vary", "Origin")
            self.send_header("Content-Length", "0")
            self.end_headers()

        def do_GET(self):
            self._dispatch("GET")

        def do_POST(self):
            self._dispatch("POST")

        def do_PUT(self):
            self._dispatch("PUT")

        def do_DELETE(self):
            self._dispatch("DELETE")

        # ---- routing ------------------------------------------------------

        def _body(self):
            length = int(self.headers.get("Content-Length") or 0)
            if length > 64 * 1024:
                raise ApiError(413, "Request too large")
            raw = self.rfile.read(length) if length else b""
            if not raw:
                return {}
            if not (self.headers.get("Content-Type") or "").startswith("application/json"):
                raise ApiError(415, "Send JSON")
            try:
                return json.loads(raw)
            except ValueError:
                raise ApiError(400, "Invalid JSON")

        def _dispatch(self, method):
            try:
                path = urllib.parse.urlsplit(self.path).path.rstrip("/")
                if path == "/api/health":
                    return self._send(200, {"ok": True})

                # State-changing requests from a browser must come from the WebUI.
                if method != "GET" and self.headers.get("Origin") and not self._allowed_origin():
                    raise ApiError(403, "Origin not allowed")
                if method != "GET" and not self.headers.get("Origin"):
                    # Browsers always send Origin on cross-origin writes; refuse
                    # writes without it so forms on other sites can't post here.
                    raise ApiError(403, "Missing Origin header")
                if not auth.check(self.headers.get("Cookie", "")):
                    raise ApiError(401, "Log in to the qBittorrent WebUI first")

                body = self._body() if method in ("POST", "PUT") else None
                parts = [urllib.parse.unquote(p) for p in path.split("/")[1:]]

                if parts == ["api", "shares"]:
                    if method == "GET":
                        return self._send(200, {"shares": manager.list()})
                    if method == "POST":
                        return self._send(201, manager.add(body))
                elif parts == ["api", "test"] and method == "POST":
                    return self._send(200, manager.test(body))
                elif parts == ["api", "status"] and method == "GET":
                    return self._send(200, {"mount_root": config["mount_root"], "shares": manager.list()})
                elif len(parts) == 3 and parts[:2] == ["api", "shares"]:
                    name = parts[2]
                    if method == "GET":
                        return self._send(200, manager._public(manager.get(name)))
                    if method == "PUT":
                        return self._send(200, manager.update(name, body))
                    if method == "DELETE":
                        manager.delete(name)
                        return self._send(200, {"deleted": name})
                elif len(parts) == 4 and parts[:2] == ["api", "shares"] and method == "POST":
                    name, action = parts[2], parts[3]
                    if action == "mount":
                        return self._send(200, manager.mount(name))
                    if action == "unmount":
                        return self._send(200, manager.unmount(name))
                raise ApiError(404, "Not found")
            except ApiError as e:
                self._send(e.status, {"error": e.message})
            except Exception:
                log.exception("Unhandled error")
                self._send(500, {"error": "Internal error; see journalctl -u qbt-samba"})

    return Handler


# --------------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------------

def load_config(path):
    config = dict(DEFAULT_CONFIG)
    try:
        with open(path) as f:
            config.update(json.load(f))
    except FileNotFoundError:
        log.warning("No config at %s; using defaults", path)
    return config


def watch(manager, interval, stop):
    while not stop.wait(interval):
        try:
            manager.check_mounts()
        except Exception:
            log.exception("Mount check failed")


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--config", default="/etc/qbt-samba/config.json")
    p.add_argument("--state-dir", default="/etc/qbt-samba")
    p.add_argument("--mount-only", action="store_true",
                   help="Mount all enabled shares and exit (used before qBittorrent starts)")
    args = p.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")

    config = load_config(args.config)
    manager = ShareManager(config, args.state_dir)
    manager.mount_all()
    if args.mount_only:
        return

    auth = QbtAuth(config["qbt_url"])
    httpd = ThreadingHTTPServer((config["listen_host"], int(config["listen_port"])),
                                make_handler(manager, auth, config))
    if config.get("tls_cert") and config.get("tls_key"):
        import ssl
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(config["tls_cert"], config["tls_key"])
        httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)

    stop = threading.Event()
    threading.Thread(target=watch, args=(manager, int(config["watch_interval"]), stop), daemon=True).start()
    log.info("Listening on %s:%s", config["listen_host"], config["listen_port"])
    try:
        httpd.serve_forever()
    finally:
        stop.set()


if __name__ == "__main__":
    main()
