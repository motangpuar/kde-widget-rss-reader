"""Tests for the daemon's lifetime and transport layer: unix socket, endpoint file,
clean shutdown, idle reaper and the single-instance lock."""

import io
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


class ClockTests(unittest.TestCase):
    """The lifetime layer must measure *running* time, not wall-clock time.

    A laptop that sleeps for three hours must not look idle for three hours: CLOCK_REALTIME
    advances during suspend and jumps on NTP steps, and the reaper used to kill a daemon whose
    client was on screen (issue #2, mechanism A).
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.env = mock.patch.dict(os.environ, {
            "XDG_RUNTIME_DIR": str(self.root / "run"),
            "XDG_DATA_HOME": str(self.root / "data"),
            "XDG_CACHE_HOME": str(self.root / "cache"),
        })
        self.env.start()
        self.store = Store(self.root / "clock.db")

    def tearDown(self):
        self.store.db.close()
        self.env.stop()
        self.tmp.cleanup()

    def test_lock_lives_in_the_data_dir_not_the_session_runtime_dir(self):
        # A wipe of $XDG_RUNTIME_DIR must not hand a second daemon a fresh lock inode.
        self.assertTrue(str(config.lock_path()).startswith(str(config.data_dir())))
        self.assertFalse(str(config.lock_path()).startswith(str(config.runtime_dir())))

    def test_idle_for_ignores_a_wall_clock_jump(self):
        runtime = api_mod.Runtime(idle_exit=900, clock=lambda: 100.0)
        runtime.touch()
        with mock.patch.object(api_mod.time, "time", lambda: 100.0 + 10800):
            # Three hours of suspend show up on the wall clock and must not count.
            self.assertEqual(runtime.idle_for(), 0.0)

    def test_idle_for_counts_running_time(self):
        now = [100.0]
        runtime = api_mod.Runtime(idle_exit=900, clock=lambda: now[0])
        runtime.touch()
        now[0] += 42.0
        self.assertAlmostEqual(runtime.idle_for(), 42.0)

    def test_watchdog_does_not_exit_on_a_wall_clock_jump(self):
        runtime = api_mod.Runtime(idle_exit=1, clock=lambda: 100.0)
        runtime.publish()
        runtime.touch()
        watchdog = api_mod.IdleWatchdog(runtime)
        with mock.patch.object(api_mod.time, "time", lambda: 100.0 + 10800):
            watchdog.start()
            time.sleep(2.6)
            self.assertFalse(runtime.stopped.is_set(),
                             "wall-clock jump must not count as idleness")
        runtime.stop()

    def test_watchdog_exits_when_the_published_endpoint_disappears(self):
        runtime = api_mod.Runtime(idle_exit=600, clock=lambda: 100.0)
        runtime.publish()
        runtime.touch()
        self.assertTrue(runtime.published_identity())
        watchdog = api_mod.IdleWatchdog(runtime)
        watchdog.start()
        config.endpoint_path().unlink()
        deadline = time.time() + 8
        while time.time() < deadline and not runtime.stopped.is_set():
            time.sleep(0.2)
        self.assertTrue(runtime.stopped.is_set(),
                        "a daemon whose endpoint file vanished must reap itself")
        self.assertFalse(runtime.published_identity())

    def test_auto_refresher_skips_the_suspend_storm(self):
        class Manager:
            def __init__(self):
                self.state = {"running": False}
                self.started = []

            def start(self, feeds=None):
                self.started.append(feeds)

        now = {"mono": 0.0, "wall": 1_000_000.0}
        self.store.add_feed("http://example.invalid/feed.xml", "t", "http://example.invalid")
        # Pretend the feed was fetched a moment ago; add_feed leaves last_fetch at 0 (due at once).
        self.store.db.execute("update feeds set last_fetch = ?", (1_000_000.0,))
        self.store.db.commit()
        manager = Manager()
        refresher = api_mod.AutoRefresher(self.store, manager,
                                          clock=lambda: now["mono"],
                                          wall=lambda: now["wall"])
        refresher.poll()
        self.assertEqual(manager.started, [], "a fresh feed is not due")

        now["wall"] += 10800          # three hours of suspend
        now["mono"] += 1.0
        refresher.poll()
        self.assertEqual(manager.started, [], "suspend must not look like three hours of age")

        now["wall"] += 1800           # half an hour of running time
        now["mono"] += 1800
        refresher.poll()
        self.assertEqual(len(manager.started), 1, "elapsed running time still refreshes")


class AccessLogTests(unittest.TestCase):
    """The access log is the end-to-end oracle for the widget: it must never break a request.

    ``BaseHTTPRequestHandler.address_string`` reads ``client_address[0]``, which is empty for an
    AF_UNIX peer, so logging used to raise IndexError and the request never got a response - a
    live daemon that looked dead from the widget's side.
    """

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
        self.store = Store(self.root / "log.db")
        self.runtime = api_mod.Runtime(idle_exit=0)
        self.unix = api_mod.build_unix_server(self.store, self.sock, self.runtime)
        self.thread = threading.Thread(
            target=self.unix.serve_forever, kwargs={"poll_interval": 0.2}, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.unix.shutdown()
        self.unix.server_close()
        self.store.db.close()
        self.env.stop()
        self.tmp.cleanup()

    def test_access_log_does_not_break_unix_requests(self):
        with mock.patch.object(api_mod, "ACCESS_LOG", True), \
                mock.patch.object(api_mod.sys, "stderr", new=io.StringIO()) as captured:
            health = api_mod.Client(socket_path=self.sock).health()
            self.assertIsNotNone(health, "a logged request must still answer")
            self.assertIn("request unix - ", captured.getvalue())
