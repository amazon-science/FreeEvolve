"""Relative Human Action Efficiency, recomputed from the harness's own step log.

The ARC-AGI toolkit computes this itself, from the scorecard it keeps while a game is
played, and that is the number the attempt reports. This module computes the same thing
a second time from `steps.jsonl` — the harness's record of what was actually sent and
what came back — and the attempt records both. Two independent numbers over the same
play either agree, in which case the score is trustworthy, or disagree, in which case
something about the recording or the scorecard is wrong and the run says so instead of
quietly reporting one of them.

The formula, from the published methodology:

    level_score  = min((baseline_actions / actions_taken) ** 2, 1.15)   if completed
                 = 0                                                    otherwise
    game_score   = sum(level_score[i] * i) / sum(i)     over ALL levels, i 1-indexed
                 capped at the ceiling reachable given which levels were finished

Every level of the game is in the denominator, finished or not, so a game whose later
levels were never reached cannot score 100% however efficient the early ones were.
Actions after the last completed level are attributed to the first unfinished one.
"""

from __future__ import annotations

from typing import Any, Iterable

LEVEL_SCORE_CAP = 1.15


def level_score(actions_taken: int, baseline_actions: int) -> float:
    if actions_taken <= 0:
        return 0.0
    return min((baseline_actions / actions_taken) ** 2, LEVEL_SCORE_CAP)


def score_play(level_actions: list[int], completed: list[bool],
               baselines: list[int]) -> dict[str, Any]:
    """Score one play. `level_actions` and `completed` are per level, 1-indexed."""
    scores = [
        level_score(level_actions[i], baselines[i]) if completed[i] else 0.0
        for i in range(len(baselines))
    ]
    total = sum(s * (i + 1) for i, s in enumerate(scores))
    weights = sum(i + 1 for i in range(len(baselines)))
    reachable = sum(i + 1 for i, s in enumerate(scores) if s > 0)
    score = min(total / weights, reachable / weights) if weights else 0.0
    return {
        "score": score,
        "level_scores": scores,
        "level_actions": level_actions,
        "level_baseline_actions": baselines,
        "levels_completed": sum(completed),
    }


def plays_from_steps(steps: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
    """Split the step log into plays and count actions per level within each.

    A play begins at a full reset — the engine says so, in `full_reset` — and every
    action after it draws on that play. A RESET that is not a full reset costs an
    action and leaves the play it is in; that is what recovering from GAME_OVER does.
    """
    plays: list[dict[str, Any]] = []
    for step in steps:
        if step.get("no_frame"):
            # The engine answered with no screen. The toolkit's scorecard ignores such a
            # response completely, so this skips it too: it did not cost an action and no
            # state is read out of it.
            continue
        if step.get("full_reset") or not plays:
            plays.append({"actions": 0, "level_at_action": [], "final_state": None,
                          "resets": 0, "max_levels": 0})
            # A full reset itself is not an action: it starts the play rather than
            # spending from it. This mirrors the toolkit's own scorecard.
            if step.get("full_reset"):
                plays[-1]["final_state"] = step.get("state")
                plays[-1]["max_levels"] = step.get("levels_completed", 0)
                continue
        play = plays[-1]
        play["actions"] += 1
        if step.get("action") == "RESET":
            play["resets"] += 1
        levels = step.get("levels_completed", 0)
        if levels > play["max_levels"]:
            # Record the action count at which each new level was first finished.
            for _ in range(play["max_levels"], levels):
                play["level_at_action"].append(play["actions"])
            play["max_levels"] = levels
        play["final_state"] = step.get("state")
    return plays


def score_steps(steps: Iterable[dict[str, Any]], baselines: list[int]) -> dict[str, Any]:
    """Score every play in the log, official-style: the game's score is the best play."""
    per_play = []
    for play in plays_from_steps(steps):
        n_levels = len(baselines)
        marks = play["level_at_action"][:n_levels]
        level_actions: list[int] = []
        completed: list[bool] = []
        prev = 0
        for i in range(n_levels):
            if i < len(marks):
                level_actions.append(marks[i] - prev)
                completed.append(True)
                prev = marks[i]
            else:
                # All remaining actions land on the first unfinished level.
                level_actions.append(play["actions"] - prev)
                completed.append(False)
                prev = play["actions"]
        scored = score_play(level_actions, completed, baselines)
        scored.update(actions=play["actions"], resets=play["resets"],
                      state=play["final_state"])
        per_play.append(scored)
    best = max((p["score"] for p in per_play), default=0.0)
    return {
        "score": best,
        "plays": per_play,
        "actions": sum(p["actions"] for p in per_play),
        "levels_completed": max((p["levels_completed"] for p in per_play), default=0),
    }
