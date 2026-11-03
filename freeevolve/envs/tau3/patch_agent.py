#!/usr/bin/env python3
"""Fix the adapter agent's extended-thinking path, in place.

The upstream tau3-bench agent works only with thinking off, which is its default.
Turn `reasoning_effort` on and three defects fire in sequence, so the lever reads
as harmful when it is not:

1. `parse_completion_message` rebuilds each assistant turn from `content` and
   `tool_calls` alone, dropping `thinking_blocks`/`reasoning_content`. Anthropic
   requires the thinking block that preceded a tool call to be sent back with it,
   and rejects the turn otherwise — so the failure surfaces one turn after its
   cause, in a conversation that was progressing.

2. A turn with no text and no tool call is recorded as `agent_error` and breaks
   the loop immediately. With thinking on the model occasionally returns a turn
   that is only a reasoning block, which is legitimate output, and the whole
   conversation is discarded for it with no retry.

3. `build_llm_args` sets `temperature` unconditionally, but Anthropic requires
   `temperature == 1.0` when thinking is enabled and rejects the call otherwise.

The grader scores a task 0 unless it terminates `agent_stop`/`user_stop`, so (1)
and (2) turn a passing task into a zero.

This patches the run directory's own copy, so the agent an evolver starts from
runs correctly with or without thinking. Idempotent: already-patched files are
left alone. Prints what it did; exits non-zero if a region it expects is missing,
since silently skipping would leave the defect in place.
"""

from __future__ import annotations

import sys
from pathlib import Path

MARKER = "# --- patched: extended-thinking support"

# 1. Carry the thinking blocks through, so a resent tool-use turn keeps its
#    signature.
PRESERVE_FROM = """    assistant_message = {
        "role": "assistant",
        "content": content,
    }
    if tool_calls:
        assistant_message["tool_calls"] = tool_calls
"""
PRESERVE_TO = '''    assistant_message = {
        "role": "assistant",
        "content": content,
    }
    if tool_calls:
        assistant_message["tool_calls"] = tool_calls

    # --- patched: extended-thinking support ---------------------------------
    # Anthropic checks that an assistant turn carrying tool_use is resent with
    # the thinking block that preceded it. litellm surfaces those as
    # `thinking_blocks` / `reasoning_content`; dropping them makes the *next*
    # turn fail, which reads as the model degenerating for no reason.
    thinking_blocks = _read_value(message, "thinking_blocks")
    if thinking_blocks:
        assistant_message["thinking_blocks"] = [
            block if isinstance(block, dict) else _model_dump(block)
            for block in thinking_blocks
        ]
    reasoning_content = _read_value(message, "reasoning_content")
    if reasoning_content:
        assistant_message["reasoning_content"] = reasoning_content
'''

# 2. Re-roll a thinking-only turn instead of aborting the conversation.
RETRY_FROM = """        content = assistant_message.get("content")
        if not isinstance(content, str) or not content.strip():
            runtime_status = await _record_termination(
                session,
                "agent_error",
                timeout_sec=tool_timeout_sec,
            )
"""
RETRY_TO = """        content = assistant_message.get("content")
        if not isinstance(content, str) or not content.strip():
            # --- patched: extended-thinking support -------------------------
            # A turn with neither text nor a tool call is degenerate, but with
            # thinking on it is usually just a reasoning-only turn, and the
            # conversation is otherwise fine. Drop that turn and re-sample
            # rather than ending the episode: the grader scores a run 0 unless
            # it terminates agent_stop/user_stop, so aborting here throws away
            # a task that was on its way to passing. A nudge message is not an
            # option — it would put two consecutive user turns in the history.
            if empty_turn_retries < MAX_EMPTY_TURN_RETRIES:
                empty_turn_retries += 1
                history_messages.pop()
                continue
            runtime_status = await _record_termination(
                session,
                "agent_error",
                timeout_sec=tool_timeout_sec,
            )
"""

