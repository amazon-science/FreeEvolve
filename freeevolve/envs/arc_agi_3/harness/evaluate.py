#!/usr/bin/env python3
"""Run an evaluation: some games, some attempts each, and write the aggregate.

    evaluate.py --games-dir <dir> --target <dir> --artifacts <dir> --model <id>
                [--tasks ids|all] [--attempts n] [--concurrency n]
                [--max-actions n] [--attempt-timeout s] [--timeout s]

One attempt is one subprocess (`attempt.py`), which owns its own copy of the game and
serves its own agent. Nothing is shared between attempts, so a game that crashes or an
agent that hangs costs one attempt rather than the evaluation.

The aggregate is written to `<artifacts>/job/result.json`, and every attempt's own
evidence to `<artifacts>/job/<game>__<n>/`.
"""

from __future__ import annotations

import argparse
import json
import statistics
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any

HARNESS_DIR = Path(__file__).resolve().parent
EVAL_NAME = "arc_agi_3"


def discover(games_dir: Path) -> dict[str, Path]:
    """base id -> the directory holding that game, newest version if several."""
    found: dict[str, Path] = {}
    for metadata_file in sorted(games_dir.rglob("metadata.json")):
        try:
            metadata = json.loads(metadata_file.read_text())
        except Exception:  # noqa: BLE001
            print(f"[eval] unreadable metadata: {metadata_file}", file=sys.stderr)
            continue
        base = str(metadata.get("game_id", "")).split("-", 1)[0]
        if base:
            found[base] = metadata_file.parent
    return found


