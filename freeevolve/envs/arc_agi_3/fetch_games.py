#!/usr/bin/env python3
"""Download the public ARC-AGI-3 games into a directory the engine can play offline.

    fetch_games.py --output-dir <dir> [--games ls20,ft09,...] [--limit n]

The ARC-AGI toolkit plays a game from a local directory holding two files:

    <dir>/<game>/<version>/metadata.json     what the game is, and the human baseline
    <dir>/<game>/<version>/<class>.py        the game itself, an ARCBaseGame subclass

`Arcade(operation_mode=OFFLINE, environments_dir=<dir>)` scans for metadata.json and
plays whatever it finds, with no API key and no network. This script is what puts them
there: it is the ONE step that talks to arcprize.org, and it is run once, ahead of any
evaluation, so that every run afterwards is offline and reproducible.

An anonymous key is enough for the public set and is fetched automatically; ARC_API_KEY
is used instead when it is set. The game sources are MIT licensed (the header is in
each file).

metadata.json is written with two fields the API does not return:

  class_name  the engine derives this from the game id when absent, but it derives it
              by capitalising the first of four characters — so it must be recorded
              rather than guessed, and a game whose class is named otherwise would
              silently fail to load.
  local_dir   the directory itself. The engine overwrites this at scan time; it is
              written anyway so the file says where it came from when read by hand.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.request
from pathlib import Path

BASE_URL = "https://three.arcprize.org"


def get(url: str, api_key: str | None = None, timeout: int = 60) -> bytes:
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    if api_key:
        req.add_header("X-Api-Key", api_key)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read()


def anonymous_key() -> str:
    data = json.loads(get(f"{BASE_URL}/api/games/anonkey"))
    return str(data["api_key"])


def class_name_in(source: str, game_base: str) -> str:
    """The ARCBaseGame subclass the engine must instantiate.

    Read out of the source rather than derived from the game id: the engine's fallback
    ("ls20" -> "Ls20") happens to be right today, and a game that ever breaks it would
    fail to load with an error about a missing class rather than about a wrong guess.
    """
    classes = re.findall(r"^class\s+(\w+)\s*\(\s*ARCBaseGame\s*\)", source, re.MULTILINE)
    if len(classes) == 1:
        return classes[0]
    if not classes:
        raise SystemExit(f"{game_base}: no ARCBaseGame subclass found in the source")
    # More than one: prefer the one whose name matches the id, else refuse to guess.
    want = game_base[0].upper() + game_base[1:]
    if want in classes:
        return want
    raise SystemExit(f"{game_base}: several ARCBaseGame subclasses {classes}, cannot choose")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--output-dir", type=Path, required=True)
    ap.add_argument("--games", default="", help="comma-separated base ids, e.g. ls20,ft09. Default: all public games.")
    ap.add_argument("--limit", type=int, default=0, help="stop after this many games (0 = no limit)")
    ap.add_argument("--api-key", default="", help="ARC_API_KEY. Default: fetch an anonymous key.")
    args = ap.parse_args()

    api_key = args.api_key or anonymous_key()
    catalogue = json.loads(get(f"{BASE_URL}/api/games", api_key))
    wanted = {g.strip().lower() for g in args.games.split(",") if g.strip()}

    entries = []
    for entry in catalogue:
        full_id = entry.get("game_id", "")
        if "-" not in full_id:
            print(f"[fetch] skipping unversioned game id {full_id!r}", file=sys.stderr)
            continue
        base, version = full_id.split("-", 1)
        if wanted and base.lower() not in wanted:
            continue
        entries.append((base, version, full_id))
    entries.sort()
    if wanted:
        missing = wanted - {b.lower() for b, _, _ in entries}
        if missing:
            raise SystemExit(f"[fetch] not in the catalogue: {sorted(missing)}")
    if args.limit:
        entries = entries[: args.limit]

    args.output_dir.mkdir(parents=True, exist_ok=True)
    for base, version, full_id in entries:
        game_dir = args.output_dir / base / version
        game_dir.mkdir(parents=True, exist_ok=True)

        metadata = json.loads(get(f"{BASE_URL}/api/games/{full_id}", api_key))
        source = get(f"{BASE_URL}/api/games/{full_id}/source", api_key).decode("utf-8")
        cls = class_name_in(source, base)

        metadata["class_name"] = cls
        metadata["local_dir"] = str(game_dir)
        baselines = metadata.get("baseline_actions") or []
        if not baselines:
            raise SystemExit(
                f"[fetch] {full_id} has no baseline_actions. The human baseline is the "
                f"denominator of the score; a game without one cannot be scored."
            )

        (game_dir / f"{cls.lower()}.py").write_text(source, encoding="utf-8")
        (game_dir / "metadata.json").write_text(json.dumps(metadata, indent=2), encoding="utf-8")
        print(f"[fetch] {full_id:>16}  class={cls:<6} levels={len(baselines):<3} "
              f"baseline_actions={sum(baselines):<5} {len(source):>7} bytes")

    print(f"[fetch] {len(entries)} games in {args.output_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
