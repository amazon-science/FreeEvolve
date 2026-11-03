#!/usr/bin/env python3
"""One game-attempt: the harness side.

    attempt.py --game-dir <dir> --artifacts <dir> --target <dir> --model <id>
               [--max-actions n] [--timeout s] [--seed n]

This process owns the game and the score. It loads the game with the ARC-AGI engine,
starts a scorecard, and then spawns the agent in a child process and serves that child
one action at a time. Every action passes through here, so the action count, the level
transitions and the final score are the harness's record of what happened rather than
the agent's report of it.

What it writes into the artifacts directory:

    result.json     the attempt's outcome: score, levels, actions, cost, timings
    steps.jsonl     every action and the state it produced, in order
    scorecard.json  the toolkit's own scorecard for this attempt
    agent/          whatever the agent process wrote, plus its stdout and stderr

Exit status is 0 whenever the attempt produced a score, including when the agent
crashed or ran out of time — those are outcomes, not failures. It is non-zero only when
the attempt could not be run at all.
"""

from __future__ import annotations

import argparse
import json
import os
import select
import subprocess
import sys
import time
import traceback
from pathlib import Path
from typing import Any

HARNESS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(HARNESS_DIR))

from protocol import ACTION_IDS, COMPLEX_ACTIONS, send  # noqa: E402
from scoring import score_steps  # noqa: E402


class LineReader:
    """Read whole lines from a file descriptor, with a timeout, without buffering them.

    A `TextIOWrapper` around the child's stdout would be the obvious thing, but it holds
    a buffer of its own: two lines arriving in one read leave the second sitting in
    Python while `select` reports the descriptor as empty, and nothing reads it until
    more data happens to arrive. Reading the descriptor directly keeps the only buffer
    the one here, which is drained before waiting again.
    """

    def __init__(self, fd: int) -> None:
        self.fd = fd
        self.buffer = b""
        self.at_eof = False

    def readline(self, timeout: float) -> str | None:
        """A line without its newline, "" at end of stream, or None if timeout passed."""
        while True:
            newline = self.buffer.find(b"\n")
            if newline >= 0:
                line, self.buffer = self.buffer[:newline], self.buffer[newline + 1:]
                return line.decode("utf-8", "replace")
            if self.at_eof:
                return ""
            ready, _, _ = select.select([self.fd], [], [], max(0.0, timeout))
            if not ready:
                return None
            chunk = os.read(self.fd, 65536)
            if not chunk:
                self.at_eof = True
                return "" if not self.buffer else self.buffer.decode("utf-8", "replace")
            self.buffer += chunk


