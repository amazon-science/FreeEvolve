#!/usr/bin/env python3
"""What the agent does with the game.

The loop is: show the model the current screen, let it choose an action, apply it, show
it what happened, repeat. It stops when the harness says the attempt is over.
"""

from __future__ import annotations

import json
import traceback
from typing import Any

import litellm

from session import SessionClosed

litellm.drop_params = True

# The model capability this agent runs at. FIXED, not a knob: raising, lowering or
# removing any of these changes how much inference the agent buys per call rather than
# how well the agent is built. See ENVIRONMENT.md.
DEFAULT_MAX_TOKENS = 32768
DEFAULT_REASONING_EFFORT = "high"
# Extended thinking requires temperature 1.0, so the agent is sampled rather than
# greedy and repeated attempts at the same game differ.
DEFAULT_TEMPERATURE = 1.0
DEFAULT_MAX_RETRIES = 4
# How long one model call may take before it is abandoned and retried. Not a capability
# knob — a connection that stops answering does not answer later. Without it a single
# stalled request holds the attempt until its deadline: measured once, at 49 minutes on
# one call, which cost the attempt everything it had not done yet. 600 rather than 180
# because at this reasoning effort a single call legitimately thinks for minutes, and a
# timeout shorter than the model's own thinking abandons good calls.
DEFAULT_REQUEST_TIMEOUT_SEC = 600

# How many recent turns are sent to the model. A bound, not a schedule: an attempt runs
# for hundreds of turns, and a conversation that kept all of them would grow the input
# of every call until the cost of the attempt was quadratic in its length. Turns are
# dropped whole — the model's message together with the results of its actions — because
# a call that reports an action without its result is not a valid conversation.
DEFAULT_TURNS_KEPT = 12
# Within those, how many of the most recent screens are sent at full size. Older ones
# are replaced by the line that says what changed. A screen is 64x64 numbers.
DEFAULT_SCREENS_KEPT = 3
# How many turns may go by without the model choosing an action before giving up.
DEFAULT_MAX_IDLE_TURNS = 3

DIGITS = "0123456789abcdef"

SYSTEM_PROMPT = """
You are playing a game you have never seen before. Nobody will tell you the rules, what
the goal is, or what the controls do — you find that out by playing.

Each turn you see the game's screen as a 64x64 grid of integers 0-15, where each number
is a colour, and you choose an action. The screen you get back is the game's response to
it. Only the actions the screen says the game accepts will do anything. ACTION6 needs a
column x and a row y, each 0-63; the others take no arguments. RESET restarts play, and
is how you recover from GAME_OVER.

The game has levels. Finishing a level advances a counter you are shown. Finishing all
of them wins the game.

You will only be shown the last few turns of this conversation, so anything you want to
remember about the game you have to say in a way that survives being the only thing left.
""".strip()

TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "act",
            "description": "Take one action in the game and see the screen it produces.",
            "parameters": {
                "type": "object",
                "properties": {
                    "action": {
                        "type": "string",
                        "description": "The action to take, e.g. ACTION1, or RESET.",
                    },
                    "x": {"type": "integer", "description": "Column 0-63. Required for ACTION6."},
                    "y": {"type": "integer", "description": "Row 0-63. Required for ACTION6."},
                },
                "required": ["action"],
            },
        },
    }
]


