#!/usr/bin/env python3
"""The harness-facing side of the game agent.

The harness imports `ARC3Agent` from here, constructs one per attempt, and calls
`play(session)` once. Everything the agent does happens inside that call.

    ARC3Agent(model=..., artifacts_dir=...)
    agent.play(session) -> dict | None

`session` is the game (see the harness's `session.py` for what it offers). The returned
dictionary is recorded with the attempt; `cost_usd`, `n_input_tokens` and
`n_output_tokens` are read out of it for the evaluation's totals, and everything else in
it is kept as-is.

This module is the place for how the agent is set up and what it records. What it
actually does with the game is in `run_arc3_agent.py`.
"""

from __future__ import annotations

import json
import traceback
from pathlib import Path
from typing import Any

from run_arc3_agent import play_game


class ARC3Agent:
    def __init__(self, *, model: str, artifacts_dir: Path) -> None:
        self.model = model
        self.artifacts_dir = Path(artifacts_dir)
        self.artifacts_dir.mkdir(parents=True, exist_ok=True)

    def play(self, session: Any) -> dict[str, Any]:
        summary: dict[str, Any] = {}
        transcript: list[dict[str, Any]] = []
        error = None
        try:
            summary, transcript = play_game(session=session, model=self.model)
        except Exception:  # noqa: BLE001
            error = traceback.format_exc()
            print(error)

        summary["model"] = self.model
        if error:
            summary["error"] = error.strip().splitlines()[-1]

        # Written here rather than returned, because a transcript of a few hundred
        # actions is far too large to hand back through the harness.
        (self.artifacts_dir / "arc3-agent-summary.json").write_text(
            json.dumps(summary, indent=2, default=str), encoding="utf-8")
        (self.artifacts_dir / "arc3-agent-transcript.json").write_text(
            json.dumps({"summary": summary, "messages": transcript},
                       indent=2, default=str), encoding="utf-8")
        return summary