class Attempt:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.agent_summary: dict[str, Any] = {}
        self.artifacts = Path(args.artifacts)
        self.agent_dir = self.artifacts / "agent"
        self.agent_dir.mkdir(parents=True, exist_ok=True)
        self.steps: list[dict[str, Any]] = []
        self.steps_file = (self.artifacts / "steps.jsonl").open("w", encoding="utf-8")
        self.actions_used = 0
        self.last_frame: list[list[list[int]]] = []
        self.closed_reason: str | None = None
        self.started_at = 0.0

    # --- the game ------------------------------------------------------------
    def load_game(self) -> None:
        from arc_agi import Arcade, OperationMode

        game_dir = Path(self.args.game_dir).resolve()
        metadata = json.loads((game_dir / "metadata.json").read_text())
        self.full_game_id = metadata["game_id"]
        self.base_id = self.full_game_id.split("-", 1)[0]
        self.baselines: list[int] = list(metadata["baseline_actions"])
        self.title = metadata.get("title") or self.base_id

        # environments_dir points at this one game, so the engine loads exactly it and
        # the attempt cannot accidentally play a different version.
        self.arc = Arcade(
            operation_mode=OperationMode.OFFLINE,
            environments_dir=str(game_dir),
            recordings_dir=str(self.artifacts / "recordings"),
        )
        found = [e.game_id for e in self.arc.get_environments()]
        if found != [self.full_game_id]:
            raise RuntimeError(f"expected only {self.full_game_id} in {game_dir}, found {found}")

        self.card_id = self.arc.open_scorecard(tags=["freeevolve"])
        # make() performs the first RESET itself, which starts the play rather than
        # spending an action from the budget.
        self.env = self.arc.make(
            self.base_id, seed=self.args.seed, scorecard_id=self.card_id,
            save_recording=False, include_frame_data=False,
        )
        if self.env is None:
            raise RuntimeError(f"the engine could not make {self.full_game_id}")
        obs = self.env.observation_space
        if obs is None or obs.is_empty():
            raise RuntimeError(f"{self.full_game_id} produced no first frame")
        self.record(obs, action="RESET")

    # --- recording -----------------------------------------------------------
    def record(self, obs: Any, action: str, x: int | None = None, y: int | None = None) -> None:
        step = {
            "i": len(self.steps),
            "t": round(time.time() - self.started_at, 3) if self.started_at else 0.0,
            "action": action,
            "state": obs.state.value if hasattr(obs.state, "value") else str(obs.state),
            "levels_completed": obs.levels_completed,
            "full_reset": bool(getattr(obs, "full_reset", False)),
            "available_actions": obs.available_actions,
        }
        if not obs.frame:
            # The engine answered with no screen at all. The toolkit's scorecard ignores
            # such a response entirely — it neither counts an action nor reads a state
            # out of it — and the renderer skips it, leaving the previous screen up. So
            # this step is marked and the scoring skips it too, which is the only way the
            # harness's own count of actions can match the one the score is built from.
            step["no_frame"] = True
        if x is not None:
            step["x"], step["y"] = x, y
        self.steps.append(step)
        self.steps_file.write(json.dumps(step, separators=(",", ":")) + "\n")
        # Flushed every action, not at the end: a running attempt is something you want
        # to be able to read, and an attempt that never finishes is exactly the one worth
        # reading. Buffering made an hour-long hang look like an attempt that had not
        # started.
        self.steps_file.flush()

    def observation(self, obs: Any) -> dict[str, Any]:
        import numpy as np

        if obs.frame:
            self.last_frame = [np.asarray(layer).tolist() for layer in obs.frame]
        return {
            # Always a usable screen. When the engine returned none, the previous one is
            # still what the game is showing — the toolkit's own renderer keeps it up —
            # and `frame_returned` says that is what happened.
            "frame": self.last_frame,
            "frame_returned": bool(obs.frame),
            "state": obs.state.value if hasattr(obs.state, "value") else str(obs.state),
            "levels_completed": obs.levels_completed,
            "win_levels": obs.win_levels or len(self.baselines),
            "available_actions": [
                f"ACTION{i}" for i in (obs.available_actions or []) if i != 0
            ],
            "actions_used": self.actions_used,
            "actions_remaining": max(0, self.args.max_actions - self.actions_used),
            "seconds_remaining": round(self.seconds_remaining, 1),
            "plays": sum(1 for s in self.steps if s["full_reset"]),
        }

    @property
    def seconds_remaining(self) -> float:
        return max(0.0, self.deadline - time.time())

    # --- serving the agent ---------------------------------------------------
    def spawn_agent(self) -> subprocess.Popen[str]:
        env = dict(os.environ)
        # The edit surface first, then the harness: the agent imports its own modules,
        # and the session it is handed comes from here.
        env["PYTHONPATH"] = os.pathsep.join(
            [str(Path(self.args.target).resolve()), str(HARNESS_DIR)]
            + ([env["PYTHONPATH"]] if env.get("PYTHONPATH") else [])
        )
        env["PYTHONUNBUFFERED"] = "1"
        # The game is on this disk because the engine has to load it. Nothing tells the
        # agent process where, and it is not this process's job to help it look.
        env.pop("ENVIRONMENTS_DIR", None)
        self.agent_stderr = (self.agent_dir / "agent-stderr.txt").open("w", encoding="utf-8")
        return subprocess.Popen(
            [sys.executable, str(HARNESS_DIR / "agent_host.py")],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.agent_stderr,
            text=True, bufsize=1, env=env, cwd=str(self.agent_dir),
        )

    def apply(self, request: dict[str, Any]) -> dict[str, Any]:
        """Apply one request to the game, or say why it will not be applied."""
        from arcengine import GameAction

        op = request.get("op")
        if op == "reset":
            action_name = "RESET"
        elif op == "step":
            action_name = str(request.get("action", "")).upper()
        else:
            return {"ok": False, "error": f"bad_request: unknown op {op!r}"}

        if action_name not in ACTION_IDS:
            return {"ok": False, "error": f"bad_request: no action {action_name!r}"}

        last = self.env.observation_space
        if last is not None and getattr(last.state, "value", None) == "WIN":
            self.closed_reason = "game_won"
            return {"ok": False, "error": "game_won"}
        if self.actions_used >= self.args.max_actions:
            self.closed_reason = "budget_exhausted"
            return {"ok": False, "error": "budget_exhausted"}
        if self.seconds_remaining <= 0:
            self.closed_reason = "deadline_reached"
            return {"ok": False, "error": "deadline_reached"}

        x = y = None
        data: dict[str, Any] = {}
        if action_name in COMPLEX_ACTIONS:
            # Required, not defaulted. An action without them is a mistake, and a
            # harness that quietly clicked (0,0) instead would hide it: the attempt
            # would spend its whole budget in the top-left corner and the score would
            # look like a strategy that did not work.
            if request.get("x") is None or request.get("y") is None:
                return {"ok": False,
                        "error": f"bad_request: {action_name} needs x and y, each 0-63"}
            try:
                x, y = int(request["x"]), int(request["y"])
            except (TypeError, ValueError):
                return {"ok": False, "error": "bad_request: x and y must be integers"}
            if not (0 <= x <= 63 and 0 <= y <= 63):
                return {"ok": False, "error": f"bad_request: ({x},{y}) is outside 0-63"}
            data = {"x": x, "y": y}

        action = GameAction.from_id(ACTION_IDS[action_name])
        obs = (self.env.reset() if action_name == "RESET"
               else self.env.step(action, data))
        if obs is None:
            return {"ok": False, "error": "bad_request: the engine rejected that action"}

        # A full reset starts a new play instead of spending from the budget, and a
        # response that carried no screen is not counted at all — both exactly as the
        # toolkit's own scorecard counts them. Diverging here would make the harness's
        # action count, and so its score, disagree with the published one.
        started_a_play = action_name == "RESET" and getattr(obs, "full_reset", False)
        if obs.frame and not started_a_play:
            self.actions_used += 1
        self.record(obs, action_name, x, y)
        return {"ok": True, "obs": self.observation(obs)}

    def serve(self) -> None:
        child = self.spawn_agent()
        assert child.stdin and child.stdout
        first = self.observation(self.env.observation_space)
        send(child.stdin, {
            "op": "hello",
            "game": {"game_id": self.full_game_id, "title": self.title,
                     "total_levels": len(self.baselines),
                     "baseline_actions": self.baselines},
            "model": self.args.model,
            "artifacts_dir": str(self.agent_dir),
            "max_actions": self.args.max_actions,
            "obs": first,
        })

        reader = LineReader(child.stdout.fileno())
        # Once the attempt is over the agent is not cut off immediately: it is left with
        # a window to notice, come back from whatever call it was in, and report what it
        # spent. Killing it instead loses its token and dollar counts entirely, so an
        # evaluation whose attempts ran out of time would report a cost of nothing.
        closing_until: float | None = None
        while True:
            remaining = self.seconds_remaining
            if remaining <= 0 and closing_until is None:
                self.closed_reason = self.closed_reason or "deadline_reached"
                closing_until = time.time() + self.args.finish_grace
            if closing_until is not None:
                remaining = closing_until - time.time()
                if remaining <= 0:
                    self.closed_reason = "deadline_reached_no_report"
                    break
            line = reader.readline(min(remaining, 5.0))
            if line is None:          # nothing yet
                if child.poll() is not None:
                    break
                continue
            if line == "":            # the agent process is gone
                break
            try:
                request = json.loads(line)
            except json.JSONDecodeError:
                send(child.stdin, {"ok": False, "error": "bad_request: not JSON"})
                continue
            if request.get("op") == "done":
                self.closed_reason = self.closed_reason or "agent_finished"
                summary = request.get("summary")
                if isinstance(summary, dict):
                    self.agent_summary = summary
                break
            try:
                send(child.stdin, self.apply(request))
            except BrokenPipeError:
                break

        # Ask, then insist.
        try:
            if child.stdin and not child.stdin.closed:
                child.stdin.close()
        except Exception:
            pass
        try:
            self.agent_exit = child.wait(timeout=self.args.kill_grace)
        except subprocess.TimeoutExpired:
            child.kill()
            self.agent_exit = child.wait()
            self.closed_reason = self.closed_reason or "agent_killed"
        self.agent_stderr.close()

    # --- the score -----------------------------------------------------------
    def finish(self) -> dict[str, Any]:
        self.steps_file.close()
        official: dict[str, Any] = {}
        toolkit_score = None
        try:
            scorecard = self.arc.close_scorecard(self.card_id)
            if scorecard is not None:
                official = json.loads(scorecard.model_dump_json())
                (self.artifacts / "scorecard.json").write_text(
                    json.dumps(official, indent=2), encoding="utf-8")
                for environment in official.get("environments", []):
                    if environment.get("id", "").startswith(self.base_id):
                        toolkit_score = environment.get("score")
        except Exception:  # noqa: BLE001
            (self.artifacts / "scorecard-error.txt").write_text(
                traceback.format_exc(), encoding="utf-8")

        recomputed = score_steps(self.steps, self.baselines)
        # The toolkit reports the score out of 100; this is the same number as a
        # fraction. They are computed from different records of the same play, so a
        # disagreement means one of the records is wrong.
        agrees = (toolkit_score is None
                  or abs(toolkit_score / 100.0 - recomputed["score"]) < 1e-6)

        summary = self.agent_summary if isinstance(self.agent_summary, dict) else {}
        cost = summary.get("cost_usd") or 0.0
        if not cost:
            cost = (
                (summary.get("n_input_tokens") or 0) / 1e6 * self.args.price_in
                + (summary.get("n_output_tokens") or 0) / 1e6 * self.args.price_out
            )

        result = {
            "game_id": self.full_game_id,
            "base_id": self.base_id,
            "title": self.title,
            # The score, as a fraction of the human-efficiency ceiling. This is the
            # reward: the environment's key metric is its mean over attempts.
            "reward": recomputed["score"],
            "score_toolkit": None if toolkit_score is None else toolkit_score / 100.0,
            "scores_agree": agrees,
            "levels_completed": recomputed["levels_completed"],
            "total_levels": len(self.baselines),
            "actions_used": self.actions_used,
            "max_actions": self.args.max_actions,
            "plays": recomputed["plays"],
            "closed_reason": self.closed_reason,
            "wall_clock_sec": round(time.time() - self.started_at, 1),
            "agent_exit_code": getattr(self, "agent_exit", None),
            "agent_summary": summary,
            # False when the agent never reported: its tokens and cost are then missing
            # from this attempt and from the evaluation's total.
            "cost_complete": bool(summary),
            "cost_usd": cost,
            "model": self.args.model,
            "seed": self.args.seed,
        }
        (self.artifacts / "result.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
        return result

    def run(self) -> int:
        self.load_game()
        self.started_at = time.time()
        self.deadline = self.started_at + self.args.timeout
        try:
            self.serve()
        except Exception:  # noqa: BLE001
            (self.artifacts / "harness-error.txt").write_text(
                traceback.format_exc(), encoding="utf-8")
            self.closed_reason = self.closed_reason or "harness_error"
        result = self.finish()
        print(f"[attempt] {result['base_id']} reward={result['reward']:.4f} "
              f"levels={result['levels_completed']}/{result['total_levels']} "
              f"actions={result['actions_used']} {result['closed_reason']} "
              f"{result['wall_clock_sec']}s ${result['cost_usd']:.2f}")
        if not result["scores_agree"]:
            print(f"[attempt] SCORES DISAGREE: toolkit={result['score_toolkit']} "
                  f"recomputed={result['reward']}", file=sys.stderr)
        return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--game-dir", required=True)
    ap.add_argument("--artifacts", required=True)
    ap.add_argument("--target", required=True, help="the edit surface directory")
    ap.add_argument("--model", required=True)
    ap.add_argument("--max-actions", type=int, default=600)
    ap.add_argument("--timeout", type=float, default=1800)
    ap.add_argument("--kill-grace", type=float, default=20)
    # How long the agent has, after the attempt is over, to return and report what it
    # spent. Long enough to outlast the model call it is probably inside.
    ap.add_argument("--finish-grace", type=float, default=180)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--price-in", type=float, default=3.0)
    ap.add_argument("--price-out", type=float, default=15.0)
    args = ap.parse_args()
    return Attempt(args).run()


if __name__ == "__main__":
    sys.exit(main())
