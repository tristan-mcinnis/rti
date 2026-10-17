#!/usr/bin/env python3
"""Record the pinned house packages (version and revision) in a built app's Info.plist.

The pins come from the committed Package.resolved, so an installed build names
the exact tags of house-chat-core and design-system it shipped with.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import plistlib
import sys

KEYS = {
    "house-chat-core": "HouseChatCore",
    "design-system": "HouseDesign",
}


def read_pins(resolved: pathlib.Path) -> dict:
    data = json.loads(resolved.read_text())
    pins = data.get("pins") or data.get("object", {}).get("pins", [])
    found = {}
    for pin in pins:
        identity = pin.get("identity") or pin.get("package", "").lower()
        if identity in KEYS:
            state = pin["state"]
            found[identity] = {"version": state.get("version"), "revision": state["revision"]}
    missing = sorted(set(KEYS) - set(found))
    if missing:
        raise ValueError(f"{resolved} has no pin for: {', '.join(missing)}")
    return found


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--resolved", type=pathlib.Path, required=True, help="Committed Package.resolved")
    parser.add_argument("--plist", type=pathlib.Path, required=True, help="Built app Info.plist to stamp before signing")
    args = parser.parse_args()
    try:
        pins = read_pins(args.resolved)
        info = plistlib.loads(args.plist.read_bytes())
        for identity, prefix in KEYS.items():
            info[f"{prefix}Version"] = pins[identity]["version"] or "unversioned"
            info[f"{prefix}Revision"] = pins[identity]["revision"]
        args.plist.write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_XML))
    except (OSError, ValueError, KeyError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
