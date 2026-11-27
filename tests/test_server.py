import http.client
import json
import os
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from types import SimpleNamespace

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "qbt_samba"))
import server  # noqa: E402


class FakeRunner:
    """Pretends to mount: records commands, 'mounts' by tracking paths."""

    def __init__(self):
        self.mounted = set()
        self.calls = []
        self.fail_with = None  # stderr to return for mount

    def run(self, args, timeout=30):
        self.calls.append(args)
        if args[0] == "mount":
            if self.fail_with:
                return SimpleNamespace(returncode=32, stderr=self.fail_with, stdout="")
            self.mounted.add(args[4])
        elif args[0] == "umount":
            self.mounted.discard(args[1])
        return SimpleNamespace(returncode=0, stderr="", stdout="")

    def is_mounted(self, path):
        return path in self.mounted


GOOD = {"name": "media", "server": "192.168.1.10", "share": "Media/Downloads",
        "username": "whit", "password": "s3cret!"}


class ManagerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.state = os.path.join(self.tmp, "state")
        os.makedirs(self.state)
        cfg = dict(server.DEFAULT_CONFIG, mount_root=os.path.join(self.tmp, "mnt"), uid=1000, gid=1000)
        self.runner = FakeRunner()
        self.m = server.ShareManager(cfg, self.state, runner=self.runner)

    def test_add_mounts_and_hides_password(self):
        out = self.m.add(dict(GOOD))
        self.assertTrue(out["mounted"])
        self.assertNotIn("password", out)
        cmd = [c for c in self.runner.calls if c[0] == "mount"][0]
        self.assertEqual(cmd[3], "//192.168.1.10/Media/Downloads")
        self.assertIn("uid=1000", cmd[6])
        self.assertNotIn("s3cret", " ".join(cmd))  # password only in the creds file
        creds = os.path.join(self.state, "credentials", "media")
        self.assertEqual(open(creds).read(), "username=whit\npassword=s3cret!\n")
        self.assertEqual(os.stat(creds).st_mode & 0o777, 0o600)
        saved = open(os.path.join(self.state, "shares.json")).read()
        self.assertNotIn("s3cret", saved)

    def test_persists_and_remounts(self):
        self.m.add(dict(GOOD))
        self.runner.mounted.clear()
        m2 = server.ShareManager(self.m.config, self.state, runner=self.runner)
        m2.mount_all()
        self.assertTrue(m2.list()[0]["mounted"])

    def test_check_mounts_remounts_dropped_share(self):
        self.m.add(dict(GOOD))
        self.runner.mounted.clear()
        self.m.check_mounts()
        self.assertTrue(self.m.list()[0]["mounted"])

    def test_unmount_disables(self):
        self.m.add(dict(GOOD))
        out = self.m.unmount("media")
        self.assertFalse(out["mounted"])
        self.assertFalse(out["enabled"])
        self.m.check_mounts()
        self.assertFalse(self.m.list()[0]["mounted"])

    def test_mount_error_is_explained(self):
        self.runner.fail_with = "mount error(13): Permission denied"
        out = self.m.add(dict(GOOD))
        self.assertFalse(out["mounted"])
        self.assertIn("username and password", out["error"])
        with self.assertRaises(server.ApiError):
            self.m.mount("media")

    def test_update_keeps_password_when_blank(self):
        self.m.add(dict(GOOD))
        self.m.update("media", {"server": "nas.local", "password": ""})
        creds = open(os.path.join(self.state, "credentials", "media")).read()
        self.assertIn("password=s3cret!", creds)
        self.assertEqual(self.m.get("media")["server"], "nas.local")

    def test_update_username_needs_password(self):
        self.m.add(dict(GOOD))
        with self.assertRaises(server.ApiError):
            self.m.update("media", {"username": "other"})

    def test_delete_removes_everything(self):
        self.m.add(dict(GOOD))
        self.m.delete("media")
        self.assertEqual(self.m.list(), [])
        self.assertFalse(os.path.exists(os.path.join(self.state, "credentials", "media")))

    def test_duplicate_rejected(self):
        self.m.add(dict(GOOD))
        with self.assertRaises(server.ApiError) as e:
            self.m.add(dict(GOOD))
        self.assertEqual(e.exception.status, 409)

    def test_validation(self):
        bad = [
            {"name": "../etc"}, {"name": "a b"},
            {"server": "bad host;rm"}, {"share": "../x"}, {"share": ""},
            {"username": "a,b"}, {"password": "x\ny"}, {"version": "9"},
        ]
        for patch in bad:
            with self.subTest(patch=patch), self.assertRaises(server.ApiError):
                server.validate_share(dict(GOOD, **patch))
        ok = server.validate_share(dict(GOOD, share="\\Media\\", version="3.0"))
        self.assertEqual(ok["share"], "Media")

    def test_test_mount_leaves_nothing_behind(self):
        res = self.m.test({k: v for k, v in GOOD.items() if k != "name"})
        self.assertTrue(res["ok"], res)
        self.assertEqual(self.runner.mounted, set())
        self.assertEqual(sorted(os.listdir(self.state)), ["credentials"])

    def test_test_saved_share_uses_stored_password(self):
        self.m.add(dict(GOOD))
        res = self.m.test({"name": "media"})
        self.assertTrue(res["ok"], res)