def run_attempt(args: argparse.Namespace, trial_id: str, game_dir: Path,
                timeout: float) -> dict[str, Any]:
    trial_dir = Path(args.artifacts) / "job" / trial_id
    trial_dir.mkdir(parents=True, exist_ok=True)
    command = [
        sys.executable, str(HARNESS_DIR / "attempt.py"),
        "--game-dir", str(game_dir),
        "--artifacts", str(trial_dir),
        "--target", str(args.target),
        "--model", args.model,
        "--max-actions", str(args.max_actions),
        "--timeout", str(timeout),
        "--kill-grace", str(args.kill_grace),
        "--finish-grace", str(args.finish_grace),
        "--seed", str(args.seed),
        "--price-in", str(args.price_in),
        "--price-out", str(args.price_out),
    ]
    log = trial_dir / "attempt.log"
    started = time.time()
    with log.open("w", encoding="utf-8") as handle:
        # The attempt enforces its own deadline; this is the outer bound for the case
        # where the attempt process itself wedges.
        try:
            code = subprocess.call(command, stdout=handle, stderr=subprocess.STDOUT,
                                   timeout=timeout + args.finish_grace + args.kill_grace + 120)
        except subprocess.TimeoutExpired:
            code = -1
            handle.write("\n[eval] the attempt process exceeded its outer bound\n")

    result_file = trial_dir / "result.json"
    if result_file.exists():
        try:
            result = json.loads(result_file.read_text())
            result["trial_id"] = trial_id
            result["attempt_exit_code"] = code
            print(f"[eval] {trial_id}: reward={result['reward']:.4f} "
                  f"levels={result['levels_completed']}/{result['total_levels']} "
                  f"actions={result['actions_used']} {result['closed_reason']} "
                  f"{round(time.time() - started)}s", flush=True)
            return result
        except Exception as exc:  # noqa: BLE001
            failure = f"unreadable result.json: {exc}"
    else:
        failure = f"no result.json (exit {code}); see {log}"
    print(f"[eval] {trial_id}: ERROR {failure}", flush=True)
    return {"trial_id": trial_id, "error": failure, "attempt_exit_code": code}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--games-dir", required=True)
    ap.add_argument("--target", required=True)
    ap.add_argument("--artifacts", required=True)
    ap.add_argument("--model", required=True)
    ap.add_argument("--tasks", default="all")
    ap.add_argument("--exclude", default="")
    ap.add_argument("--attempts", type=int, default=1)
    ap.add_argument("--concurrency", type=int, default=8)
    ap.add_argument("--max-actions", type=int, default=600)
    ap.add_argument("--attempt-timeout", type=float, default=1800)
    ap.add_argument("--timeout", type=float, default=0, help="0 = no bound on the whole evaluation")
    ap.add_argument("--kill-grace", type=float, default=20)
    ap.add_argument("--finish-grace", type=float, default=180)
    # One seed for every attempt: the game is then identical across them and the spread
    # between attempts is the agent's own variance rather than a different game.
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--price-in", type=float, default=3.0)
    ap.add_argument("--price-out", type=float, default=15.0)
    args = ap.parse_args()

    games_dir = Path(args.games_dir).resolve()
    available = discover(games_dir)
    if not available:
        sys.exit(f"[eval] no games under {games_dir}")

    if args.tasks.strip().lower() == "all":
        chosen = sorted(available)
    else:
        chosen = [t.strip() for t in args.tasks.split(",") if t.strip()]
        unknown = [t for t in chosen if t not in available]
        if unknown:
            sys.exit(f"[eval] not installed in this run: {unknown}. "
                     f"Available: {sorted(available)}")
    excluded = {t.strip() for t in args.exclude.split(",") if t.strip()}
    chosen = [t for t in chosen if t not in excluded]
    if not chosen:
        sys.exit("[eval] nothing left to run")

    artifacts = Path(args.artifacts).resolve()
    (artifacts / "job").mkdir(parents=True, exist_ok=True)
    started_at = time.time()
    deadline = started_at + args.timeout if args.timeout else None

    plan = [(f"{base}__{k}", available[base])
            for base in chosen for k in range(args.attempts)]
    print(f"[eval] {len(chosen)} games x {args.attempts} attempts = {len(plan)} "
          f"attempts, concurrency {args.concurrency}", flush=True)
    print(f"[eval] {args.max_actions} actions and {args.attempt_timeout}s per attempt", flush=True)

    results: list[dict[str, Any]] = []
    not_run: list[str] = []

    def launch(item: tuple[str, Path]) -> dict[str, Any] | None:
        trial_id, game_dir = item
        timeout = args.attempt_timeout
        if deadline is not None:
            left = deadline - time.time()
            if left <= 60:
                not_run.append(trial_id)
                return None
            timeout = min(timeout, left)
        return run_attempt(args, trial_id, game_dir, timeout)

    with ThreadPoolExecutor(max_workers=max(1, args.concurrency)) as pool:
        for outcome in pool.map(launch, plan):
            if outcome is not None:
                results.append(outcome)

    scored = [r for r in results if "error" not in r]
    errored = [r for r in results if "error" in r]
    rewards = [r["reward"] for r in scored]

    per_game: dict[str, Any] = {}
    for base in chosen:
        mine = [r for r in scored if r["base_id"] == base]
        if not mine:
            continue
        per_game[base] = {
            # The published metric takes the best play of a game, so with several
            # attempts the game's own score is the best of them.
            "best": max(r["reward"] for r in mine),
            "mean": statistics.fmean(r["reward"] for r in mine),
            "rewards": [r["reward"] for r in mine],
            "levels_completed": [r["levels_completed"] for r in mine],
            "total_levels": mine[0]["total_levels"],
            "actions": [r["actions_used"] for r in mine],
            "closed_reasons": [r["closed_reason"] for r in mine],
        }

    def mean(values: list[float]) -> float | None:
        return statistics.fmean(values) if values else None

    stderr = (statistics.stdev(rewards) / len(rewards) ** 0.5
              if len(rewards) > 1 else None)
    exception_stats: dict[str, list[str]] = {}
    for r in errored:
        exception_stats.setdefault(str(r["error"]).split(";")[0], []).append(r["trial_id"])
    disagreed = [r["trial_id"] for r in scored if not r.get("scores_agree", True)]

    result = {
        "job_name": artifacts.name,
        "config": {
            "games": chosen, "attempts": args.attempts, "model": args.model,
            "max_actions": args.max_actions, "attempt_timeout_sec": args.attempt_timeout,
            "concurrency": args.concurrency, "target": str(Path(args.target).resolve()),
            "games_dir": str(games_dir),
        },
        "started_at": started_at,
        "finished_at": time.time(),
        "duration_sec": round(time.time() - started_at, 1),
        "stats": {
            "cost_usd": sum(r.get("cost_usd") or 0.0 for r in scored),
            # Attempts whose agent never reported what it spent, so the total above is a
            # lower bound by however much they cost.
            "cost_incomplete_trials": [r["trial_id"] for r in scored
                                       if not r.get("cost_complete", True)],
            "evals": {
                EVAL_NAME: {
                    "metrics": [
                        {"name": "rhae", "mean": mean(rewards), "stderr": stderr},
                        {"name": "levels_fraction",
                         "mean": mean([r["levels_completed"] / r["total_levels"] for r in scored])},
                        {"name": "levels_completed",
                         "mean": mean([float(r["levels_completed"]) for r in scored])},
                        {"name": "actions",
                         "mean": mean([float(r["actions_used"]) for r in scored])},
                    ],
                    # The benchmark's own number: best play per game, averaged over games.
                    "official_score": mean([g["best"] for g in per_game.values()]),
                    "reward_stats": {r["trial_id"]: r["reward"] for r in scored},
                    "per_game": per_game,
                    "n_trials": len(scored),
                    "n_errors": len(errored),
                    "n_not_run": len(not_run),
                    "not_run": not_run,
                    "exception_stats": exception_stats,
                    "scores_disagreed": disagreed,
                }
            },
        },
    }
    (artifacts / "job" / "result.json").write_text(json.dumps(result, indent=2), encoding="utf-8")

    stats = result["stats"]["evals"][EVAL_NAME]
    print(f"[eval] rhae={stats['metrics'][0]['mean']} "
          f"official={stats['official_score']} "
          f"levels={stats['metrics'][2]['mean']} "
          f"trials={stats['n_trials']} errors={stats['n_errors']} "
          f"not_run={stats['n_not_run']}", flush=True)
    print(f"[eval] cost=${result['stats']['cost_usd']:.2f} "
          f"in {result['duration_sec']}s", flush=True)
    if disagreed:
        print(f"[eval] SCORES DISAGREED on {len(disagreed)} attempts: {disagreed[:5]}",
              file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
