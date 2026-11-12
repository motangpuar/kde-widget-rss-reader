"""Tests for the daemon's lifetime and transport layer: unix socket, endpoint file,
clean shutdown, idle reaper and the single-instance lock."""

import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path
from unittest import mock

from knewsd import api as api_mod
from knewsd import config
from knewsd.db import Store

BACKEND = Path(__file__).resolve().parents[1]

class UnixTransportTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.env = mock.patch.dict(os.environ, {
            "XDG_RUNTIME_DIR": str(self.root / "run"),
            "XDG_DATA_HOME": str(self.root / "data"),
            "XDG_CACHE_HOME": str(self.root / "cache"),
        })
        self.env.start()
        self.sock = str(self.root / "run" / "knews-curator" / "knewsd.sock")
        self.store = Store(self.root / "test.db")
        self.runtime = api_mod.Runtime(idle_exit=0)
        self.runtime.transport = "socket"
        self.tcp = api_mod.build_server(self.store, "127.0.0.1", 0, self.runtime)
        self.unix = api_mod.build_unix_server(self.store, self.sock, self.runtime)
        self.runtime.publish()
        self.threads = [
            threading.Thread(target=self.tcp.serve_forever, kwargs={"poll_interval": 0.2}, daemon=True),
            threading.Thread(target=self.unix.serve_forever, kwargs={"poll_interval": 0.2}, daemon=True),
        ]
        for thread in self.threads:
            thread.start()

    def tearDown(self):
        for server in (self.tcp, self.unix):
            server.shutdown()
            server.server_close()
        self.store.db.close()
        self.env.stop()
        self.tmp.cleanup()

    def test_socket_serves_the_same_api(self):
        client = api_mod.Client(socket_path=self.sock)
        health = client.health()
        self.assertIsNotNone(health)
        self.assertTrue(health["ok"])
        self.assertEqual(health["transport"], "socket")
        self.assertEqual(health["socket"], self.sock)
        self.assertEqual(health["pid"], os.getpid())
        self.assertGreater(health["port"], 0)

        reply = client.request("GET", "/api/state")
        self.assertEqual(reply["status"], 200)
        self.assertIn("prefs", reply)

    def test_endpoint_file_describes_both_channels(self):
        data = json.loads(config.endpoint_path().read_text())
        self.assertEqual(data["pid"], os.getpid())
        self.assertEqual(data["socket"], self.sock)
        self.assertEqual(data["port"], self.tcp.server_address[1])
        self.assertEqual(data["version"], config.VERSION)
        # The published loopback port must actually serve the widget's transport.
        with urllib.request.urlopen(f"http://127.0.0.1:{data['port']}/api/health", timeout=5) as r:
            self.assertTrue(json.loads(r.read())["ok"])

    def test_unix_peer_without_host_header_is_allowed(self):
        client = api_mod.Client(socket_path=self.sock)
        self.assertIsNotNone(client.health())

    def test_shutdown_needs_the_client_header(self):
        # No CSRF header -> refused, daemon keeps running.
        bare = api_mod.Client(socket_path=self.sock).request("POST", "/api/shutdown", {})
        self.assertEqual(bare["status"], 403)
        self.assertIsNotNone(api_mod.Client(socket_path=self.sock).health())

        reply = api_mod.Client(socket_path=self.sock).shutdown()
        self.assertTrue(reply)
        for thread in self.threads:
            thread.join(timeout=5)
            self.assertFalse(thread.is_alive())

class IdleReaperTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.env = mock.patch.dict(os.environ, {
            "XDG_RUNTIME_DIR": str(self.root / "run"),
            "XDG_DATA_HOME": str(self.root / "data"),
            "XDG_CACHE_HOME": str(self.root / "cache"),
        })
        self.env.start()
        self.store = Store(self.root / "test.db")

    def tearDown(self):
        self.store.db.close()
        self.env.stop()
        self.tmp.cleanup()

    def test_idle_daemon_exits_and_cleans_up(self):
        sock = str(self.root / "run" / "knews-curator" / "knewsd.sock")
        thread = threading.Thread(
            target=api_mod.serve,
            args=(self.store, "127.0.0.1", 0, sock, 2),
            daemon=True,
        )
        thread.start()

        deadline = time.time() + 8
        while time.time() < deadline and not api_mod.Client(socket_path=sock).health():
            time.sleep(0.2)
        self.assertTrue(api_mod.Client(socket_path=sock).health(), "daemon never became ready")

        thread.join(timeout=12)
        self.assertFalse(thread.is_alive(), "idle reaper did not stop the daemon")
        self.assertFalse(Path(sock).exists(), "socket file survived the exit")
        self.assertFalse(config.endpoint_path().exists(), "endpoint file survived the exit")

    def test_client_reports_unreachable(self):
        self.assertIsNone(api_mod.Client(port=9).health())

class RuntimeDirFallbackTests(unittest.TestCase):
    def test_read_only_runtime_dir_falls_back_to_cache(self):
        # Hardened units run with ProtectSystem=strict, which can make $XDG_RUNTIME_DIR
        # read-only; the daemon must degrade, not fail to start.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            blocked = root / "run"
            blocked.mkdir()
            blocked.chmod(0o500)
            env = mock.patch.dict(os.environ, {
                "XDG_RUNTIME_DIR": str(blocked),
                "XDG_CACHE_HOME": str(root / "cache"),
            })
            env.start()
            try:
                if os.access(blocked, os.W_OK):
                    self.skipTest("running as root: directory stays writable")
                runtime = config.runtime_dir()
                self.assertTrue(str(runtime).startswith(str(root / "cache")))
                self.assertTrue(runtime.is_dir())
            finally:
                env.stop()
                blocked.chmod(0o700)

class SingleInstanceTests(unittest.TestCase):
    def test_second_daemon_refuses_the_lock(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            env = {
                **os.environ,
                "PYTHONPATH": str(BACKEND),
                "XDG_RUNTIME_DIR": str(root / "run"),
                "XDG_DATA_HOME": str(root / "data"),
                "XDG_CACHE_HOME": str(root / "cache"),
            }
            first = subprocess.Popen(
                [sys.executable, "-m", "knewsd", "--socket", str(root / "a.sock"),
                 "--port", "0", "--idle-exit", "0", "--db", str(root / "db")],
                env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
            )
            try:
                deadline = time.time() + 10
                while time.time() < deadline:
                    if api_mod.Client(socket_path=str(root / "a.sock")).health():
                        break
                    time.sleep(0.2)
                second = subprocess.run(
                    [sys.executable, "-m", "knewsd", "--socket", str(root / "a.sock"),
                     "--port", "0", "--idle-exit", "0", "--db", str(root / "db")],
                    env=env, capture_output=True, text=True, timeout=20,
                )
                self.assertEqual(second.returncode, 0)
                self.assertIn("already running", second.stdout + second.stderr)
            finally:
                api_mod.Client(socket_path=str(root / "a.sock")).shutdown()
                first.wait(timeout=10)

if __name__ == "__main__":
    unittest.main()
