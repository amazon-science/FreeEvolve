#!/usr/bin/env python3
"""The puzzle-solving agent, as it runs inside the task container.

Reads the task's instruction, works in the container, and leaves an answer at the
path the verifier reads. The loop is: ask the model, run whatever command it asks
for, hand back the output, repeat until it stops asking or the step cap is reached.

The verifier compares /testbed/output.json with the expected grid, exactly. It reads
nothing else and nothing here writes that file — the agent does, with the tool it
has.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import traceback
from pathlib import Path
from typing import Any

import litellm

litellm.drop_params = True

# The model capability this agent runs at. FIXED, not a knob: raising, lowering or
# removing any of these changes how much inference the agent buys per attempt rather
# than how well the agent is built. See ENVIRONMENT.md.
DEFAULT_MAX_TOKENS = 16384
DEFAULT_REASONING_EFFORT = "medium"
# Extended thinking requires temperature 1.0, so the agent is sampled rather than
# greedy and repeated attempts at the same puzzle differ.
DEFAULT_TEMPERATURE = 1.0
DEFAULT_MAX_RETRIES = 4

# How many model calls one attempt may make. A bound, not a schedule: it exists so a
# loop that stops asking for anything cannot run until the wall clock kills it.
DEFAULT_MAX_STEPS = 60
# What one command may spend before it is cut off and its output returned as-is.
DEFAULT_COMMAND_TIMEOUT_SEC = 120
# How much of a command's output comes back. Output beyond this is dropped from the
# middle, keeping both ends, because a grid printed by accident can be enormous.
DEFAULT_OUTPUT_LIMIT_CHARS = 20000
# After the first output.json write, force at least this many more tool calls before
# letting the model stop. Dominant baseline failure: model iterates, solver passes
# training, applies to test, writes output, stops immediately — but the test output
# is wrong because the rule over-fits 2-3 training pairs. Forcing a post-write
# verification phase makes the model actually re-check its work.
POST_WRITE_REQUIRED_STEPS = 3

OUTPUT_PATH = "/testbed/output.json"

# Injected once, right after the first output.json write, to redirect the model into
# active critical review rather than sign-off. Written as a user turn so it lands
# naturally in the conversation flow.
POST_WRITE_REVIEW_MESSAGE = """
You just wrote /testbed/output.json. Before you stop, do a critical review — the
most common failure mode on ARC-AGI-2 is a solver that fits every training pair yet
gets the test wrong because the rule is over-specialized. Use the next few tool
calls to catch that:

1. **Re-verify EVERY training pair, exactly.** Print `got` vs `expected` cell by
   cell (use `equal(got, expected)` and `diff_grids(got, expected)`). If ANY pair
   differs anywhere, the rule is wrong — go back and fix.

2. **Alternative-rule check.** State at least one OTHER rule that also fits all
   training pairs. Which is simpler? Do the two rules agree on the test input? If
   they disagree, the simpler one is usually right.

3. **Novel-feature check.** What structural features does the test input have that
   the training pairs do NOT (new palette values, more/fewer objects, larger grid,
   different symmetry, etc.)? For each novelty, does your rule handle it naturally
   or is it silently making an assumption?

4. **Test-output sanity check.** Load /testbed/output.json and visually inspect it
   with `show()`. Does its shape, palette, object count, and overall structure
   look consistent with what the training outputs looked like relative to their
   inputs? Print `count_by_color` for output and for the test input.

If the review turns up anything suspicious, fix your solver, re-run on training to
confirm, then overwrite /testbed/output.json. Overwriting is cheap — never stop
with a suspect answer.
""".strip()

SYSTEM_PROMPT = """
You are solving an ARC-AGI-2 puzzle inside a Linux container. Each puzzle shows a
handful of input/output grid pairs that demonstrate one unstated transformation.
Your job: infer the transformation from the training pairs, apply it to the test
input, and write the resulting grid to /testbed/output.json as a JSON 2D array of
integers 0-9. The verifier compares cells exactly — wrong shape or one wrong cell
scores zero.

## Your tool

You have exactly one tool, `run`, which executes a bash command in /testbed and
returns its combined stdout/stderr (truncated in the middle if very long). You
progress by making tool calls. You will make MANY calls, not one.

