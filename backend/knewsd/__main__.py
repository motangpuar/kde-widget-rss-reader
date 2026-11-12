"""Entry point: python3 -m knewsd [--port 8770] [--socket PATH] [--db PATH]

Also carries the small client modes the widget's bootstrap needs, so the shell script never
has to speak HTTP itself:

    python3 knewsd.pyz --probe [--port N | --socket PATH]   -> health JSON, exit 0/1
    python3 knewsd.pyz --shutdown [--port N | --socket PATH] -> clean stop, exit 0/1
"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import sys
import time

from . import config
from .api import Client, read_endpoint, serve
from .config import DEFAULT_IDLE_EXIT, DEFAULT_PORT, VERSION, db_path
from .db import Store

def _lock() -> object:
    """Take the per-session daemon lock; returns None when another instance owns it.

    Without XDG_RUNTIME_DIR (or a writable one) locking is skipped and the port bind decides
    who wins — the lock is a convenience, not the security boundary.
    """
    try:
        handle = open(config.lock_path(), "a+", encoding="utf-8")
    except OSError:
        return _NoLock
    # A sibling that was just asked to stop can hold the lock for a few hundred milliseconds;
    # waiting briefly turns that race into a clean restart instead of a refused start.
    deadline = time.time() + 5.0
    while True:
        try:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except OSError:
            if time.time() >= deadline:
                handle.close()
                return None
            time.sleep(0.2)
    handle.seek(0)
    handle.truncate()
    handle.write(str(os.getpid()))
    handle.flush()
    return handle

class _NoLock:
    """Placeholder held instead of a lock file handle."""

def _client(args: argparse.Namespace) -> Client:
    if args.socket:
        return Client(socket_path=args.socket)
    if args.port is not None:
        return Client(port=args.port)
    endpoint = read_endpoint()
    if endpoint.get("socket"):
        return Client(socket_path=str(endpoint["socket"]))
    return Client(port=int(endpoint.get("port") or DEFAULT_PORT))

def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="knewsd", description="News Curator backend")
    parser.add_argument("--port", type=int, default=None,
                        help="loopback port (socket mode defaults to an ephemeral one)")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--socket", default=os.environ.get("KNEWS_SOCKET", ""),
                        help="also serve the API on this unix socket")
    parser.add_argument("--db", default=str(db_path()))
    parser.add_argument("--idle-exit", type=int, default=None,
                        help="exit after N seconds without a request (0 disables)")
    parser.add_argument("--probe", action="store_true", help="print health JSON and exit")
    parser.add_argument("--shutdown", action="store_true", help="ask a running daemon to stop")
    parser.add_argument("--version", action="version", version=f"knewsd {VERSION}")
    args = parser.parse_args(argv)

    if args.probe or args.shutdown:
        client = _client(args)
        if args.probe:
            health = client.health()
            if not health:
                print("knewsd: not reachable", file=sys.stderr)
                return 1
            print(json.dumps(health, ensure_ascii=False))
            return 0
        if not client.shutdown():
            print("knewsd: shutdown refused", file=sys.stderr)
            return 1
        print("knewsd: shutdown requested")
        return 0

    socket_path = str(args.socket or "")
    port = args.port if args.port is not None else (0 if socket_path else DEFAULT_PORT)
    if args.idle_exit is not None:
        idle_exit = args.idle_exit
    elif "KNEWS_IDLE_EXIT" in os.environ:
        try:
            idle_exit = int(os.environ["KNEWS_IDLE_EXIT"])
        except ValueError:
            idle_exit = DEFAULT_IDLE_EXIT
    else:
        idle_exit = DEFAULT_IDLE_EXIT

    lock = _lock()
    if lock is None:
        # Another daemon already owns this session; not an error for a supervisor.
        print("knewsd: already running for this session", flush=True)
        return 0

    store = Store(args.db)
    where = f"unix:{socket_path}" if socket_path else f"http://{args.host}:{port}"
    print(f"knewsd {VERSION} starting on {where} (loopback port {port or 'auto'}) "
          f"idle_exit={idle_exit}s db={args.db}", flush=True)
    try:
        serve(store, args.host, port, socket_path or None, idle_exit)
    except KeyboardInterrupt:
        return 0
    except OSError as exc:
        print(f"knewsd: cannot bind {where}: {exc}", file=sys.stderr)
        return 1
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