class FakeQbt(BaseHTTPRequestHandler):
    bypass = False

    def do_GET(self):
        ok = FakeQbt.bypass or "SID=good" in (self.headers.get("Cookie") or "")
        self.send_response(200 if ok else 403)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *a):
        pass


class ApiTests(unittest.TestCase):
    def setUp(self):
        FakeQbt.bypass = False
        self.qbt = ThreadingHTTPServer(("127.0.0.1", 0), FakeQbt)
        threading.Thread(target=self.qbt.serve_forever, daemon=True).start()
        qport = self.qbt.server_address[1]
        tmp = tempfile.mkdtemp()
        os.makedirs(os.path.join(tmp, "state"))
        cfg = dict(server.DEFAULT_CONFIG, mount_root=os.path.join(tmp, "mnt"),
                   qbt_url="http://127.0.0.1:{}".format(qport))
        self.manager = server.ShareManager(cfg, os.path.join(tmp, "state"), runner=FakeRunner())
        auth = server.QbtAuth(cfg["qbt_url"])
        self.api = ThreadingHTTPServer(("127.0.0.1", 0), server.make_handler(self.manager, auth, cfg))
        threading.Thread(target=self.api.serve_forever, daemon=True).start()
        self.origin = "http://127.0.0.1:{}".format(qport)

    def tearDown(self):
        self.api.shutdown()
        self.qbt.shutdown()

    def req(self, method, path, body=None, cookie="SID=good", origin="default"):
        c = http.client.HTTPConnection("127.0.0.1", self.api.server_address[1])
        h = {}
        if cookie:
            h["Cookie"] = cookie
        if origin:
            h["Origin"] = self.origin if origin == "default" else origin
        data = None
        if body is not None:
            data = json.dumps(body)
            h["Content-Type"] = "application/json"
        c.request(method, path, body=data, headers=h)
        r = c.getresponse()
        out = (r.status, json.loads(r.read() or b"null"), r.getheader("Access-Control-Allow-Origin"))
        c.close()
        return out

    def test_requires_login(self):
        self.assertEqual(self.req("GET", "/api/shares", cookie="SID=bad")[0], 401)
        self.assertEqual(self.req("GET", "/api/shares", cookie=None)[0], 401)

    def test_full_flow(self):
        st, body, acao = self.req("POST", "/api/shares", dict(GOOD))
        self.assertEqual(st, 201, body)
        self.assertEqual(acao, self.origin)
        st, body, _ = self.req("GET", "/api/shares")
        self.assertEqual(body["shares"][0]["name"], "media")
        self.assertEqual(self.req("POST", "/api/shares/media/unmount")[0], 200)
        self.assertEqual(self.req("POST", "/api/shares/media/mount")[0], 200)
        self.assertEqual(self.req("PUT", "/api/shares/media", {"server": "nas"})[0], 200)
        self.assertEqual(self.req("DELETE", "/api/shares/media")[0], 200)
        self.assertEqual(self.req("GET", "/api/shares/media")[0], 404)

    def test_foreign_origin_blocked(self):
        st, _, acao = self.req("POST", "/api/shares", dict(GOOD), origin="http://evil.example")
        self.assertEqual(st, 403)
        self.assertIsNone(acao)

    def test_write_without_origin_blocked(self):
        self.assertEqual(self.req("POST", "/api/shares", dict(GOOD), origin=None)[0], 403)

    def test_auth_bypass_refused(self):
        FakeQbt.bypass = True
        st, body, _ = self.req("GET", "/api/shares", cookie="SID=anything")
        self.assertEqual(st, 503)
        self.assertIn("bypass", body["error"])

    def test_health_is_open(self):
        self.assertEqual(self.req("GET", "/api/health", cookie=None)[0], 200)


if __name__ == "__main__":
    unittest.main()
