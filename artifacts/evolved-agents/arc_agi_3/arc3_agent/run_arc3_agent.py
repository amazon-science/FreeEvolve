#!/usr/bin/env python3
"""What the agent does with the game.

The loop is: show the model the current screen, let it choose actions, apply them, show
it what happened, repeat. It stops when the harness says the attempt is over.

Three things this does beyond showing a screen and taking one action:

* the screen comes with its own structure worked out — the scale it is drawn at where that
  is uniform, and otherwise where its column and row boundaries are, which is what decides
  where a click has to land;
* what an action *changed* is computed here and stated in words, because diffing two
  grids by eye is the one thing a language model reliably gets wrong;
* actions are asked for as a sequence, in one short string, and the sequence stops early
  the moment the screen stops behaving as expected. Measured on this setup, an attempt's
  wall clock goes almost entirely on generated tokens rather than on actions: deciding one
  action at a time cost about 420 output tokens per action and got through ten actions a
  minute, and the games in this set need hundreds of actions.
"""

from __future__ import annotations

import difflib
import json
import os
import re
import time
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
DEFAULT_MAX_RETRIES = 0
# How long one model call may take before it is abandoned and retried. Not a capability
# knob — a connection that stops answering does not answer later, and this buys no extra
# inference; it decides how long a stall is paid for. Measured on the version this one
# replaces: at 600s with four internal retries, three of seventeen attempts lost between
# 900 and 1900 seconds of their 7200 sitting in one call, roughly a quarter of the attempt.
# 600, after measuring both ends of it. The reply text this agent produces is empty — every
# output token is hidden thinking — and calls came in at 1100 to 2400 tokens on the games
# that went well but 4000 to 10000 on three that stalled. At 240s those long-thinking calls
# were aborted and retried into the same long thought: m0r0, r11l and tr87 each lost ten
# minutes to it. What made 600 dangerous before was not its length but that the *client*
# retried it four times on an identical prompt, up to 3000s on one ask. So: all retries are
# driven by the loop below instead (num_retries above is 0), every retry changes the prompt,
# and two abandoned calls in a row tell the model to answer with a sequence and nothing else.
DEFAULT_REQUEST_TIMEOUT_SEC = 600
# Above this many output tokens in one reply, the model is told it is spending the clock on
# thinking. Measured: the attempts that went well came in at 1100-2400 output tokens a call
# and the three that stalled at 4000-10000, so this sits just above the healthy range. The
# model cannot see its own token count, and it is the only party that can bring it down.
SLOW_REPLY_TOKENS = 4000
# How much of a multi-screen response is described. Long enough to see a piece run a whole
# program, short enough that a chain reaction cannot fill the window.
ANIMATION_FRAMES = 10
ANIMATION_CHARS = 220
# After this many model calls without finishing a level, the agent is told it is stuck, and
# the advice escalates every this-many calls after that. Measured reason for an escalation
# rather than one message: the runs that lose whole games are the ones that spend hundreds of
# actions refining a model of the level that was wrong from the start, and repeating "go and
# get data" does not dislodge that — it has to be told to doubt the goal, then to restart the
# level, then to go back to the actions it wrote off.
STALL_CALLS = 8
# How similar to an earlier sequence counts as running the same experiment again, and how
# many of the recent ones a new one is compared against.
NEAR_REPEAT = 0.75
PAST_SEQUENCES = 40
LONG_REPLY = ("Your last reply cost {n} output tokens. That is thinking, not acting, and the "
              "clock goes on it: at this rate you get a few dozen actions out of the whole "
              "attempt. Decide from your notes and the change list, and send a longer `run` "
              "instead of a longer thought.")
# What is said to the model after its replies have been abandoned for taking too long. It
# cannot see that this happened, and it is the only party that can make the next one shorter.
TOO_SLOW = ("Your last {n} replies were abandoned for taking too long — that is minutes of "
            "your clock gone for nothing, and the clock is what ends this attempt. Answer "
            "this one with a single `run` call and no thinking beyond what it needs: pick "
            "the most useful sequence you can see and send it.")

# How many recent turns are sent to the model. A bound, not a schedule: an attempt runs
# for hundreds of turns, and a conversation that kept all of them would grow the input
# of every call until the cost of the attempt was quadratic in its length. Turns are
# dropped whole — the model's message together with the results of its actions — because
# a call that reports an action without its result is not a valid conversation.
DEFAULT_TURNS_KEPT = 10
# Within those, how many of the most recent screens are sent at full size. Older ones
# are replaced by the line that says what changed. A screen is 64x64 numbers.
DEFAULT_SCREENS_KEPT = 2
# How many turns may go by without the model choosing an action before giving up.
DEFAULT_MAX_IDLE_TURNS = 4
# The most actions one model call may ask for, over all its tool calls together. A
# ceiling on how much can be spent blind: a sequence also stops early the moment the game
# stops behaving as expected.
DEFAULT_BATCH_CAP = 40
# A provider error is not the end of an attempt, and neither is a hundred of them. The
# loop retries for as long as the attempt has clock left, because there is nothing better
# to do with the remaining time than ask again: measured here, one attempt (tr87) hit a
# run of client timeouts and a fixed retry count would have ended it with 90% of its clock
# unspent and its score frozen at whatever it had. This is the sleep between tries.
DEFAULT_ASK_BACKOFF_SEC = 20

DIGITS = "0123456789abcdef"
MOVES = ("ACTION1", "ACTION2", "ACTION3", "ACTION4", "ACTION5", "ACTION7")

