#!/usr/bin/env python3
"""The answering agent, as it runs inside the task container.

Reads the task's instruction (and its image, if it has one), asks the model, and
writes the answer to the path the harness reads.

The response file has a required shape — Explanation / Answer / Confidence — and
the grader reads only that file. Nothing here parses or reformats the model's
reply: what the model writes is what is submitted.
"""

from __future__ import annotations

import argparse
import base64
import json
import mimetypes
import sys
import traceback
from pathlib import Path
from typing import Any

import litellm

litellm.drop_params = True

# The model capability this agent runs at. FIXED, not a knob: raising, lowering or
# removing either of these changes how much inference the agent buys per attempt
# rather than how well the agent is built. See ENVIRONMENT.md.
DEFAULT_MAX_TOKENS = 16384
DEFAULT_REASONING_EFFORT = "medium"
# Extended thinking requires temperature 1.0, so the agent is sampled rather than
# greedy and repeated attempts at the same question differ.
DEFAULT_TEMPERATURE = 1.0
DEFAULT_MAX_RETRIES = 4

IMAGE_SUFFIXES = (".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp")

SYSTEM_PROMPT = """
You are answering one question that may require expert knowledge.
""".strip()


def find_image(workspace: Path) -> Path | None:
    for path in sorted(workspace.iterdir()):
        if path.is_file() and path.suffix.lower() in IMAGE_SUFFIXES:
            return path
    return None


def build_messages(instruction: str, image: Path | None) -> list[dict[str, Any]]:
    content: list[dict[str, Any]] = [{"type": "text", "text": instruction}]
    if image is not None:
        mime = mimetypes.guess_type(image.name)[0] or "image/jpeg"
        encoded = base64.b64encode(image.read_bytes()).decode("ascii")
        content.append(
            {
                "type": "image_url",
                "image_url": {"url": f"data:{mime};base64,{encoded}"},
            }
        )
    return [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": content},
    ]


def answer(
    *,
    model: str,
    instruction: str,
    image: Path | None,
    max_tokens: int,
    reasoning_effort: str,
) -> tuple[str, dict[str, Any]]:
    messages = build_messages(instruction, image)
    response = litellm.completion(
        model=model,
        messages=messages,
        max_tokens=max_tokens,
        reasoning_effort=reasoning_effort,
        temperature=DEFAULT_TEMPERATURE,
        num_retries=DEFAULT_MAX_RETRIES,
    )
    text = response.choices[0].message.content or ""
    usage = getattr(response, "usage", None)
    stats = {
        "n_input_tokens": getattr(usage, "prompt_tokens", None),
        "n_output_tokens": getattr(usage, "completion_tokens", None),
        "finish_reason": response.choices[0].finish_reason,
        "had_image": image is not None,
    }
    try:
        stats["cost_usd"] = litellm.completion_cost(completion_response=response)
    except Exception:
        stats["cost_usd"] = None
    return text, stats


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--instruction-file", type=Path, default=Path("/app/instruction.md"))
    parser.add_argument("--workspace", type=Path, default=Path("/app"))
    parser.add_argument("--response-path", type=Path, default=Path("/logs/agent/response.txt"))
    parser.add_argument("--summary-path", type=Path, default=Path("/logs/agent/hle-agent-summary.json"))
    parser.add_argument("--transcript-path", type=Path, default=Path("/logs/agent/hle-agent-transcript.json"))
    parser.add_argument("--model", required=True)
    # Defaults are the fixed capability above, so the runner behaves the same
    # whether or not the harness passes them explicitly.
    parser.add_argument("--max-tokens", type=int, default=DEFAULT_MAX_TOKENS)
    parser.add_argument("--reasoning-effort", default=DEFAULT_REASONING_EFFORT)
    args = parser.parse_args()

    instruction = args.instruction_file.read_text(encoding="utf-8")
    image = find_image(args.workspace)
    args.response_path.parent.mkdir(parents=True, exist_ok=True)

    stats: dict[str, Any] = {}
    text = ""
    error = None
    try:
        text, stats = answer(
            model=args.model,
            instruction=instruction,
            image=image,
            max_tokens=args.max_tokens,
            reasoning_effort=args.reasoning_effort,
        )
    except Exception as exc:  # noqa: BLE001
        error = f"{type(exc).__name__}: {exc}"
        traceback.print_exc()

    # Written even when the call failed, and written empty rather than not at all:
    # an empty response is a fact the grader can see, while a missing file makes a
    # failed attempt indistinguishable from an attempt that never ran.
    args.response_path.write_text(text, encoding="utf-8")

    summary = {
        "n_input_tokens": stats.get("n_input_tokens"),
        "n_output_tokens": stats.get("n_output_tokens"),
        "cost_usd": stats.get("cost_usd"),
        "metadata": {
            "model": args.model,
            "max_tokens": args.max_tokens,
            "reasoning_effort": args.reasoning_effort,
            "finish_reason": stats.get("finish_reason"),
            "had_image": stats.get("had_image"),
            "response_chars": len(text),
            "error": error,
        },
    }
    args.summary_path.parent.mkdir(parents=True, exist_ok=True)
    args.summary_path.write_text(json.dumps(summary, indent=2), encoding="utf-8")
    args.transcript_path.write_text(
        json.dumps(
            {
                "system_prompt": SYSTEM_PROMPT,
                "instruction": instruction,
                "image": image.name if image else None,
                "response": text,
                "summary": summary,
            },
            indent=2,
        ),
        encoding="utf-8",
    )

    print(f"[agent] response {len(text)} chars -> {args.response_path}")
    if error:
        print(f"[agent] error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
