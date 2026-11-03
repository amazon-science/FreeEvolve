#!/usr/bin/env python3
"""The agent side of the boundary: loads the agent and hands it a session.

This process holds no game and no score. It receives observations from the harness,
gives the agent one object to act through, and reports back what the agent returned.
It is not part of the edit surface — `session.py`'s docstring is the contract the agent
is written against.

The protocol occupies this process's real stdin and stdout, so both are taken away from
the agent before it is imported: anything it prints lands in `agent-stdout.txt` instead.
"""

from __future__ import annotations

import importlib
import json
import os
import sys
import traceback
from pathlib import Path
from typing import Any, IO

HARNESS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(HARNESS_DIR))

from protocol import SessionClosed, send  # noqa: E402
from session import GameSession  # noqa: E402


def take_stdout() -> tuple[IO[str], IO[str]]:
    """Move the protocol onto a private copy of stdout and give stdout to the agent."""
    protocol = os.fdopen(os.dup(1), "w", buffering=1, encoding="utf-8")
    log = open("agent-stdout.txt", "w", buffering=1, encoding="utf-8")
    os.dup2(log.fileno(), 1)
    sys.stdout = log
    return protocol, log


def main() -> int:
    protocol_out, _log = take_stdout()
    protocol_in = sys.stdin

    hello = json.loads(protocol_in.readline())
    if hello.get("op") != "hello":
        print(f"[host] expected hello, got {hello!r}", file=sys.stderr)
        return 2

    session = GameSession(
        protocol_in=protocol_in,
        protocol_out=protocol_out,
        game=hello["game"],
        first_observation=hello["obs"],
        max_actions=hello["max_actions"],
    )

    summary: dict[str, Any] = {}
    error = None
    try:
        module_name, class_name = os.environ.get(
            "ARC3_AGENT_IMPORT_PATH", "arc3_agent:ARC3Agent").split(":", 1)
        agent_class = getattr(importlib.import_module(module_name), class_name)
        agent = agent_class(
            model=hello["model"],
            artifacts_dir=Path(hello["artifacts_dir"]),
        )
        returned = agent.play(session)
        if isinstance(returned, dict):
            summary = returned
    except SessionClosed as closed:
        # The attempt ended under the agent while it was mid-action. Not an error.
        summary.setdefault("stop_reason", closed.reason)
    except BaseException:  # noqa: BLE001 - a crashing agent still has a real score
        error = traceback.format_exc()
        print(error, file=sys.stderr)

    if error:
        summary["agent_error"] = error.strip().splitlines()[-1]
        summary["agent_traceback"] = error
    summary.setdefault("actions_taken", session.actions_used)
    summary.setdefault("stop_reason", session.closed_reason or "returned")

    try:
        send(protocol_out, {"op": "done", "summary": summary})
    except BrokenPipeError:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
