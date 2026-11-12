#!/usr/bin/env python3
"""Validate the plasmoid package metadata.

Used by CI, by scripts/ci-local.sh and by the release workflow, so a packaging mistake fails
locally instead of on a GitHub runner. Stdlib only.

    python3 scripts/check-metadata.py [--expect-tag v1.9.0] [--require-backend]

knewsd.pyz is a build product (gitignored), so it only exists after ./build.sh: it is checked
when present, and required only with --require-backend (post-build callers).
"""

import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
PKG = ROOT / "plasmoid" / "io.github.infidel.newscurator"
PLASMOID_ID = PKG.name
REQUIRED_KEYS = ["Id", "Name", "Version", "License", "Icon", "Category", "Description"]

errors = []


def fail(message):
    errors.append(message)


def main():
    expect_tag = None
    print_version = False
    require_backend = False
    args = sys.argv[1:]
    while args:
        if args[0] == "--print-version":
            print_version = True
            args = args[1:]
        elif args[0] == "--expect-tag" and len(args) >= 2:
            expect_tag = args[1]
            args = args[2:]
        elif args[0] == "--require-backend":
            require_backend = True
            args = args[1:]
        else:
            print("usage: check-metadata.py [--expect-tag vX.Y.Z] [--require-backend] "
                  "[--print-version]",
                  file=sys.stderr)
            return 2

    meta_path = PKG / "metadata.json"
    if not meta_path.is_file():
        print(f"error: {meta_path} not found", file=sys.stderr)
        return 1

    try:
        meta = json.loads(meta_path.read_text())
    except json.JSONDecodeError as exc:
        print(f"error: metadata.json is not valid JSON: {exc}", file=sys.stderr)
        return 1

    if meta.get("KPackageStructure") != "Plasma/Applet":
        fail("KPackageStructure must be 'Plasma/Applet'")

    plugin = meta.get("KPlugin")
    if not isinstance(plugin, dict):
        fail("KPlugin object is missing")
        plugin = {}

    for key in REQUIRED_KEYS:
        if not plugin.get(key):
            fail(f"KPlugin.{key} is empty or missing")

    if plugin.get("Id") and plugin["Id"] != PLASMOID_ID:
        fail(f"KPlugin.Id '{plugin['Id']}' does not match the package directory '{PLASMOID_ID}'")

    version = plugin.get("Version", "")
    if not re.fullmatch(r"\d+\.\d+\.\d+", version or ""):
        fail(f"KPlugin.Version '{version}' is not X.Y.Z")

    config = ROOT / "backend" / "knewsd" / "config.py"
    if config.is_file():
        match = re.search(r'^VERSION = "([^"]+)"', config.read_text(), re.M)
        backend_version = match.group(1) if match else None
        if backend_version != version:
            fail(f"backend VERSION {backend_version} does not match metadata {version}")
    else:
        fail("backend/knewsd/config.py is missing")

    # X-Plasma-MainScript is relative to contents/, not to the package root.
    main_script = meta.get("X-Plasma-MainScript", "")
    if not main_script:
        fail("X-Plasma-MainScript is missing")
    else:
        target = PKG / "contents" / main_script
        if not target.is_file():
            fail(f"X-Plasma-MainScript points at a missing file: contents/{main_script}")

    if not (PKG / "contents" / "config" / "main.xml").is_file():
        fail("contents/config/main.xml is missing")

    # A store install has no installer script, so the daemon has to travel inside the package.
    if not (PKG / "contents" / "backend" / "bootstrap.sh").is_file():
        fail("missing contents/backend/bootstrap.sh")
    zipapp = PKG / "contents" / "backend" / "knewsd.pyz"
    if not zipapp.is_file():
        if require_backend:
            fail("missing bundled backend contents/backend/knewsd.pyz (run ./build.sh)")
    elif zipapp.stat().st_size < 10000:
        fail(f"contents/backend/knewsd.pyz looks truncated ({zipapp.stat().st_size} bytes)")

    ui_files = sorted((PKG / "contents" / "ui").glob("*"))
    if not ui_files:
        fail("contents/ui is empty")
    for path in ui_files:
        if path.suffix in (".qml", ".js") and path.stat().st_size == 0:
            fail(f"{path.relative_to(ROOT)} is empty")

    icon = plugin.get("Icon")
    if icon and not (ROOT / "icons" / f"{icon}.svg").is_file():
        fail(f"icons/{icon}.svg is missing (KPlugin.Icon is installed as a theme icon)")

    if not (ROOT / "LICENSE").is_file():
        fail("LICENSE is missing")

    for path in PKG.rglob("*"):
        if path.is_file() and "PLACEHOLDER" in path.read_text(errors="ignore"):
            fail(f"{path.relative_to(ROOT)} still contains a PLACEHOLDER marker")

    if expect_tag and expect_tag != f"v{version}":
        fail(f"tag {expect_tag} does not match metadata version v{version}")

    if print_version and not errors:
        print(plugin.get("Version", ""))
        return 0

    if errors:
        for message in errors:
            print(f"error: {message}", file=sys.stderr)
        return 1

    print(f"metadata ok: {plugin['Id']} {version} "
          f"main=contents/{main_script} ui={len(ui_files)} files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
