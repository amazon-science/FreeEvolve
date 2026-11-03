#!/usr/bin/env python3
"""Does the harness work? Load every installed game, take a few actions, score it.

    selfcheck.py --games-dir <dir> [--actions n]

No model is called and no agent is involved: this exercises the engine, the step
recording and the scoring, which are the parts that would otherwise fail an hour into
an evaluation.

It also proves the harness and the toolkit agree about the play that just happened — on
the ACTION COUNT as well as the score. The count is the sharper of the two: while no
level has been finished both scores are zero and agree for no reason at all, so a
disagreement about what counts as an action hides there until the day an agent finishes
a level. That is not hypothetical — it is how the empty-frame response was found.

Exit status is 0 when every game loaded, stepped and scored, and non-zero otherwise.
"""

from __future__ import annotations

import argparse
import json
import random
import sys
import time
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

from scoring import score_steps  # noqa: E402


def check(game_dir: Path, actions: int) -> tuple[bool, str]:
    from arc_agi import Arcade, OperationMode
    from arcengine import GameAction

    metadata = json.loads((game_dir / "metadata.json").read_text())
    full_id = metadata["game_id"]
    base = full_id.split("-", 1)[0]
    baselines = metadata["baseline_actions"]

    arc = Arcade(operation_mode=OperationMode.OFFLINE, environments_dir=str(game_dir),
                 recordings_dir=str(game_dir / ".selfcheck-recordings"))
    card = arc.open_scorecard(tags=["selfcheck"])
    env = arc.make(base, seed=0, scorecard_id=card, save_recording=False,
                   include_frame_data=False)
    if env is None:
        return False, "the engine would not make it"
    obs = env.observation_space
    if obs is None or obs.is_empty():
        return False, "no first frame"
    if len(obs.frame[0]) != 64 or len(obs.frame[0][0]) != 64:
        return False, f"first frame is {len(obs.frame[0])}x{len(obs.frame[0][0])}, not 64x64"

    def note(action: str, frame_data: Any) -> dict[str, Any]:
        step = {"i": len(steps), "action": action, "state": frame_data.state.value,
                "levels_completed": frame_data.levels_completed,
                "full_reset": bool(getattr(frame_data, "full_reset", False))}
        if not frame_data.frame:
            step["no_frame"] = True
        return step

    steps: list[dict[str, Any]] = []
    steps.append(note("RESET", obs))
    if not steps[0]["full_reset"]:
        return False, "the first RESET did not start a play, so nothing can be scored"

    rng = random.Random(0)
    used = 0
    empty = 0
    started = time.time()
    for _ in range(actions):
        available = [a for a in (obs.available_actions or []) if a != 0] or [1]
        action = GameAction.from_id(rng.choice(available))
        data = {"x": rng.randrange(64), "y": rng.randrange(64)} if action.is_complex() else {}
        obs = env.step(action, data)
        if obs is None:
            return False, "the engine rejected an action it said was available"
        used += 1
        steps.append(note(action.name, obs))
        if not obs.frame:
            empty += 1
        if obs.state.value == "GAME_OVER":
            # One more action before resetting, deliberately. The game ignores an action
            # taken from GAME_OVER and returns no screen, which is the one case where the
            # harness must not count an action — so this is where the count comparison
            # below earns its keep. Without it a random walk never reaches the case on
            # most games, and the disagreement stays invisible.
            ignored = env.step(action, data)
            if ignored is not None:
                steps.append(note(action.name, ignored))
                if not ignored.frame:
                    empty += 1
            obs = env.reset()
            used += 1
            steps.append(note("RESET", obs))
    rate = used / max(time.time() - started, 1e-6)

    recomputed = score_steps(steps, baselines)
    scorecard = arc.close_scorecard(card)
    toolkit_score = toolkit_actions = None
    for environment in json.loads(scorecard.model_dump_json()).get("environments", []):
        if environment.get("id", "").startswith(base):
            toolkit_score = environment.get("score")
            toolkit_actions = environment.get("actions")
    if toolkit_score is None:
        return False, "the toolkit produced no score for this game"
    if toolkit_actions != recomputed["actions"]:
        return False, (f"the two counts of actions disagree: toolkit={toolkit_actions} "
                       f"harness={recomputed['actions']} "
                       f"({used} sent, {empty} with no screen back)")
    if abs(toolkit_score / 100.0 - recomputed["score"]) > 1e-6:
        return False, (f"the two scorers disagree: toolkit={toolkit_score / 100.0} "
                       f"recomputed={recomputed['score']}")
    return True, (f"{len(baselines)} levels, {used} random actions at {rate:.0f}/s "
                  f"({empty} returned no screen), {recomputed['actions']} counted, "
                  f"score {recomputed['score']:.4f} — both agreed")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--games-dir", required=True)
    ap.add_argument("--actions", type=int, default=30)
    args = ap.parse_args()

    game_dirs = sorted(p.parent for p in Path(args.games_dir).rglob("metadata.json"))
    if not game_dirs:
        print(f"[selfcheck] no games under {args.games_dir}", file=sys.stderr)
        return 1
    failed = 0
    for game_dir in game_dirs:
        try:
            ok, message = check(game_dir, args.actions)
        except Exception as exc:  # noqa: BLE001
            ok, message = False, f"{type(exc).__name__}: {exc}"
        print(f"[selfcheck] {'ok  ' if ok else 'FAIL'} {game_dir.parent.name}: {message}")
        failed += not ok
    print(f"[selfcheck] {len(game_dirs) - failed}/{len(game_dirs)} games usable")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
