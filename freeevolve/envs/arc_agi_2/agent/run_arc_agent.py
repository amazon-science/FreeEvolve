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
DEFAULT_MAX_STEPS = 40
# What one command may spend before it is cut off and its output returned as-is.
DEFAULT_COMMAND_TIMEOUT_SEC = 120
# How much of a command's output comes back. Output beyond this is dropped from the
# middle, keeping both ends, because a grid printed by accident can be enormous.
DEFAULT_OUTPUT_LIMIT_CHARS = 20000

OUTPUT_PATH = "/testbed/output.json"

SYSTEM_PROMPT = """
You are solving an ARC-AGI puzzle inside a Linux container. Each puzzle shows a
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

## The container

Python 3.11 with STANDARD LIBRARY ONLY — no numpy, no scipy. Use plain
`list[list[int]]`. Files you create in /testbed persist between commands. You
have shell (bash) and outbound network.

## A working recipe

1. Peek at the data:  small `python3 -c '...'` to see shapes, palettes, and any
   obvious features.
2. Hypothesise the transformation. Write it as a function `solve(grid) -> grid`
   in `/testbed/solver.py`.
3. Verify on every training pair. Do not go on until `solve(pair["input"])`
   equals `pair["output"]` cell-for-cell for ALL of them. If any pair fails,
   print the diff, refine the function, retry.
4. Once all training pairs match, apply `solve` to /testbed/test_input.json and
   write the result to /testbed/output.json as a JSON 2D int array.
5. Confirm the file exists and its shape looks right (`python3 -c 'import
   json;g=json.load(open("/testbed/output.json"));print(len(g), len(g[0]) if g
   else 0)'`).

## Rules of thumb

- Objects, colors, symmetry, tiling, gravity, counting, connected components,
  masking, denoising — ARC transformations are usually one of these; look for
  the simplest rule that fits every training example.
- If the test grid is different in size from the training inputs, the output
  shape is almost always derivable from the input (same shape, or from an
  obvious feature like the bounding box of a marker color).
- 0 is usually background but not always. Do not assume; check per puzzle.
- Every training pair must match. A rule that fits three of four pairs is the
  wrong rule; keep searching.
- Reserve some steps for writing and verifying the final answer. Do NOT leave
  /testbed/output.json empty or missing.

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


def _build_user_message(pairs: list[dict[str, Any]], test_input: list[list[int]] | None) -> str:
    lines = ["An ARC-AGI puzzle. The data is on disk:"]
    lines.append("")
    lines.append(f"- /testbed/pairs.json — {len(pairs)} training pair(s)")
    for i, p in enumerate(pairs):
        lines.append(
            f"    pair {i}: input {_shape_summary(p.get('input'))} -> "
            f"output {_shape_summary(p.get('output'))}"
        )
    lines.append(f"- /testbed/test_input.json — test input, shape {_shape_summary(test_input)}")
    lines.append(f"- /testbed/instruction.md — the raw puzzle text")
    lines.append("")
    lines.append(
        "Infer the transformation from the training pairs, verify it against every "
        "pair, apply it to the test input, and write the result to "
        "/testbed/output.json as a JSON 2D array of integers 0-9."
    )
    lines.append("")
    lines.append("Start by loading the data with a small python3 -c command.")
    return "\n".join(lines)


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

        # If a valid output has been written, let the model decide whether it wants
        # another round to verify or stop — switching to tool_choice="auto" so it
        # can end cleanly instead of being forced to loop.
        if Path(OUTPUT_PATH).exists() and Path(OUTPUT_PATH).stat().st_size > 0:
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