Do NOT try to reason through the whole puzzle in a single reply. You have a
16 384-token budget per model call, shared between hidden reasoning and the reply
itself; a reply that runs out of budget produces nothing at all and wastes the
call. Instead, make each call small and focused, and let commands do the heavy
lifting.

## The puzzle data — pre-parsed for you

- /testbed/pairs.json      — JSON list of {"input": grid, "output": grid} pairs
- /testbed/test_input.json — the JSON 2D array to transform
- /testbed/instruction.md  — the raw puzzle text, if you want the original wording
- /testbed/arc_lib.py      — small helper library (see below)

Your answer goes to /testbed/output.json as a JSON 2D array of ints. Write it as
soon as you have a candidate — overwriting is cheap, and never writing scores zero
automatically.

## The container

Python 3.11 with STANDARD LIBRARY ONLY — no numpy, no scipy. Use plain
`list[list[int]]`. Files you create in /testbed persist between commands. You
have shell (bash) and outbound network (rarely useful here).

## Helper library — /testbed/arc_lib.py

Import as `from arc_lib import *`. Provides:

- `show(grid)` — pretty-print a grid (rows aligned, colors as digits)
- `shape(grid)` — (rows, cols)
- `palette(grid)` — sorted list of distinct values
- `find_color(grid, c)` — list of (r,c) cells with that color
- `components(grid, bg=0, connectivity=4)` — connected components as list of dicts
   {"color": c, "cells": [(r,c), ...], "bbox": (r0,c0,r1,c1), "size": n}
- `transpose(grid), rotate90(grid), flip_h(grid), flip_v(grid)` — geometry
- `pad(grid, rows, cols, value=0)` — pad to (rows, cols)
- `crop(grid, r0, c0, r1, c1)` — crop inclusive bbox
- `tile(grid, kr, kc)` — repeat grid kr×kc times
- `equal(a, b)` — cell-for-cell equality (safe with ragged rows)
- `count_by_color(grid)` — dict {color: count}
- `bbox_of_cells(cells)` / `bbox_of_color(grid, c)` — bounding box (r0, c0, r1, c1)
- `blank(rows, cols, value=0)` — an rows×cols grid filled with value
- `replace(grid, old, new)` — swap one color for another
- `diff_grids(a, b)` — list of (r, c, a_val, b_val) where cells differ
- `show_diff(a, b)` — print a mask grid highlighting differing cells

None of this is required — write your own code if it fits the puzzle better.

## The working recipe

1. **Look.** In your very first tool call, load the pairs and print shapes,
   palettes, and each RAW grid with `show()`. Skim them — patterns are visible
   in the picture, not in the abstract summary.

2. **Hypothesise.** State the transformation in a sentence. Ask: does output
   shape depend on input? Which colors are involved? Is any object being
   moved / recolored / mirrored / duplicated / cropped / tiled?

3. **Implement.** Write /testbed/solver.py with a function
   `solve(grid: list[list[int]]) -> list[list[int]]`.

4. **Verify on EVERY training pair.** Do this as one command:
   ```python
   from solver import solve
   from arc_lib import equal
   import json
   pairs = json.load(open("/testbed/pairs.json"))
   for i, p in enumerate(pairs):
       got = solve(p["input"])
       ok = equal(got, p["output"])
       print(f"pair {i}: {'OK' if ok else 'FAIL'}")
       if not ok:
           # show first divergence
           for r,row in enumerate(got):
               exp = p["output"][r] if r < len(p["output"]) else None
               if exp is None or row != exp:
                   print(f"  row {r} got={row} exp={exp}"); break
   ```
   Do NOT proceed until ALL pairs pass. A solver that fits N-1 of N pairs is
   the wrong solver; keep searching. If you are stuck, look again at what makes
   the failing pair different.

5. **Test-input sanity.** Before you apply solve to the test input, compare the
   test to the training inputs: what structural features (object count,
   palette, symmetry, size) are new? Would your rule handle them naturally, or
   is your rule relying on assumptions taken from training? Prefer the SIMPLEST
   rule that fits — with only 2–3 training pairs, many rules match the data
   and the simplest one is usually what the test exercises.