# The retry counter, initialised with the loop's other accumulators.
COUNTER_INIT_FROM = """    stop_reason = "max_steps"
    turns_completed = 0
"""
COUNTER_INIT_TO = """    stop_reason = "max_steps"
    turns_completed = 0
    # --- patched: extended-thinking support ---------------------------------
    # Reasoning-only turns re-sampled so far, reset whenever a turn produces
    # real output, so the budget is per-stall rather than per-episode.
    empty_turn_retries = 0
"""

# Reset the counter once a turn has produced usable content.
COUNTER_RESET_FROM = """        message_response = await _submit_assistant_message(
            session,
            content,
            timeout_sec=tool_timeout_sec,
        )
"""
COUNTER_RESET_TO = """        empty_turn_retries = 0  # patched: this turn produced real output
        message_response = await _submit_assistant_message(
            session,
            content,
            timeout_sec=tool_timeout_sec,
        )
"""

# 3. Force temperature=1.0 when thinking is on, which the API requires.
TEMP_FROM = """    llm_args.setdefault("temperature", temperature)
    if seed is not None:
        llm_args.setdefault("seed", seed)
    effective_reasoning_effort = reasoning_effort or os.getenv(
        "TAU3_AGENT_REASONING_EFFORT"
    )
    if effective_reasoning_effort:
        llm_args.setdefault("reasoning_effort", effective_reasoning_effort)
"""
TEMP_TO = """    if seed is not None:
        llm_args.setdefault("seed", seed)
    effective_reasoning_effort = reasoning_effort or os.getenv(
        "TAU3_AGENT_REASONING_EFFORT"
    )
    if effective_reasoning_effort:
        llm_args.setdefault("reasoning_effort", effective_reasoning_effort)

    # --- patched: extended-thinking support ---------------------------------
    # Anthropic rejects extended thinking at any temperature but 1.0, so an
    # explicit temperature and a reasoning effort are mutually exclusive. Note
    # this makes the agent sampled rather than greedy, which adds real
    # run-to-run variance to the score.
    if effective_reasoning_effort:
        llm_args["temperature"] = 1.0
    else:
        llm_args.setdefault("temperature", temperature)
"""


def patch(path: Path) -> bool:
    src = path.read_text()
    if MARKER in src:
        print(f"[patch] {path.name}: already patched")
        return False

    missing = [
        name
        for name, frag in (
            ("thinking-block preservation", PRESERVE_FROM),
            ("empty-turn abort", RETRY_FROM),
            ("temperature default", TEMP_FROM),
            ("loop accumulators", COUNTER_INIT_FROM),
            ("assistant-message submit", COUNTER_RESET_FROM),
        )
        if frag not in src
    ]
    if missing:
        sys.exit(
            f"[patch] {path.name}: cannot find {', '.join(missing)} — the adapter "
            "has changed upstream. Re-read run_tau3_llm_agent.py and update "
            "patch_agent.py; do not skip, or the agent ships with the defect."
        )

    src = src.replace(PRESERVE_FROM, PRESERVE_TO, 1)
    src = src.replace(RETRY_FROM, RETRY_TO, 1)
    src = src.replace(TEMP_FROM, TEMP_TO, 1)

    src = src.replace(COUNTER_INIT_FROM, COUNTER_INIT_TO, 1)
    src = src.replace(COUNTER_RESET_FROM, COUNTER_RESET_TO, 1)
    path.write_text(src)
    print(f"[patch] {path.name}: extended thinking fixed (3 defects)")
    return True


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit("usage: patch_agent.py <agent_dir>")
    agent_dir = Path(sys.argv[1])
    target = agent_dir / "run_tau3_llm_agent.py"
    if not target.is_file():
        sys.exit(f"[patch] no run_tau3_llm_agent.py in {agent_dir}")
    patch(target)


if __name__ == "__main__":
    main()