SYSTEM_PROMPT = """
You are playing a game you have never seen before. Nobody will tell you the rules, what
the goal is, or what the controls do — you find that out by playing.

The screen is a 64x64 grid of small integers, one per cell, each standing for a colour,
with (0,0) at the top left. Above it you are told which colours are present and where the
screen's own column and row boundaries are: adjacent columns that are identical all the way
down are one column of whatever the game is drawing, so those boundaries are the board's
grid, and a click has to land inside a cell rather than on its edge. Where the whole screen
is painted in uniform kxk blocks you are shown it at that scale instead, and the header
says so; then bx/by in a click means block coordinates and is converted for you.

WHAT YOU ARE SCORED ON. The game has several levels. Each level you finish scores
(actions a first-time human needed / actions you took) squared; a level you never finish
scores zero; every level of the game is in the divisor; and later levels count for more
(level 5 is weighted five times level 1). On top of that the whole game's score is capped at
the share of the weight you actually finished — so a five-of-seven finish scores 15/28 = 0.54
whether you did those five levels in the human's count or in a tenth of it.

Which means: **every action up to the human's count for a level is free.** Going faster than
a human buys you essentially nothing. Going slower costs you — three times the human count
leaves a ninth of that level — but reaching a level you have not reached is worth more than
any economy on the ones behind you. So: use the human's count as your allowance, spend it
without hesitation on being certain, and never trade a level you could reach for actions you
did not need to save.

Two things follow from that shape, and they matter more than the formula.

The first is that **the early levels are where you should be spending actions to learn**.
In a seven-level game the weights are 1..7 and add to 28, so level 1 can never be worth
more than 4% of your score and level 7 is worth 25%. Spending two or three times the
human's level-1 count on working out exactly what every control does therefore costs you a
percent or two, and it is what makes levels 4 to 7 cheap. Being frugal on level 1 and then
never understanding the game is the expensive mistake. You will be told, every call, what
the level you are on is worth and what the ones after it are worth.

The second is that **the last levels are where the score is, and they are far away**. A
human needs a few hundred actions for a whole game in this set, sometimes eighteen hundred.
You have 2000 actions and a wall clock, and it is the clock that runs out. So aim to finish
each level inside about twice the human's count for it, and keep moving: finishing every
level of a seven-level game at twice the human's pace scores more than finishing three of
them perfectly. Once a level has already cost you more than twice the human count, its own
score is small whatever you do, and the thing still worth having is finishing it so that the
levels after it become reachable.

WHAT ACTUALLY RUNS OUT. Every action costs one of your budget, whether or not anything
happened: walking into a wall costs one, clicking empty space costs one. But the thing
that will actually end this attempt is the wall clock, and the clock is spent on *what you
write*, not on how many actions you take. Writing a paragraph of reasoning costs many
seconds; adding one more action to a `run` costs about a hundredth of that. Measured on
this setup: an attempt that deliberates on every single action gets through about ten
actions a minute, and games in this set need hundreds.

So spend your writing where it buys something:

* `run` takes a whole sequence of actions in a few characters — `run("2*6 4*3")` is nine
  actions and costs you almost nothing. Use it for everything you have already worked out.
* When you are probing, probe in bulk. `run("1 2 3 4 5")` tells you what all five keys do
  for the price of one decision. That is the cheapest information in the game.
* When you already know what to do, just do it: emit the `run` with no commentary at all.
  Save the writing for when the screen surprises you.
* A `run` stops early by itself if a level completes, if the game state changes, or if two
  actions in a row change nothing — so a plan that turns out to be wrong costs you the
  wasted actions but not the rest of the sequence.
* Do not re-derive what you already know. If it is in your notes, trust it.

HOW TO READ THE SCREEN. You do not have to diff grids by eye — every action's result
tells you exactly which cells changed and from which colour to which. Trust that list.
If it says nothing changed, that action did nothing in that situation, and repeating it
will do nothing again.

HOW TO START. You do not know which key does what. Find out on purpose rather than by
accident: your first call should be `run` with every available action once, and then read
the change list for each. That is a handful of actions and it usually tells you the whole
control scheme. If the game accepts ACTION6 (a click), sweep clicks over the things that
look like objects, and over anything that looks like a button or a control panel edge —
several clicks in one `run`, not one per call.

WHAT A PLAN COSTS. A `run` of thirty actions is thirty actions off your score whether it
works or not, so before you send a long one, ask what it is buying. The expensive mistake —
measured, repeatedly, on the version of you that came before this one — is to build a
thirty-action plan on a belief you have not checked, watch it fail on one detail, and then
send the same thirty actions again with that detail changed. One game spent 116 actions on
two one-move edits of the same script; another clicked the same square 168 times; another
re-ran a sweep its own notes had twice recorded as useless.

So: when a plan fails, do not re-run the plan. Find the cheapest action that distinguishes
the version you believed from the version that is true — usually one or two actions — take
that first, and only then rebuild. And before any long sequence, check it against what your
notes say is already ruled out. You are told, every call, which actions and which clicks
have never once changed anything on this level; if something is on that list, it is not going
to work the next time either.

WHEN YOU ARE STUCK. Being stuck is nearly always a shortage of observations, not a
shortage of thought. If you have been on the same level for a while, stop reasoning about
the screen and go and get data: sweep an action across every position, click along a whole
row, try the action you have been assuming does nothing. Twenty cheap actions beat one
more paragraph of theory. If a level looks unwinnable from where you are, a single RESET
restarts it and keeps every level you have already finished.

WHAT TO REMEMBER. You are only shown the last few turns of this conversation. Everything
else you know has to be in your notes, which are shown to you in full on every call.
Rewrite them with the `remember` tool whenever you learn something, and keep four things in
them explicitly:

* CONTROLS — what each action does, in one line each.
* RULES — what you have *confirmed* about how this game works, and what the goal of a level
  turns out to be.
* RULED OUT — hypotheses you have tested and disproved, and exact attempts that failed. Write
  the attempt down in full: agents in your position have re-submitted a program they had
  already watched fail, forty turns later, because it was no longer in the window.
* DANGEROUS — anything irreversible: what kills you, what undoes progress you had made, what
  resets the level. Levels of one game almost
always share their mechanics, so notes written on level 1 are what make level 5 fast.
Do not describe the current screen in your notes — you can see it. Notes are for what
you cannot see.
""".strip()

TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "run",
            "description": (
                "Take a whole sequence of actions, in order, and see what each one changed. "
                "This is the cheap way to act and should be almost all of what you do.\n"
                "The sequence is a short string of items separated by spaces:\n"
                "  1 .. 7      ACTION1 .. ACTION7\n"
                "  3*8         ACTION3 eight times\n"
                "  6:12,34     ACTION6 (a click) at pixel x=12 y=34\n"
                "  b:3,4       ACTION6 at the centre of block (bx=3, by=4) at the scale shown\n"
                "  R           RESET\n"
                "Where a game offers ACTION7 it is an undo: it reverses your last action, so "
                "trying something reversible costs two actions instead of a restart.\n"
                "So \"1 2 3 4 5\" probes five keys, \"2*6 4*3\" walks six then three, and "
                "\"b:0,0 b:1,0 b:2,0\" clicks along a row. Up to 40 actions per call. The "
                "sequence stops early if a level completes, if the game state changes, or if "
                "two actions in a row change nothing."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "seq": {"type": "string",
                            "description": "The sequence, e.g. \"1 2 3 4\" or \"2*6 4*3\"."},
                },
                "required": ["seq"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "act",
            "description": (
                "Take one single action. Prefer `run` — it does the same thing for any "
                "number of actions and costs you far less of the clock."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "action": {
                        "type": "string",
                        "description": "The action to take, e.g. ACTION1, or RESET.",
                    },
                    "x": {"type": "integer", "description": "Pixel column 0-63. For ACTION6."},
                    "y": {"type": "integer", "description": "Pixel row 0-63. For ACTION6."},
                    "bx": {"type": "integer",
                           "description": "Block column at the scale shown, converted to "
                                          "the centre pixel of that block. Use instead of x."},
                    "by": {"type": "integer",
                           "description": "Block row at the scale shown, converted to the "
                                          "centre pixel of that block. Use instead of y."},
                },
                "required": ["action"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "remember",
            "description": (
                "Replace your notes. They are shown to you in full on every call and are "
                "the only thing that survives the conversation window, so keep everything "
                "you have worked out about this game in them."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "notes": {"type": "string",
                              "description": "The complete new notes, replacing the old."},
                },
                "required": ["notes"],
            },
        },
    },
]

NOTES_LIMIT = 6000
# The most actions one `run` may contain. Long enough to cross a board, short enough that
# a plan built on a wrong belief cannot spend the whole budget before being looked at.
SEQ_CAP = 40

SEQ_TOKEN = re.compile(
    r"""(?:(?:action)?6\s*[:@=(]\s*(?P<px>\d{1,2})\s*[, ]\s*(?P<py>\d{1,2})\s*\)?)   # 6:12,34
      | (?:b\s*[:@=(]\s*(?P<bx>\d{1,2})\s*[, ]\s*(?P<by>\d{1,2})\s*\)?)             # b:3,4
      | (?:(?:action)?(?<!\d)(?P<rep>[1-7])\s*[*x]\s*(?P<n>\d{1,3}))                # 3*8
      | (?:(?:action)?(?<!\d)(?P<one>[1-7])(?!\d))                                   # 3
      | (?P<reset>\br(?:eset)?\b)                                                    # R
    """,
    re.IGNORECASE | re.VERBOSE,
)
# Separators are not junk: only characters that could have been meant as an action are
# worth complaining about.
SEQ_FILLER = re.compile(r"[\s,;()\[\]|>+.-]+")