6. **Apply and save.** Load test_input.json, apply solve, dump the result
   to /testbed/output.json. Print the output shape and palette to confirm.

7. **Double-check.** Verify output.json parses as JSON, is a list of lists of
   ints in 0-9, and its shape matches your expectation. Overwriting is cheap
   — refine if the check surfaces a flaw.

## ARC-AGI-2 pattern zoo (things to look for first)

- **Shape derivation.** Output shape often equals input shape, but can also be:
  a fixed size the training pairs share; a factor times input (upscale/tile);
  a factor divided by input (downsample); the bbox of a marker color; or the
  smallest tiled subgrid.
- **Objects.** Group non-background cells into connected components. Sort by
  size, color, or position. Common ops: move to a corner, recolor by size,
  keep only the largest / unique-colored one.
- **Symmetry and completion.** The transformation may complete a broken
  symmetry (fill the missing quadrant so the whole grid is symmetric).
- **Frames and interiors.** Rectangles of one color often mark a region to
  fill, extract, transform, or nest a smaller pattern inside.
- **Gravity / stacking.** Non-bg cells slide to an edge, sometimes color-by-color.
- **Counting / tallies.** The number of objects (by color, or in total) may
  determine an output value or shape.
- **Recoloring by rule.** Two colors swap; a rare color spreads; each color
  maps to a new color by some property (position, count, adjacency).
- **Tiling and repetition.** The output is the input tiled 2×2 or repeated N
  times based on a count in the input.
- **Line propagation.** A marker cell casts a line, ray, or beam in one or
  more directions until it hits something.
- **Denoising.** Remove scattered "noise" of one color while keeping the
  larger objects, or vice versa.

If your first hypothesis is not supported by ALL pairs, try a second, and a
third. Do not commit to a partial fit.

## Rules of thumb

- 0 is usually background but not always. Do not assume; check per puzzle.
- Every training pair must match, exactly. Off-by-one in shape is a wrong rule.
- Grid values are always integers 0-9. If your output has anything else, fix it.
- Reserve steps for verifying and re-writing output.json. Do NOT leave it
  in an intermediate or malformed state — the verifier reads whatever is there.

Now start.
""".strip()

TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "run",
            "description": (
                "Run a shell command in /testbed and get its combined stdout/stderr. "
                "Use this to inspect the puzzle data, write and test a solver, and "
                "eventually save the answer to /testbed/output.json."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "command": {
                        "type": "string",
                        "description": "Command executed with bash -c in /testbed.",
                    }
                },
                "required": ["command"],
            },
        },
    }
]


ARC_LIB_SOURCE = r'''"""Small helper library for ARC-AGI-2 puzzle solvers.

