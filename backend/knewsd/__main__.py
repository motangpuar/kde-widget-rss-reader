"""Entry point: python3 -m knewsd [--port 8770] [--db PATH]"""

from __future__ import annotations

import argparse
import os
import sys

from .api import serve
from .config import DEFAULT_PORT, VERSION, db_path
from .db import Store


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="knewsd", description="News Curator backend")
    parser.add_argument("--port", type=int, default=int(os.environ.get("KNEWS_PORT", DEFAULT_PORT)))
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--db", default=str(db_path()))
    parser.add_argument("--version", action="version", version=f"knewsd {VERSION}")
    args = parser.parse_args(argv)

    store = Store(args.db)
    print(f"knewsd {VERSION} listening on http://{args.host}:{args.port} db={args.db}", flush=True)
    try:
        serve(store, args.host, args.port)
    except KeyboardInterrupt:
        return 0
    except OSError as exc:
        print(f"knewsd: cannot bind {args.host}:{args.port}: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