def parse_sequence(text: str, scale: int) -> tuple[list[tuple[str, Any, Any]], str]:
    """A sequence string to a list of (action, x, y). Forgiving on purpose: a syntax
    error that costs a whole call is worse than one that acts on what was understood."""
    out: list[tuple[str, Any, Any]] = []
    matched: list[tuple[int, int]] = []
    for match in SEQ_TOKEN.finditer(text or ""):
        matched.append(match.span())
        group = match.groupdict()
        if group["px"] is not None:
            out.append(("ACTION6", int(group["px"]), int(group["py"])))
        elif group["bx"] is not None:
            out.append(("ACTION6", int(group["bx"]) * scale + scale // 2,
                        int(group["by"]) * scale + scale // 2))
        elif group["rep"] is not None:
            out.extend([(f"ACTION{group['rep']}", None, None)]
                       * max(min(int(group["n"]), SEQ_CAP), 1))
        elif group["one"] is not None:
            out.append((f"ACTION{group['one']}", None, None))
        elif group["reset"] is not None:
            out.append(("RESET", None, None))
    leftover = list(text or "")
    for start, end in matched:
        for i in range(start, end):
            leftover[i] = " "
    junk = SEQ_FILLER.sub(" ", "".join(leftover)).strip()
    note = ""
    if junk:
        note = f" (ignored the unreadable part: {junk[:40]!r})"
    if len(out) > SEQ_CAP:
        note += f" (cut to the first {SEQ_CAP} actions)"
        out = out[:SEQ_CAP]
    return out, note


# --------------------------------------------------------------------------- screens

def block_scale(grid: list[list[int]]) -> int:
    """The largest kxk aligned block size the whole screen is painted in.

    Almost every game here draws a small board as big uniform blocks. Finding k lets the
    screen be shown at the scale it was drawn at, which is lossless and about k*k times
    smaller. Falls back to 1, which is the raw grid.
    """
    height = len(grid)
    width = len(grid[0]) if height else 0
    for k in (16, 8, 4, 2):
        if height % k or width % k:
            continue
        ok = True
        for by in range(0, height, k):
            for bx in range(0, width, k):
                first = grid[by][bx]
                for y in range(by, by + k):
                    row = grid[y]
                    for x in range(bx, bx + k):
                        if row[x] != first:
                            ok = False
                            break
                    if not ok:
                        break
                if not ok:
                    break
            if not ok:
                break
        if ok:
            return k
    return 1


def shrink(grid: list[list[int]], k: int) -> list[list[int]]:
    if k == 1:
        return grid
    return [[grid[y][x] for x in range(0, len(grid[0]), k)]
            for y in range(0, len(grid), k)]


def render(grid: list[list[int]]) -> str:
    """The screen as text, with row and column numbers so coordinates can be read off."""
    width = len(grid[0]) if grid else 0
    tens = "    " + "".join(str((x // 10) % 10) if x % 10 == 0 else " " for x in range(width))
    ones = "    " + "".join(DIGITS[x % 10] for x in range(width))
    rows = [f"{y:3d} " + "".join(DIGITS[v & 0xF] for v in row) for y, row in enumerate(grid)]
    return "\n".join([tens, ones, *rows])


def picture(grid: list[list[int]]) -> str:
    """The screen at the scale it is drawn at, with a line saying which scale that is."""
    k = block_scale(grid)
    small = shrink(grid, k)
    counts: dict[int, int] = {}
    for row in small:
        for value in row:
            counts[value] = counts.get(value, 0) + 1
    tally = ", ".join(f"{DIGITS[c]}:{n}" for c, n in
                      sorted(counts.items(), key=lambda kv: -kv[1])[:8])
    if k > 1:
        head = (f"screen, drawn in {k}x{k} blocks, so shown as {len(small[0])}x{len(small)} "
                f"blocks; block (bx,by) covers pixels x = bx*{k} to bx*{k}+{k - 1} and "
                f"y = by*{k} to by*{k}+{k - 1}")
    else:
        head = f"screen, {len(grid[0])}x{len(grid)} pixels"
    return f"{head}\ncolours: {tally}\n{seams(small)}\n{render(small)}"


def seams(grid: list[list[int]]) -> str:
    """Where the screen's own cell boundaries are.

    Adjacent columns that are identical all the way down are one column of whatever the
    game is drawing; the same for rows. Saying where those groups begin hands over the
    board's grid without changing the coordinates anything is addressed by, and it is the
    thing that decides where a click has to land.
    """
    columns = list(zip(*grid))
    xs = [0] + [x for x in range(1, len(columns)) if columns[x] != columns[x - 1]]
    ys = [0] + [y for y in range(1, len(grid)) if grid[y] != grid[y - 1]]
    def spans(cuts: list[int], size: int) -> str:
        widths = [b - a for a, b in zip(cuts, cuts[1:] + [size])]
        if len(set(widths)) == 1:
            return f"{len(cuts)} of width {widths[0]}, starting at " + ",".join(map(str, cuts))
        return f"{len(cuts)}, starting at " + ",".join(map(str, cuts))
    if len(xs) > 40 and len(ys) > 40:
        return "no repeated column or row structure — this screen is drawn per pixel"
    return (f"column groups: {spans(xs, len(columns))}\n"
            f"row groups: {spans(ys, len(grid))}")


def changed_cells(before: list[list[int]], after: list[list[int]],
                  k: int) -> list[tuple[int, int, int, int]]:
    small_a, small_b = shrink(before, k), shrink(after, k)
    out = []
    for y, (ra, rb) in enumerate(zip(small_a, small_b)):
        for x, (va, vb) in enumerate(zip(ra, rb)):
            if va != vb:
                out.append((x, y, va, vb))
    return out


def group_changes(cells: list[tuple[int, int, int, int]]) -> list[dict[str, Any]]:
    """Cluster changed cells into rectangles so the report is about objects, not pixels."""
    index = {(x, y): (a, b) for x, y, a, b in cells}
    seen: set[tuple[int, int]] = set()
    groups = []
    for start in index:
        if start in seen:
            continue
        stack = [start]
        seen.add(start)
        members = []
        while stack:
            x, y = stack.pop()
            members.append((x, y))
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1):
                    nxt = (x + dx, y + dy)
                    if nxt in index and nxt not in seen:
                        seen.add(nxt)
                        stack.append(nxt)
        transitions: dict[tuple[int, int], int] = {}
        for member in members:
            transitions[index[member]] = transitions.get(index[member], 0) + 1
        groups.append({
            "x0": min(m[0] for m in members), "x1": max(m[0] for m in members),
            "y0": min(m[1] for m in members), "y1": max(m[1] for m in members),
            "n": len(members),
            "transitions": sorted(transitions.items(), key=lambda kv: -kv[1]),
        })
    groups.sort(key=lambda g: -g["n"])
    return groups


def animation(before: list[list[int]], frames: list[list[list[int]]]) -> str:
    """One action can come back with several screens, and they are the game showing you
    something happen — a piece running the program you just submitted, a chain reaction,
    a countdown. Only the last of them survives into the next turn, so what happened in
    between has to be said here or it is lost. Measured cost of losing it: one attempt
    concluded "the board resets after each failed run, so end-positions aren't observable"
    and then submitted fourteen programs, when every run had been shown to it frame by frame.
    """
    lines = [f"{len(frames)} screens came back — the game animated this. Frame by frame:"]
    previous = before
    for index, frame in enumerate(frames[:ANIMATION_FRAMES]):
        k = min(block_scale(frame), block_scale(previous))
        report = change_report(previous, frame, k)
        lines.append(f"  screen {index + 1}: {report[:ANIMATION_CHARS]}")
        previous = frame
    if len(frames) > ANIMATION_FRAMES:
        lines.append(f"  ... and {len(frames) - ANIMATION_FRAMES} more screens; the last one "
                     f"is the one shown below")
    return "\n".join(lines)


def change_report(before: list[list[int]] | None, after: list[list[int]], k: int) -> str:
    if before is None:
        return ""
    if len(before) != len(after) or len(before[0]) != len(after[0]):
        return "the screen changed size"
    cells = changed_cells(before, after, k)
    if not cells:
        return "NOTHING CHANGED"
    groups = group_changes(cells)
    parts = []
    for group in groups[:8]:
        where = (f"({group['x0']},{group['y0']})" if group["n"] == 1 else
                 f"x{group['x0']}-{group['x1']} y{group['y0']}-{group['y1']}")
        moves = " ".join(f"{DIGITS[a]}->{DIGITS[b]}x{n}" for (a, b), n in
                         group["transitions"][:3])
        parts.append(f"{where} {moves}")
    if len(groups) > 8:
        parts.append(f"and {len(groups) - 8} more regions")
    return f"{len(cells)} cells changed in {len(groups)} region(s): " + "; ".join(parts)


# --------------------------------------------------------------------------- messages

def stall_advice(stuck: int) -> str:
    """What to say to an agent that has stopped making progress, escalating with how long."""
    if stuck < 2 * STALL_CALLS:
        return ("Stop refining what you believe and go and get data: take 15-30 cheap actions "
                "in one run that you have not taken before — a whole row of clicks, an action "
                "you wrote off as useless, one key swept across the board — and read the "
                "change list.")
    if stuck < 3 * STALL_CALLS:
        return ("Your idea of what this level *wants* is probably the thing that is wrong, not "
                "your execution of it. Below is everything that has changed on this level "
                "since it started; look at it and ask what a level that ends would look like. "
                "Then write the new reading into your notes and act on it.")
    if stuck < 4 * STALL_CALLS:
        return ("Nothing you have tried from this position works. Send a single RESET: it "
                "restarts this level and keeps every level you have finished, and doing the "
                "level deliberately from a clean board is cheaper than untangling this one. "
                "The actions you have already spent here are lost either way.")
    return ("You are far past the point where this approach was going to work. Take the "
            "actions you have decided are useless and take them anyway, in bulk, in places "
            "you have not tried them; take the action that is not in your notes at all. An "
            "unfinished level scores zero, so there is nothing left to protect here.")


def elide(message: dict[str, Any]) -> dict[str, Any]:
    """An older tool result cut down to what is still worth carrying.

    The picture goes, and so do the per-action change lines: a sequence of forty actions
    is forty lines, and twelve turns of those was measured at 21k input tokens a call. What
    is kept is the first line and anything the run marked as important, which is where the
    level boundaries and the state changes are.
    """
    content = str(message.get("content", "")).split("\nscreen, ")[0]
    lines = content.splitlines()
    kept = [lines[0]] if lines else []
    kept += [l for l in lines[1:] if "***" in l or "CHANGED to" in l]
    dropped = len(lines) - len(kept)
    if dropped > 0:
        kept.append(f"({dropped} action lines and the screen dropped from the history)")
    return {**message, "content": "\n".join(kept)}


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
        self.opening = self.opening_message()
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

        self.notes = ""
        self.started = time.time()
        self.batch_sizes: list[int] = []
        self.no_change_actions = 0
        self.refused_resets = 0
        self.ask_failures = 0
        # The harness resets the game to hand over its first screen, so as far as the
        # engine is concerned the last thing that happened was a RESET. A RESET now would
        # be the second in a row, which is a full restart back to level 1.
        self.last_applied = "RESET"
        self.level_started_at = 0
        self.stalled_since = 0
        self.available = list(self.session.observation.available_actions)
        self.notes_at = 0
        self.slow_calls = 0
        self.last_out = 0
        # A sequence sent twice is the cheapest sign of a stuck agent there is. Measured on
        # the version before this one: one attempt re-submitted a program it had already
        # watched fail, forty turns later, because it had fallen out of the window.
        self.past_sequences: list[tuple[int, list[str]]] = []
        # Per level: for each action (a click counts as its coordinate), how many times it
        # has been taken here and how many of those changed nothing. Measured on the version
        # before this one: dc22 clicked (56,8) 168 times and 535 of its 790 clicks were
        # coordinates it had already tried; wa30 re-ran sweeps its own notes had refuted
        # twice. None of that is visible to an agent that only sees the last few turns.
        self.tally: dict[str, list[int]] = {}
        self.level_start_grid: list[list[int]] | None = self.session.observation.frame[-1]
        self.repeated_sequences = 0
        self.level_marks: list[int] = []
        self.levels_seen = self.session.observation.levels_completed

    # -- what the model is shown ------------------------------------------------
    def opening_message(self) -> dict[str, Any]:
        session = self.session
        obs = session.observation
        baselines = ", ".join(f"L{i + 1}:{b}" for i, b in enumerate(session.baseline_actions))
        return {
            "role": "user",
            "content": (
                f"You are playing {session.title}. It has {session.total_levels} levels. A "
                f"human seeing it for the first time finished them in {baselines} actions "
                f"({sum(session.baseline_actions)} for the whole game), which is the "
                f"standard you are scored against.\n\n"
                f"You have {session.max_actions} actions and a wall clock, and the clock "
                f"usually binds first.\n\n"
                f"This game accepts: {', '.join(obs.available_actions) or 'nothing'}.\n\n"
                f"Here is the opening screen.\n\n" + picture(obs.frame[-1])
            ),
        }

    def projection(self) -> tuple[float, float]:
        """The score as it stands, and the score if every remaining level goes at the human's
        pace. The formula is the published one, including the cap that stops a game scoring
        more than the share of levels it finished — which is why being faster than the human
        buys nothing and reaching one more level buys a lot. Showing both numbers turns that
        into something the model can act on instead of a paragraph it has to believe.
        """
        baselines = self.session.baseline_actions
        levels = len(baselines)
        weights = sum(range(1, levels + 1)) or 1
        total = 0.0
        reachable = 0
        previous = 0
        for index, mark in enumerate(self.level_marks[:levels]):
            base = baselines[index]
            took = max(mark - previous, 1)
            total += (index + 1) * min((base / took) ** 2, 1.15)
            reachable += index + 1
            previous = mark
        now = min(total, float(reachable)) / weights
        rest = sum(range(len(self.level_marks) + 1, levels + 1))
        best = min(total + rest, float(weights)) / weights
        return now, best

    def status(self) -> dict[str, Any]:
        session, obs = self.session, self.session.observation
        level = obs.levels_completed + 1
        baselines = session.baseline_actions
        here = baselines[level - 1] if level - 1 < len(baselines) else baselines[-1]
        spent_here = session.actions_used - self.level_started_at
        elapsed = max(time.time() - self.started, 1.0)
        pace = self.actions_taken / elapsed * 60.0
        left = getattr(session, "seconds_remaining", 0.0)
        room = int(pace * left / 60.0)
        lines = [
            "=== where you are ===",
            f"on level {level} of {obs.win_levels} ({obs.levels_completed} finished)"
            f" — state {obs.state}",
            f"a human needed {here} actions for this level; you have spent {spent_here}",
            f"actions: {session.actions_used} used, "
            f"{getattr(session, 'actions_remaining', 0)} left",
            (f"clock: {int(left)}s left; at your pace of {pace:.1f} actions/min that is "
             f"room for roughly {room} more actions" if self.actions_taken
             else f"clock: {int(left)}s left"),
            f"this game currently accepts: {', '.join(obs.available_actions) or 'nothing'}",
        ]
        weights = sum(range(1, obs.win_levels + 1)) or 1
        worth = level / weights * 100
        after = sum(range(level + 1, obs.win_levels + 1)) / weights * 100
        lines.append(f"this level is worth at most {worth:.0f}% of your total score; the "
                     f"levels after it are worth {after:.0f}% together")
        now, best = self.projection()
        lines.append(f"your score if the attempt ended here: {now:.3f}. If you finish every "
                     f"remaining level in about the human's count for it: {best:.3f}. That "
                     f"gap is what is still on the table.")
        if spent_here < here:
            lines.append(f"You have {here - spent_here} free actions left on this level — up "
                         f"to the human's {here} costs you nothing at all. Spend them on being "
                         f"certain, not on hurrying.")
        if level <= 2 and after > 50:
            lines.append("So this early level is the cheap place to learn the game. Spend "
                         "actions here until you understand every control and what the goal "
                         "is — that is what makes the levels that carry the score reachable.")
        elif spent_here <= here:
            lines.append("You are still inside the human's count for this level. Actions are "
                         "squared against you, so keep it tight and do not wander.")
        elif spent_here <= 2 * here:
            lines.append("You are over the human's count for this level but not by much — "
                         "finishing it now still keeps most of what it is worth.")
        else:
            lines.append("This level has already cost you more than twice the human's count, "
                         "so its own score is small whatever you do now. What is still worth "
                         "a lot is FINISHING it and reaching the next one, which is weighted "
                         "higher. Spend actions freely to get unstuck. If the board is in a "
                         "state you no longer understand, one RESET restarts this level and "
                         "keeps every level you have finished — the actions already spent here "
                         "are lost either way, and doing the level deliberately from a clean "
                         "start is often cheaper than untangling it.")
        if left < 1200:
            lines.append("THE CLOCK IS NEARLY GONE. Take many actions per call now: an "
                         "unfinished level scores nothing, so finish what you can.")
        elif room < sum(baselines[obs.levels_completed:]):
            lines.append("At this pace the clock will end the attempt before the last "
                         "level. Put more actions in each call.")
        if obs.state == "GAME_OVER":
            lines.append("You are in GAME_OVER. Send exactly ONE RESET to carry on. Never "
                         "two RESETs in a row: the second throws away every level you have "
                         "finished and starts again at level 1.")
        stuck = self.calls - self.stalled_since
        if stuck >= STALL_CALLS:
            lines.append(f"You have made no progress for {stuck} calls. " + stall_advice(stuck))
            if self.level_start_grid is not None:
                lines.append("everything that has changed on this level since it began: "
                             + change_report(self.level_start_grid,
                                             obs.frame[-1], 1)[:600])
        if self.notes and self.calls - self.notes_at >= 12:
            lines.append(f"Your notes have not changed for {self.calls - self.notes_at} calls. "
                         f"Anything you have worked out since is about to be forgotten — "
                         f"rewrite them.")
        if not self.notes and self.calls >= 3:
            lines.append("Your notes are still empty. Call remember now with what you have "
                         "worked out — in a few more turns the transcript that holds it will "
                         "be gone and you will be working it out again from scratch.")
        dead = sorted(((n, k) for k, (n, z) in self.tally.items() if n == z and n >= 2),
                      reverse=True)[:12]
        if dead:
            lines.append("on THIS level these have never once changed the screen — stop "
                         "spending actions on them: "
                         + ", ".join(f"{k} x{n}" for n, k in dead))
        live = sorted(((n, z, k) for k, (n, z) in self.tally.items() if n > z),
                      reverse=True)[:10]
        if live:
            lines.append("what has done something on this level (taken/of those did nothing): "
                         + ", ".join(f"{k} {n}/{z}" for n, z, k in live))
        if self.level_marks:
            done = []
            previous = 0
            for index, mark in enumerate(self.level_marks):
                base = baselines[index] if index < len(baselines) else baselines[-1]
                done.append(f"L{index + 1} {mark - previous}/{base}")
                previous = mark
            lines.append("levels you have finished, your actions/human's: " + "  ".join(done))
        lines.append("=== your notes (rewrite them with remember) ===")
        lines.append(self.notes or "(empty — write down what you learn)")
        return {"role": "user", "content": "\n".join(lines)}

    def window(self) -> list[dict[str, Any]]:
        kept = self.turns[-DEFAULT_TURNS_KEPT:]
        messages = [self.system, self.opening]
        for index, turn in enumerate(kept):
            recent = index >= len(kept) - DEFAULT_SCREENS_KEPT
            for message in turn:
                messages.append(
                    message if recent or message.get("role") != "tool" else elide(message))
        status = self.status()
        if self.last_out >= SLOW_REPLY_TOKENS:
            status = {**status, "content": status["content"] + "\n\n"
                      + LONG_REPLY.format(n=self.last_out)}
        if self.slow_calls >= 2:
            status = {**status, "content": status["content"] + "\n\n"
                      + TOO_SLOW.format(n=self.slow_calls)}
        messages.append(status)
        return messages

    def keep(self, turn: list[dict[str, Any]]) -> None:
        self.turns.append(turn)
        self.everything.extend(turn)

    # -- the model call ---------------------------------------------------------
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
        self.last_out = getattr(usage, "completion_tokens", 0) or 0
        self.out_tokens += self.last_out
        self.finish_reasons.append(choice.finish_reason)
        try:
            self.cost += litellm.completion_cost(completion_response=response) or 0.0
        except Exception:  # noqa: BLE001
            pass
        return choice.message

    def ask_with_retries(self) -> Any:
        """A provider error mid-attempt is a thing that happens, not the end of the game.

        Measured on this setup: one transient error used to end an attempt where it stood,
        which reads from the outside exactly like an agent that gave up. So this gives up
        only when the attempt itself is over — while there is clock left, asking again is
        strictly better than returning.
        """
        attempt = 0
        while True:
            try:
                message = self.ask()
                self.slow_calls = 0
                return message
            except Exception as failure:  # noqa: BLE001
                attempt += 1
                self.ask_failures += 1
                print(f"[ask] {type(failure).__name__}: {failure}"[:400])
                if getattr(self.session, "seconds_remaining", 1.0) <= 0:
                    raise
                # A prompt the provider chokes on, or one that sends the model into a reply
                # so long it hits the timeout, is the failure that retrying alone does not
                # fix. So every retry drops the oldest turn: the request is not the same one.
                if len(self.turns) > 1:
                    self.turns = self.turns[1:]
                self.slow_calls = attempt
                time.sleep(min(DEFAULT_ASK_BACKOFF_SEC, max(2, attempt)))

    # -- acting -----------------------------------------------------------------
    def wanted(self, call: Any, scale: int) -> tuple[list[tuple[str, Any, Any]], str]:
        """What one tool call is asking for, as a list of (action, x, y)."""
        name = getattr(getattr(call, "function", None), "name", "")
        try:
            arguments = json.loads(call.function.arguments or "{}")
        except ValueError:
            return [], " (those arguments did not parse as JSON)"
        if name == "run":
            return parse_sequence(str(arguments.get("seq", "")), scale)
        action = str(arguments.get("action", "")).upper().replace(" ", "").replace("_", "")
        x, y = arguments.get("x"), arguments.get("y")
        if x is None and arguments.get("bx") is not None:
            x = int(arguments["bx"]) * scale + scale // 2
        if y is None and arguments.get("by") is not None:
            y = int(arguments["by"]) * scale + scale // 2
        return [(action, x, y)], ""

    def echo(self, actions: list[tuple[str, Any, Any]]) -> str:
        """Say so when this sequence is one the agent has already run, or nearly is.

        Measured on the version before this one, on three games it *won* but paid double for:
        the waste was almost entirely long sequences re-run with a small edit. g50t call 69
        was call 66 verbatim; call 70 was call 67 without its two-action pad, so 44 actions
        went on deleting a pad. sc25 spent 116 actions on two one-move edits of the same
        40-action script. tn36 pressed its GO button 20 times in one level whose human budget
        was 62 actions. None of that was confusion — the notes were right throughout — it was
        paying an experiment's whole setup cost again to test one bit.
        """
        key = [f"{a}{x},{y}" for a, x, y in actions]
        best_ratio, best = 0.0, None
        for when, previous in self.past_sequences[-PAST_SEQUENCES:]:
            ratio = difflib.SequenceMatcher(None, key, previous).ratio()
            if ratio > best_ratio:
                best_ratio, best = ratio, (when, previous)
        self.past_sequences.append((self.calls, key))
        if best is None or best_ratio < NEAR_REPEAT:
            return ""
        when, previous = best
        self.repeated_sequences += 1
        same = "exactly the sequence" if best_ratio > 0.999 else (
            f"{best_ratio * 100:.0f}% the same as the sequence")
        return (f" — WARNING: this is {same} you ran at call {when} ({len(previous)} actions). "
                f"You are about to pay {len(actions)} actions again to test whatever you have "
                f"changed. Is there a two- or three-action test that would settle that one "
                f"difference first? If the answer is yes, do that instead.")

    def apply_one(self, action: str, x: Any, y: Any) -> tuple[str, str]:
        """Apply one action to the game. Returns (one-line report, flag)."""
        if action == "RESET" and self.last_applied == "RESET":
            self.refused_resets += 1
            return ("RESET refused and nothing spent: the last thing that happened was "
                    "already a RESET, and a second one in a row is a full restart that "
                    "throws away every level finished so far", "refused")

        before = self.session.observation.frame[-1]
        obs = self.session.step(action, x=x, y=y)
        self.actions_taken += 1
        self.last_applied = action
        where = "" if x is None else f"({x},{y})"

        grid = obs.frame[-1]
        flag = ""
        parts = [f"{action}{where}"]
        if not obs.frame_returned:
            parts.append("no screen came back and the action was not counted (that is "
                         "what happens while in GAME_OVER)")
            flag = "no_frame"
        if len(obs.frame) > 1:
            parts.append(animation(before, obs.frame))
        if list(obs.available_actions) != self.available:
            parts.append(f"the actions this game accepts have CHANGED to "
                         f"{', '.join(obs.available_actions) or 'nothing'}")
            self.available = list(obs.available_actions)
        report = change_report(before, grid, min(block_scale(grid), block_scale(before)))
        if report == "NOTHING CHANGED":
            self.no_change_actions += 1
            flag = flag or "no_change"
        name = action if x is None else f"{action}({x},{y})"
        seen = self.tally.setdefault(name, [0, 0])
        seen[0] += 1
        seen[1] += 1 if report == "NOTHING CHANGED" else 0
        if seen[0] > 1 and seen[1] == seen[0]:
            report += (f" (and that is {seen[0]} times on this level that this has done "
                       f"nothing at all)")
        parts.append(report)
        if obs.levels_completed > self.levels_seen:
            took = self.session.actions_used - self.level_started_at
            base = self.session.baseline_actions
            want = base[self.levels_seen] if self.levels_seen < len(base) else base[-1]
            parts.append(f"*** LEVEL {obs.levels_completed} COMPLETE in {took} actions "
                         f"(a human took {want}) *** write down how, the next level "
                         f"probably works the same way")
            self.level_marks.append(self.session.actions_used)
            self.levels_seen = obs.levels_completed
            self.level_started_at = self.session.actions_used
            self.stalled_since = self.calls
            self.tally = {}
            self.level_start_grid = grid
            # Both ledgers are about *this* level. Re-walking the same route on the next
            # level is usually exactly right — several of these games repeat their mechanics
            # level after level — so a repeat only means something within one level.
            self.past_sequences = []
            flag = "level_up"
        if obs.state != "NOT_FINISHED":
            parts.append(f"*** state is now {obs.state} ***")
            flag = "state_" + obs.state
        return " | ".join(parts), flag

    def act_on(self, call: Any, scale: int, budget: int) -> tuple[str, str | None, int]:
        """Apply everything one tool call asks for. Returns (report, stop reason, taken)."""
        actions, note = self.wanted(call, scale)
        if len(actions) >= 4 and len(set(actions)) >= 2:
            note += self.echo(actions)
        if not actions:
            return (f"nothing was taken: no action could be read out of that call{note}. "
                    f"Use run with a sequence like \"1 2 3\" or \"2*6\".", None, 0)
        lines = []
        stop: str | None = None
        consecutive_no_change = 0
        taken = 0
        for index, (action, x, y) in enumerate(actions):
            if taken >= budget:
                stop = f"the call's action allowance ran out after {taken}"
                break
            try:
                line, flag = self.apply_one(action, x, y)
            except ValueError as bad:
                self.rejected += 1
                available = self.session.observation.available_actions
                lines.append(f"{index + 1}) {bad} — nothing spent; this game accepts "
                             f"{', '.join(available) or 'nothing'}")
                continue
            taken += 1
            lines.append(f"{index + 1}) {line}")
            if flag == "no_change":
                consecutive_no_change += 1
                if consecutive_no_change >= 2:
                    stop = "two actions in a row changed nothing"
            else:
                consecutive_no_change = 0
            if flag == "level_up":
                stop = "a level was completed, so the screen is new"
            elif flag.startswith("state_"):
                stop = f"the game state became {flag[6:]}"
            elif flag == "no_frame":
                stop = "the game is not accepting actions until you RESET"
            if stop:
                break
        head = f"{taken} action(s) taken{note}"
        if stop and taken < len(actions):
            head += f"; stopped after {taken} of {len(actions)} because {stop}"
        return head + "\n" + "\n".join(lines), stop, taken

    def play(self) -> None:
        while True:
            message = self.ask_with_retries()
            turn: list[dict[str, Any]] = [message.model_dump(exclude_none=True)]
            tool_calls = list(getattr(message, "tool_calls", None) or [])
            scale = block_scale(self.session.observation.frame[-1])

            acts = [c for c in tool_calls
                    if getattr(getattr(c, "function", None), "name", "") in ("act", "run")]
            if not acts:
                self.idle_turns += 1
                for call in tool_calls:
                    turn.append({"role": "tool", "tool_call_id": call.id,
                                 "content": self.remember(call)})
                if self.idle_turns >= DEFAULT_MAX_IDLE_TURNS:
                    self.stop_reason = "stopped_choosing_actions"
                    self.keep(turn)
                    return
                turn.append({"role": "user",
                             "content": "Now act: call run with a sequence of actions. The "
                                        "clock is running and thinking is what spends it."})
                self.keep(turn)
                continue
            self.idle_turns = 0

            closed: str | None = None
            stop: str | None = None
            taken = 0
            for call in tool_calls:
                name = getattr(getattr(call, "function", None), "name", "")
                if name == "remember":
                    turn.append({"role": "tool", "tool_call_id": call.id,
                                 "content": self.remember(call)})
                    continue
                if closed is not None:
                    content = f"The attempt is over: {closed}."
                elif stop is not None:
                    content = (f"not taken — the rest of this turn was dropped because "
                               f"{stop}. Look at the screen and decide again.")
                else:
                    try:
                        content, stop, count = self.act_on(
                            call, scale, DEFAULT_BATCH_CAP - taken)
                        taken += count
                    except SessionClosed as over:
                        closed = over.reason
                        content = f"The attempt is over: {closed}."
                    except Exception as broken:  # noqa: BLE001
                        content = f"that call raised {type(broken).__name__}: {broken}"
                turn.append({"role": "tool", "tool_call_id": call.id, "content": content})

            self.batch_sizes.append(taken)
            if closed is None:
                # The screen goes on the last tool result of the turn, not in a message of
                # its own, because only tool results are elided out of the history later.
                last = max(i for i, m in enumerate(turn) if m.get("role") == "tool")
                turn[last] = {**turn[last],
                              "content": str(turn[last]["content"]) + "\n"
                              + picture(self.session.observation.frame[-1])}
            self.keep(turn)
            self.log_live(taken)
            if closed is not None:
                self.stop_reason = closed
                return

    def log_live(self, taken: int) -> None:
        """A line per call, on disk as it happens, so a running attempt can be read.

        The transcript is only written when the attempt ends, and the attempts worth
        reading are exactly the ones that have not ended yet.
        """
        try:
            with open("arc3-agent-live.jsonl", "a", encoding="utf-8") as handle:
                handle.write(json.dumps({
                    "call": self.calls, "t": round(time.time() - self.started, 1),
                    "actions": self.session.actions_used, "took": taken,
                    "levels": self.session.observation.levels_completed,
                    "state": self.session.observation.state,
                    "in": self.in_tokens, "out": self.out_tokens,
                    "notes": len(self.notes),
                }) + "\n")
        except Exception:  # noqa: BLE001
            pass

    def remember(self, call: Any) -> str:
        try:
            arguments = json.loads(call.function.arguments or "{}")
        except ValueError:
            return "those notes did not parse as JSON; nothing was saved"
        name = getattr(getattr(call, "function", None), "name", "")
        if name != "remember":
            return f"there is no tool called {name!r}; the tools are act and remember"
        self.notes = str(arguments.get("notes", ""))[:NOTES_LIMIT]
        self.notes_at = self.calls
        return f"notes saved ({len(self.notes)} characters)"

    def summary(self) -> dict[str, Any]:
        batches = [b for b in self.batch_sizes if b]
        return {
            "stop_reason": self.stop_reason,
            "model_calls": self.calls,
            "actions_taken": self.actions_taken,
            "actions_per_call": round(self.actions_taken / self.calls, 3) if self.calls else 0,
            "mean_batch": round(sum(batches) / len(batches), 2) if batches else 0,
            "max_batch": max(batches) if batches else 0,
            "rejected_actions": self.rejected,
            "no_change_actions": self.no_change_actions,
            "refused_resets": self.refused_resets,
            "repeated_sequences": self.repeated_sequences,
            "ask_failures": self.ask_failures,
            "out_tokens_per_call": round(self.out_tokens / self.calls, 1) if self.calls else 0,
            "level_marks": self.level_marks,
            "notes_final": self.notes,
            "levels_completed": self.session.observation.levels_completed,
            "final_state": self.session.observation.state,
            "n_input_tokens": self.in_tokens,
            "n_output_tokens": self.out_tokens,
            "cost_usd": self.cost,
            "max_tokens": DEFAULT_MAX_TOKENS,
            "reasoning_effort": DEFAULT_REASONING_EFFORT,
            "turns_kept": DEFAULT_TURNS_KEPT,
            "variant": os.environ.get("ARC3_VARIANT", ""),
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
