"""The game, as the agent sees it.

An agent is handed one of these and plays through it. It is the agent's ONLY route into
the game: the engine, the scorecard and the action count live in the harness process,
and every call here is a request across that boundary.

    session.game_id            e.g. "ls20-9607627b"
    session.title              e.g. "LS20"
    session.total_levels       how many levels the game has
    session.baseline_actions   how many actions a human needed for each level, in order
    session.max_actions        the attempt's action budget

    session.observation        the latest Observation (see below)
    session.actions_used       how many of the budget have been spent
    session.actions_remaining
    session.seconds_remaining  wall clock left in the attempt

    session.step("ACTION1")            -> Observation
    session.step("ACTION6", x=3, y=7)  -> Observation
    session.reset()                    -> Observation

An Observation carries:

    obs.frame              a list of 64x64 grids of integers 0-15. Usually one.
    obs.frame_returned     False when the game produced no new screen for that action.
                           The known cause is acting while the state is already
                           GAME_OVER: the game ignores it. `obs.frame` is then the
                           previous screen, which is still what the game is showing, and
                           the action was NOT counted against the budget — the published
                           scoring ignores such a response completely, so this does too.
    obs.state              "NOT_FINISHED", "WIN" or "GAME_OVER"
    obs.levels_completed   how many levels are finished
    obs.win_levels         how many there are
    obs.available_actions  which action names this game accepts, e.g. ["ACTION1", ...]
    obs.plays              how many times the game has been started

Both `step` and `reset` raise `SessionClosed` when the harness will not accept another
action — the budget is spent, the clock ran out, or the game has been won. That is the
attempt ending, not a failure: there is nothing to retry, and whatever the agent has
already achieved is already recorded. Letting it propagate is fine; catching it to
write a last note is fine too.

A malformed request raises `ValueError` and does not cost an action: an action name that
does not exist, `ACTION6` without coordinates, or coordinates outside 0-63.

An action the game merely does not list in `available_actions` is NOT malformed. It is
sent, it comes back with a screen, and it costs an action like any other — it just does
nothing. `available_actions` is information, not a guard.
"""

from __future__ import annotations

from typing import Any, IO

from protocol import SessionClosed, recv, send


class Observation:
    """One frame and the state that came with it."""

    __slots__ = ("frame", "frame_returned", "state", "levels_completed", "win_levels",
                 "available_actions", "plays", "raw")

    def __init__(self, data: dict[str, Any]) -> None:
        self.raw = data
        self.frame: list[list[list[int]]] = data["frame"]
        self.frame_returned: bool = data.get("frame_returned", True)
        self.state: str = data["state"]
        self.levels_completed: int = data["levels_completed"]
        self.win_levels: int = data["win_levels"]
        self.available_actions: list[str] = data["available_actions"]
        self.plays: int = data["plays"]

    @property
    def grid(self) -> list[list[int]]:
        """The first frame layer, which is the whole picture in every public game."""
        return self.frame[0]

    def __repr__(self) -> str:
        return (f"Observation(state={self.state}, "
                f"levels_completed={self.levels_completed}/{self.win_levels}, "
                f"layers={len(self.frame)}, frame_returned={self.frame_returned})")


class GameSession:
    def __init__(self, *, protocol_in: IO[str], protocol_out: IO[str],
                 game: dict[str, Any], first_observation: dict[str, Any],
                 max_actions: int) -> None:
        self._in = protocol_in
        self._out = protocol_out
        self.game_id: str = game["game_id"]
        self.title: str = game["title"]
        self.total_levels: int = game["total_levels"]
        self.baseline_actions: list[int] = game["baseline_actions"]
        self.max_actions: int = max_actions
        self.closed_reason: str | None = None
        self._apply(first_observation)

    def _apply(self, data: dict[str, Any]) -> Observation:
        self.observation = Observation(data)
        self.actions_used: int = data["actions_used"]
        self.actions_remaining: int = data["actions_remaining"]
        self.seconds_remaining: float = data["seconds_remaining"]
        return self.observation

    def _request(self, message: dict[str, Any]) -> Observation:
        if self.closed_reason:
            raise SessionClosed(self.closed_reason)
        send(self._out, message)
        reply = recv(self._in)
        if reply is None:
            self.closed_reason = "harness_gone"
            raise SessionClosed(self.closed_reason)
        if reply.get("ok"):
            return self._apply(reply["obs"])
        error = str(reply.get("error", "unknown"))
        if error.startswith("bad_request"):
            raise ValueError(error)
        self.closed_reason = error
        raise SessionClosed(error)

    def step(self, action: str, x: int | None = None, y: int | None = None) -> Observation:
        message: dict[str, Any] = {"op": "step", "action": action}
        if x is not None or y is not None:
            message["x"], message["y"] = x, y
        return self._request(message)

    def reset(self) -> Observation:
        return self._request({"op": "reset"})