Standard library only. Import as `from arc_lib import *`.
"""
from collections import deque


def shape(grid):
    if not grid:
        return (0, 0)
    return (len(grid), len(grid[0]) if isinstance(grid[0], list) else 0)


def show(grid, sep=" "):
    if not grid:
        print("(empty)")
        return
    for row in grid:
        print(sep.join(str(v) for v in row))


def palette(grid):
    seen = set()
    for row in grid:
        for v in row:
            seen.add(v)
    return sorted(seen)


def find_color(grid, c):
    out = []
    for r, row in enumerate(grid):
        for k, v in enumerate(row):
            if v == c:
                out.append((r, k))
    return out


def _neighbors(r, c, connectivity=4):
    if connectivity == 4:
        return [(r - 1, c), (r + 1, c), (r, c - 1), (r, c + 1)]
    return [(r - 1, c - 1), (r - 1, c), (r - 1, c + 1),
            (r, c - 1), (r, c + 1),
            (r + 1, c - 1), (r + 1, c), (r + 1, c + 1)]


def components(grid, bg=0, connectivity=4):
    if not grid:
        return []
    R, C = shape(grid)
    seen = [[False] * C for _ in range(R)]
    out = []
    for r in range(R):
        for c in range(C):
            if seen[r][c] or grid[r][c] == bg:
                continue
            color = grid[r][c]
            cells = []
            q = deque([(r, c)])
            seen[r][c] = True
            while q:
                y, x = q.popleft()
                cells.append((y, x))
                for ny, nx in _neighbors(y, x, connectivity):
                    if 0 <= ny < R and 0 <= nx < C and not seen[ny][nx] and grid[ny][nx] == color:
                        seen[ny][nx] = True
                        q.append((ny, nx))
            rs = [p[0] for p in cells]
            cs = [p[1] for p in cells]
            out.append({
                "color": color,
                "cells": cells,
                "bbox": (min(rs), min(cs), max(rs), max(cs)),
                "size": len(cells),
            })
    return out


def transpose(grid):
    if not grid:
        return []
    R, C = shape(grid)
    return [[grid[r][c] for r in range(R)] for c in range(C)]


def rotate90(grid, k=1):
    g = [row[:] for row in grid]
    for _ in range(k % 4):
        g = transpose(g)
        g = [row[::-1] for row in g]
    return g


def flip_h(grid):
    return [row[::-1] for row in grid]


def flip_v(grid):
    return grid[::-1]


def pad(grid, rows, cols, value=0):
    R, C = shape(grid)
    out = [[value] * cols for _ in range(rows)]
    for r in range(min(R, rows)):
        for c in range(min(C, cols)):
            out[r][c] = grid[r][c]
    return out


def crop(grid, r0, c0, r1, c1):
    return [row[c0:c1 + 1] for row in grid[r0:r1 + 1]]


def tile(grid, kr, kc):
    out = []
    R = len(grid)
    for _ in range(kr):
        for r in range(R):
            out.append(grid[r] * kc)
    return out


def equal(a, b):
    if not isinstance(a, list) or not isinstance(b, list) or len(a) != len(b):
        return False
    for ra, rb in zip(a, b):
        if not isinstance(ra, list) or not isinstance(rb, list) or len(ra) != len(rb):
            return False
        if ra != rb:
            return False
    return True


def count_by_color(grid):
    """Return dict {color: count} of cells."""
    d = {}
    for row in grid:
        for v in row:
            d[v] = d.get(v, 0) + 1
    return d


def bbox_of_cells(cells):
    """Return (r0, c0, r1, c1) — inclusive bounding box — of a list of (r, c) cells."""
    if not cells:
        return None
    rs = [r for r, _ in cells]
    cs = [c for _, c in cells]
    return (min(rs), min(cs), max(rs), max(cs))


def bbox_of_color(grid, c):
    """Return the bbox of all cells of color c, or None if absent."""
    return bbox_of_cells(find_color(grid, c))


def blank(rows, cols, value=0):
    """Return an rows×cols grid filled with `value`."""
    return [[value] * cols for _ in range(rows)]


def apply_offset(grid, dr, dc, base_value=0):
    """Return a grid shifted by (dr, dc); cells that leave the grid are dropped,
    empty cells revealed are `base_value`. Same shape as input."""
    R, C = shape(grid)
    out = blank(R, C, base_value)
    for r in range(R):
        for c in range(C):
            nr, nc = r + dr, c + dc
            if 0 <= nr < R and 0 <= nc < C:
                out[nr][nc] = grid[r][c]
    return out


def replace(grid, old, new):
    """Return a copy of `grid` with every `old` cell set to `new`."""
    return [[new if v == old else v for v in row] for row in grid]


def diff_grids(a, b):
    """Return a list of (r, c, a_val, b_val) where cells differ. Same-shape assumed."""
    out = []
    for r, (ra, rb) in enumerate(zip(a, b)):
        for c, (va, vb) in enumerate(zip(ra, rb)):
            if va != vb:
                out.append((r, c, va, vb))
    return out


def show_diff(a, b, marker="X", background="."):
    """Print a mask grid where `marker` marks cells differing between a and b."""
    R = min(len(a), len(b))
    for r in range(R):
        row_a = a[r]
        row_b = b[r]
        C = min(len(row_a), len(row_b))
        line = []
        for c in range(C):
            line.append(marker if row_a[c] != row_b[c] else background)
        print(" ".join(line))
'''


def clip(text: str, limit: int) -> str:
    if len(text) <= limit:
        return text
    half = limit // 2
    dropped = len(text) - 2 * half
    return f"{text[:half]}\n...[{dropped} characters dropped]...\n{text[-half:]}"


def run_command(command: str, timeout_sec: int, output_limit: int) -> str:
    try:
        proc = subprocess.run(
            ["bash", "-c", command],
            capture_output=True,
            text=True,
            timeout=timeout_sec,
            cwd="/testbed",
        )
        out = (proc.stdout or "") + (proc.stderr or "")
        return clip(f"exit {proc.returncode}\n{out}".strip(), output_limit)
    except subprocess.TimeoutExpired as exc:
        partial = (exc.stdout or b"").decode(errors="replace") if isinstance(exc.stdout, bytes) else (exc.stdout or "")
        return clip(f"command timed out after {timeout_sec}s\n{partial}".strip(), output_limit)
    except Exception as exc:  # noqa: BLE001
        return f"command could not be run: {type(exc).__name__}: {exc}"


def _shape_summary(grid: Any) -> str:
    if not isinstance(grid, list) or not grid:
        return "0x0"
    return f"{len(grid)}x{len(grid[0]) if isinstance(grid[0], list) else 0}"


def _palette_of(grid: Any) -> list[int]:
    seen: set[int] = set()
    if isinstance(grid, list):
        for row in grid:
            if isinstance(row, list):
                for v in row:
                    if isinstance(v, int):
                        seen.add(v)
    return sorted(seen)


def _count_by_color(grid: Any) -> dict[int, int]:
    counts: dict[int, int] = {}
    if not isinstance(grid, list):
        return counts
    for row in grid:
        if isinstance(row, list):
            for v in row:
                if isinstance(v, int):
                    counts[v] = counts.get(v, 0) + 1
    return counts


def _pair_summary_line(idx: int, pair: dict[str, Any]) -> str:
    inp = pair.get("input"); out = pair.get("output")
    ip = _palette_of(inp); op = _palette_of(out)
    same_shape = _shape_summary(inp) == _shape_summary(out)
    added = sorted(set(op) - set(ip))
    removed = sorted(set(ip) - set(op))
    tag = "same-shape" if same_shape else "shape-change"
    parts = [
        f"    pair {idx}: {_shape_summary(inp)} -> {_shape_summary(out)} ({tag}); "
        f"in palette {ip}, out palette {op}"
    ]
    if added:
        parts.append(f"        colors added in output: {added}")
    if removed:
        parts.append(f"        colors removed in output: {removed}")
    ci = _count_by_color(inp); co = _count_by_color(out)
    # cell counts per color: shows what stays constant vs what changes (a common
    # ARC signature — e.g. a color's cell count doubling implies duplication).
    parts.append(
        "        cells by color: in {" +
        ", ".join(f"{k}:{ci[k]}" for k in sorted(ci)) +
        "} -> out {" +
        ", ".join(f"{k}:{co[k]}" for k in sorted(co)) + "}"
    )
    return "\n".join(parts)


def _build_user_message(pairs: list[dict[str, Any]], test_input: list[list[int]] | None) -> str:
    lines = ["An ARC-AGI-2 puzzle. The data is on disk:"]
    lines.append("")
    lines.append(f"- /testbed/pairs.json — {len(pairs)} training pair(s)")
    for i, p in enumerate(pairs):
        lines.append(_pair_summary_line(i, p))
    tp = _palette_of(test_input)
    lines.append(
        f"- /testbed/test_input.json — test input, shape {_shape_summary(test_input)}, "
        f"palette {tp}"
    )
    # Highlight any test-input palette values that never appear in any training input:
    # a very common source of over-fitting is a rule that hardcodes training colors.
    train_in_palette: set[int] = set()
    for p in pairs:
        train_in_palette |= set(_palette_of(p.get("input")))
    novel = sorted(set(tp) - train_in_palette)
    if novel:
        lines.append(
            f"        NOTE: colors {novel} in test input do NOT appear in any training input"
        )
    lines.append(f"- /testbed/instruction.md — the raw puzzle text")
    lines.append(f"- /testbed/arc_lib.py — helper library ('from arc_lib import *')")
    lines.append("")
    lines.append(
        "Infer the transformation from the training pairs, verify it against every "
        "pair, apply it to the test input, and write the result to "
        "/testbed/output.json as a JSON 2D array of integers 0-9."
    )
    lines.append("")
    lines.append("Start by loading the data with a small python3 -c command.")
    return "\n".join(lines)


def _install_arc_lib() -> None:
    try:
        Path("/testbed/arc_lib.py").write_text(ARC_LIB_SOURCE, encoding="utf-8")
    except Exception:
        pass


def _write_fallback(test_input: list[list[int]] | None) -> None:
    """After the loop exits, if output.json is missing/empty, drop test_input in.

    Called AFTER solve() returns, so it never triggers the tool_choice="auto"
    transition that happens when output.json exists during the loop. This is a
    safety net for attempts that terminated before writing anything — a copy of
    the input is a legal grid, and identity-preserving puzzles score.
    """
    p = Path(OUTPUT_PATH)
    if p.exists() and p.stat().st_size > 0:
        return
    fallback = test_input if isinstance(test_input, list) else []
    try:
        p.write_text(json.dumps(fallback), encoding="utf-8")
    except Exception:
        pass


def solve(
    *,
    model: str,
    pairs: list[dict[str, Any]],
    test_input: list[list[int]] | None,
    max_tokens: int,
    reasoning_effort: str,
    max_steps: int,
    command_timeout_sec: int,
    output_limit: int,
) -> dict[str, Any]:
    _install_arc_lib()

    user_message = _build_user_message(pairs, test_input)
    messages: list[dict[str, Any]] = [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": user_message},
    ]
    steps = 0
    stop_reason = "max_steps"
    in_tokens = out_tokens = 0
    cost = 0.0
    finish_reasons: list[str] = []
    # Force at least one tool call every turn: the observed baseline failure is that
    # the model spends its entire per-call token budget on hidden reasoning and never
    # emits a tool call, so the /testbed/output.json file never gets written. Making
    # a tool call mandatory turns "think then reply" into "think then act", which is
    # exactly what this loop is for.
    tool_choice: Any = "required"
    # Step index at which output.json first appears. Used to keep tool_choice required
    # for a short post-write verification phase before switching to auto.
    first_output_step: int | None = None

    while steps < max_steps:
        response = litellm.completion(
            model=model,
            messages=messages,
            tools=TOOLS,
            tool_choice=tool_choice,
            max_tokens=max_tokens,
            reasoning_effort=reasoning_effort,
            temperature=DEFAULT_TEMPERATURE,
            num_retries=DEFAULT_MAX_RETRIES,
        )
        steps += 1
        choice = response.choices[0]
        message = choice.message
        usage = getattr(response, "usage", None)
        in_tokens += getattr(usage, "prompt_tokens", 0) or 0
        out_tokens += getattr(usage, "completion_tokens", 0) or 0
        finish_reasons.append(choice.finish_reason)
        try:
            cost += litellm.completion_cost(completion_response=response) or 0.0
        except Exception:
            pass

        messages.append(message.model_dump(exclude_none=True))
        tool_calls = getattr(message, "tool_calls", None) or []
        if not tool_calls:
            # Under tool_choice="required" this should not happen unless the model
            # ran out of budget mid-response. Treat it as a signal to stop — the next
            # call would repeat.
            stop_reason = "no_tool_call"
            break

        finished = False
        for call in tool_calls:
            try:
                args = json.loads(call.function.arguments or "{}")
            except json.JSONDecodeError:
                args = {}
            command = str(args.get("command", ""))
            result = (
                run_command(command, command_timeout_sec, output_limit)
                if command
                else "no command given"
            )
            messages.append(
                {
                    "role": "tool",
                    "tool_call_id": call.id,
                    "content": result,
                }
            )

        # If a valid output has been written, force a short verification phase before
        # letting the model stop. Baseline fails most often at exactly this point: the
        # model writes an over-specialized solver's output and stops before catching
        # that its rule doesn't handle features unique to the test input.
        if Path(OUTPUT_PATH).exists() and Path(OUTPUT_PATH).stat().st_size > 0:
            if first_output_step is None:
                first_output_step = steps
                # Inject a critical-review reminder ONCE, right after the first write.
                # A synthetic user turn is more visible than another line in the
                # system prompt and lands with fresh reasoning budget.
                messages.append({
                    "role": "user",
                    "content": POST_WRITE_REVIEW_MESSAGE,
                })
            if steps - first_output_step >= POST_WRITE_REQUIRED_STEPS:
                tool_choice = "auto"

        if finished:
            break

    return {
        "steps": steps,
        "stop_reason": stop_reason,
        "n_input_tokens": in_tokens,
        "n_output_tokens": out_tokens,
        "cost_usd": cost,
        "finish_reasons": finish_reasons,
        "messages": messages,
    }


def _load_pairs(path: Path) -> list[dict[str, Any]]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return data if isinstance(data, list) else []
    except Exception:
        return []


def _load_test_input(path: Path) -> list[list[int]] | None:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return data if isinstance(data, list) else None
    except Exception:
        return None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--instruction-file", type=Path, default=Path("/testbed/instruction.md"))
    parser.add_argument("--pairs-file", type=Path, default=Path("/testbed/pairs.json"))
    parser.add_argument("--test-input-file", type=Path, default=Path("/testbed/test_input.json"))
    parser.add_argument("--summary-path", type=Path, default=Path("/logs/agent/arc-agent-summary.json"))
    parser.add_argument("--transcript-path", type=Path, default=Path("/logs/agent/arc-agent-transcript.json"))
    parser.add_argument("--model", required=True)
    # Defaults are the fixed capability above, so the runner behaves the same whether
    # or not the harness passes them explicitly.
    parser.add_argument("--max-tokens", type=int, default=DEFAULT_MAX_TOKENS)
    parser.add_argument("--reasoning-effort", default=DEFAULT_REASONING_EFFORT)
    parser.add_argument("--max-steps", type=int, default=DEFAULT_MAX_STEPS)
    parser.add_argument("--command-timeout-sec", type=int, default=DEFAULT_COMMAND_TIMEOUT_SEC)
    parser.add_argument("--output-limit-chars", type=int, default=DEFAULT_OUTPUT_LIMIT_CHARS)
    args = parser.parse_args()

    pairs = _load_pairs(args.pairs_file)
    test_input = _load_test_input(args.test_input_file)

    result: dict[str, Any] = {}
    error = None
    try:
        result = solve(
            model=args.model,
            pairs=pairs,
            test_input=test_input,
            max_tokens=args.max_tokens,
            reasoning_effort=args.reasoning_effort,
            max_steps=args.max_steps,
            command_timeout_sec=args.command_timeout_sec,
            output_limit=args.output_limit_chars,
        )
    except Exception as exc:  # noqa: BLE001
        error = f"{type(exc).__name__}: {exc}"
        traceback.print_exc()

    # Safety net: if the loop exited without writing anything, drop the test input
    # in as a placeholder. Puzzles where the transformation is identity will score;
    # others will still fail, but no worse than they would with an empty file.
    _write_fallback(test_input)

    output_path = Path(OUTPUT_PATH)
    summary = {
        "n_input_tokens": result.get("n_input_tokens"),
        "n_output_tokens": result.get("n_output_tokens"),
        "cost_usd": result.get("cost_usd"),
        "metadata": {
            "model": args.model,
            "max_tokens": args.max_tokens,
            "reasoning_effort": args.reasoning_effort,
            "max_steps": args.max_steps,
            "steps_used": result.get("steps"),
            "stop_reason": result.get("stop_reason"),
            "finish_reasons": result.get("finish_reasons"),
            "n_pairs": len(pairs),
            "test_input_shape": (
                [len(test_input), len(test_input[0]) if test_input and test_input[0] else 0]
                if test_input else None
            ),
            # Recorded because a run that never wrote the file and a run that wrote a
            # wrong grid both score zero, and only this tells them apart.
            "output_written": output_path.exists(),
            "output_bytes": output_path.stat().st_size if output_path.exists() else 0,
            "error": error,
        },
    }
    args.summary_path.parent.mkdir(parents=True, exist_ok=True)
    args.summary_path.write_text(json.dumps(summary, indent=2), encoding="utf-8")
    args.transcript_path.write_text(
        json.dumps(
            {"system_prompt": SYSTEM_PROMPT, "summary": summary,
             "messages": result.get("messages", [])},
            indent=2, default=str,
        ),
        encoding="utf-8",
    )

    print(f"[agent] steps={result.get('steps')} stop={result.get('stop_reason')} "
          f"output_written={summary['metadata']['output_written']}")
    if error:
        print(f"[agent] error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
