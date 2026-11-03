"""The line protocol between the harness and the agent process.

One JSON object per line, in both directions, over a pair of pipes. It exists because
the game engine and the score must not live in the same process as the agent: the
harness applies every action, counts it, and computes the score, and the agent's only
route into the game is a request across this boundary.

Requests the agent process may send:

    {"op": "step",  "action": "ACTION1"}                  a simple action
    {"op": "step",  "action": "ACTION6", "x": 3, "y": 7}   an action with coordinates
    {"op": "reset", }                                      RESET
    {"op": "done",  "summary": {...}}                      finished; stop the attempt

Replies:

    {"ok": true,  "obs": {...}}
    {"ok": false, "error": "budget_exhausted"}   no actions left
    {"ok": false, "error": "deadline_reached"}   no time left
    {"ok": false, "error": "game_won"}           every level is finished
    {"ok": false, "error": "bad_request: ..."}   the request did not parse

An observation:

    {"frame": [[[int]]],          one or more 64x64 grids of 0-15
     "frame_returned": bool,      false when the engine produced no new screen, in which
                                  case `frame` is the previous one and no action was spent
     "state": "NOT_FINISHED" | "WIN" | "GAME_OVER" | "NOT_PLAYED",
     "levels_completed": int,     how many levels are finished
     "win_levels": int,           how many there are in total
     "available_actions": ["ACTION1", ...],
     "actions_used": int,         drawn from the budget so far
     "actions_remaining": int,
     "seconds_remaining": float,
     "plays": int}                how many times the game has been started
"""

from __future__ import annotations

import json
from typing import Any, IO

ACTION_NAMES = {
    0: "RESET",
    1: "ACTION1",
    2: "ACTION2",
    3: "ACTION3",
    4: "ACTION4",
    5: "ACTION5",
    6: "ACTION6",
    7: "ACTION7",
}
ACTION_IDS = {name: value for value, name in ACTION_NAMES.items()}
# The only action that carries coordinates. Both are 0-63; the engine validates them
# and (0,0) is the top-left cell.
COMPLEX_ACTIONS = {"ACTION6"}


def send(stream: IO[str], obj: Any) -> None:
    stream.write(json.dumps(obj, separators=(",", ":")) + "\n")
    stream.flush()


def recv(stream: IO[str]) -> Any:
    """Read one message. Returns None at end of stream."""
    line = stream.readline()
    if not line:
        return None
    return json.loads(line)


class SessionClosed(RuntimeError):
    """The harness will not accept another action.

    Raised in the agent process by the session, carrying the harness's reason:
    `budget_exhausted`, `deadline_reached` or `game_won`. It is not an error in the
    agent — it is the attempt being over — and there is nothing to retry.
    """

    def __init__(self, reason: str) -> None:
        super().__init__(reason)
        self.reason = reason