def render(grid: list[list[int]]) -> str:
    """The screen as text, with row and column numbers so coordinates can be read off."""
    width = len(grid[0]) if grid else 0
    tens = "    " + "".join(str((x // 10) % 10) if x % 10 == 0 else " " for x in range(width))
    ones = "    " + "".join(DIGITS[x % 10] for x in range(width))
    rows = [f"{y:3d} " + "".join(DIGITS[v & 0xF] for v in row) for y, row in enumerate(grid)]
    return "\n".join([tens, ones, *rows])


def describe(session: Any, obs: Any) -> str:
    lines = [
        f"state: {obs.state}",
        f"levels finished: {obs.levels_completed} of {obs.win_levels}",
        f"actions used: {session.actions_used} of {session.max_actions}",
        f"actions this game accepts: {', '.join(obs.available_actions) or 'none'}",
    ]
    if not obs.frame_returned:
        lines.append("the game produced no new screen for that action, and it was not "
                     "counted against your budget; the screen below is the previous one")
    elif len(obs.frame) > 1:
        lines.append(f"({len(obs.frame)} screens came back; the last one is shown)")
    return "\n".join(lines) + "\n\n" + render(obs.frame[-1])


def elide(message: dict[str, Any]) -> dict[str, Any]:
    """The same tool result without the screen: the state lines stay, the picture goes."""
    head = str(message.get("content", "")).split("\n\n")[0]
    return {**message, "content": head + "\n\n(screen dropped from the history)"}


def opening_message(session: Any) -> dict[str, Any]:
    baselines = ", ".join(str(b) for b in session.baseline_actions)
    return {
        "role": "user",
        "content": (
            f"You are playing {session.title}. It has {session.total_levels} levels. A "
            f"human seeing it for the first time finished them in {baselines} actions "
            f"respectively, which is roughly what a reasonable number of actions looks "
            f"like.\n\nYou have {session.max_actions} actions in total. Here is the "
            f"opening screen.\n\n" + describe(session, session.observation)
        ),
    }


class Player:
    """One attempt's worth of playing: the conversation, and what it has cost so far.

    The tally lives on the instance rather than in locals so that it survives the loop
    ending for any reason. An attempt that fell over still has a real score — the levels
    it had already finished — and the tokens it had already spent are part of what the
    evaluation cost; both would be lost if they only existed inside the loop.
    """

    def __init__(self, *, session: Any, model: str) -> None:
        self.session = session
        self.model = model
        self.system = {"role": "system", "content": SYSTEM_PROMPT}
        self.opening = opening_message(session)
        # One turn is the model's message plus the results of the actions it asked for.
        self.turns: list[list[dict[str, Any]]] = []
        self.everything: list[dict[str, Any]] = [self.system, self.opening]

        self.calls = 0
        self.idle_turns = 0
        self.in_tokens = 0
        self.out_tokens = 0
        self.cost = 0.0
        self.finish_reasons: list[str] = []
        self.rejected = 0
        self.actions_taken = 0
        self.stop_reason = "session_closed"

    def window(self) -> list[dict[str, Any]]:
        kept = self.turns[-DEFAULT_TURNS_KEPT:]
        messages = [self.system, self.opening]
        for index, turn in enumerate(kept):
            recent = index >= len(kept) - DEFAULT_SCREENS_KEPT
            for message in turn:
                messages.append(
                    message if recent or message.get("role") != "tool" else elide(message))
        return messages

    def keep(self, turn: list[dict[str, Any]]) -> None:
        self.turns.append(turn)
        self.everything.extend(turn)

    def ask(self) -> Any:
        response = litellm.completion(
            model=self.model,
            messages=self.window(),
            tools=TOOLS,
            tool_choice="auto",
            max_tokens=DEFAULT_MAX_TOKENS,
            reasoning_effort=DEFAULT_REASONING_EFFORT,
            temperature=DEFAULT_TEMPERATURE,
            num_retries=DEFAULT_MAX_RETRIES,
            timeout=DEFAULT_REQUEST_TIMEOUT_SEC,
        )
        self.calls += 1
        choice = response.choices[0]
        usage = getattr(response, "usage", None)
        self.in_tokens += getattr(usage, "prompt_tokens", 0) or 0
        self.out_tokens += getattr(usage, "completion_tokens", 0) or 0
        self.finish_reasons.append(choice.finish_reason)
        try:
            self.cost += litellm.completion_cost(completion_response=response) or 0.0
        except Exception:  # noqa: BLE001
            pass
        return choice.message

    def take(self, call: Any) -> str:
        """Apply one tool call to the game and return what to tell the model about it."""
        try:
            arguments = json.loads(call.function.arguments or "{}")
        except ValueError:
            arguments = {}
        action = str(arguments.get("action", "")).upper()
        obs = self.session.step(action, x=arguments.get("x"), y=arguments.get("y"))
        self.actions_taken += 1
        return describe(self.session, obs)

    def play(self) -> None:
        while True:
            message = self.ask()
            turn: list[dict[str, Any]] = [message.model_dump(exclude_none=True)]

            tool_calls = getattr(message, "tool_calls", None) or []
            if not tool_calls:
                self.idle_turns += 1
                if self.idle_turns >= DEFAULT_MAX_IDLE_TURNS:
                    self.stop_reason = "stopped_choosing_actions"
                    self.keep(turn)
                    return
                turn.append({"role": "user", "content": "Call act to take an action."})
                self.keep(turn)
                continue
            self.idle_turns = 0

            closed: str | None = None
            for call in tool_calls:
                if closed is not None:
                    content = f"The attempt is over: {closed}."
                else:
                    try:
                        content = self.take(call)
                    except SessionClosed as over:
                        closed = over.reason
                        content = f"The attempt is over: {closed}."
                    except ValueError as bad:
                        self.rejected += 1
                        available = self.session.observation.available_actions
                        content = (
                            f"{bad}\nNothing happened and no action was spent. This game "
                            f"accepts: {', '.join(available) or 'nothing'}."
                        )
                turn.append({"role": "tool", "tool_call_id": call.id, "content": content})
            self.keep(turn)

            if closed is not None:
                self.stop_reason = closed
                return

    def summary(self) -> dict[str, Any]:
        return {
            "stop_reason": self.stop_reason,
            "model_calls": self.calls,
            "actions_taken": self.actions_taken,
            "actions_per_call": round(self.actions_taken / self.calls, 3) if self.calls else 0,
            "rejected_actions": self.rejected,
            "levels_completed": self.session.observation.levels_completed,
            "final_state": self.session.observation.state,
            "n_input_tokens": self.in_tokens,
            "n_output_tokens": self.out_tokens,
            "cost_usd": self.cost,
            "max_tokens": DEFAULT_MAX_TOKENS,
            "reasoning_effort": DEFAULT_REASONING_EFFORT,
            "turns_kept": DEFAULT_TURNS_KEPT,
            "finish_reasons": self.finish_reasons[-20:],
            "n_length_capped_replies": sum(1 for r in self.finish_reasons if r == "length"),
        }


def play_game(*, session: Any, model: str) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    player = Player(session=session, model=model)
    try:
        player.play()
    except Exception as failure:  # noqa: BLE001
        # Reported, not raised: see Player's docstring for why the tally has to outlive
        # this. A provider error in the middle of an attempt is a thing that happens, and
        # an attempt it ended is worth telling apart from one the agent chose to end.
        player.stop_reason = f"error: {type(failure).__name__}: {failure}"[:300]
        print(traceback.format_exc())
    return player.summary(), player.everything
