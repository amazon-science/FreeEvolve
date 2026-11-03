"""Harbor shim for the ARC-AGI-2 puzzle agent.

Installs the runner into the task container, hands it the puzzle, and reports back
what the attempt spent. All the behaviour worth changing lives in run_arc_agent.py;
this file is the wiring that gets it there.
"""

from __future__ import annotations

import json
import os
import re
import shlex
from pathlib import Path
from typing import Any

from harbor.agents.installed.base import BaseInstalledAgent
from harbor.environments.base import BaseEnvironment
from harbor.models.agent.context import AgentContext

RUNNER_FILENAME = "run_arc_agent.py"
RUNNER_TARGET_PATH = f"/{RUNNER_FILENAME}"
# The task image does not carry the puzzle text: harbor passes it to the agent, so it
# has to be put inside the container before the runner can read it.
INSTRUCTION_TARGET_PATH = "/testbed/instruction.md"
PAIRS_TARGET_PATH = "/testbed/pairs.json"
TEST_INPUT_TARGET_PATH = "/testbed/test_input.json"
SUMMARY_FILENAME = "arc-agent-summary.json"
LITELLM_PIN = "1.94.0"
DEFAULT_VERSION = "1.0"
# The model capability, mirrored from the runner so a reader of either file sees the
# same numbers. FIXED, not a knob — see ENVIRONMENT.md.
DEFAULT_MAX_TOKENS = 16384
DEFAULT_REASONING_EFFORT = "medium"


_EXAMPLE_RE = re.compile(
    r"--Example\s+(\d+)--\s*\n\s*INPUT:\s*\n\s*(\[\[.+?\]\])\s*\n\s*OUTPUT:\s*\n\s*(\[\[.+?\]\])",
    re.DOTALL,
)
_TEST_RE = re.compile(
    r"--Test Input--\s*\n(\[\[.+?\]\])\s*\n--End of Test Input--",
    re.DOTALL,
)


def _parse_puzzle(text: str) -> tuple[list[dict[str, Any]], list[list[int]] | None]:
    """Extract training pairs and the test input grid from the instruction text.

    The instruction has a well-known shape (see the datasets), so the parser is a
    couple of regexes. If it does not match, the runner will fall back to reading
    the raw instruction.md.
    """
    pairs: list[dict[str, Any]] = []
    for m in _EXAMPLE_RE.finditer(text):
        try:
            pairs.append(
                {
                    "input": json.loads(m.group(2)),
                    "output": json.loads(m.group(3)),
                }
            )
        except json.JSONDecodeError:
            continue
    test_input: list[list[int]] | None = None
    tm = _TEST_RE.search(text)
    if tm:
        try:
            test_input = json.loads(tm.group(1))
        except json.JSONDecodeError:
            test_input = None
    return pairs, test_input


class ARCAgent(BaseInstalledAgent):
    def __init__(
        self,
        *args: Any,
        max_tokens: int = DEFAULT_MAX_TOKENS,
        reasoning_effort: str = DEFAULT_REASONING_EFFORT,
        max_steps: int | None = None,
        **kwargs: Any,
    ) -> None:
        super().__init__(*args, **kwargs)
        self._max_tokens = max_tokens
        self._reasoning_effort = reasoning_effort
        self._max_steps = max_steps

    @staticmethod
    def name() -> str:
        return "arc-agent"

    def version(self) -> str | None:
        return self._version or DEFAULT_VERSION

    async def install(self, environment: BaseEnvironment) -> None:
        # The task image is python plus curl plus uv and nothing else, so the client
        # has to be installed here. Pinned, because a floating client version would
        # change what the agent is across runs for reasons unrelated to the agent.
        await self.exec_as_root(
            environment,
            command=f"python3 -m pip install --no-cache-dir litellm=={LITELLM_PIN} boto3",
        )
        runner_src = Path(__file__).with_name(RUNNER_FILENAME)
        local_copy = self.logs_dir / RUNNER_FILENAME
        local_copy.write_text(runner_src.read_text(encoding="utf-8"), encoding="utf-8")
        await environment.upload_file(local_copy, RUNNER_TARGET_PATH)

    async def run(
        self,
        instruction: str,
        environment: BaseEnvironment,
        context: AgentContext,
    ) -> None:
        if not self.model_name:
            raise ValueError("model_name is required for ARCAgent")

        instruction_copy = self.logs_dir / "arc-agent.instruction.md"
        instruction_copy.write_text(instruction, encoding="utf-8")
        await environment.upload_file(instruction_copy, INSTRUCTION_TARGET_PATH)

        # Pre-parse the puzzle so the model does not have to grep the instruction with
        # bash commands. Extracting the training pairs and test input on this side
        # means (a) the initial user message stays short, so the model does not try to
        # solve the entire puzzle in one over-reasoned reply, and (b) the runner can
        # depend on the data being available as JSON at a known path.
        pairs, test_input = _parse_puzzle(instruction)
        pairs_copy = self.logs_dir / "pairs.json"
        pairs_copy.write_text(json.dumps(pairs), encoding="utf-8")
        await environment.upload_file(pairs_copy, PAIRS_TARGET_PATH)
        if test_input is not None:
            test_copy = self.logs_dir / "test_input.json"
            test_copy.write_text(json.dumps(test_input), encoding="utf-8")
            await environment.upload_file(test_copy, TEST_INPUT_TARGET_PATH)

        parts = [
            "python3",
            RUNNER_TARGET_PATH,
            "--model",
            shlex.quote(self.model_name),
            "--instruction-file",
            shlex.quote(INSTRUCTION_TARGET_PATH),
            "--pairs-file",
            shlex.quote(PAIRS_TARGET_PATH),
            "--test-input-file",
            shlex.quote(TEST_INPUT_TARGET_PATH),
            "--max-tokens",
            str(self._max_tokens),
            "--reasoning-effort",
            shlex.quote(self._reasoning_effort),
        ]
        if self._max_steps is not None:
            parts.extend(["--max-steps", str(self._max_steps)])
        command = " ".join(parts) + " 2>&1 | tee /logs/agent/arc-agent.txt"
        await self.exec_as_agent(environment, command=command, env=self._build_runner_env())

    def _build_runner_env(self) -> dict[str, str]:
        # Bedrock credentials come from the instance role, so only the region has to
        # travel; nothing secret is passed into the container.
        env: dict[str, str] = {}
        for key in ("AWS_REGION", "AWS_DEFAULT_REGION"):
            value = self._get_env(key) or os.environ.get(key)
            if value:
                env[key] = value
        for source in (os.environ, self._extra_env):
            for key, value in source.items():
                if key.startswith("LITELLM_") and value:
                    env[key] = value
        return env

    def populate_context_post_run(self, context: AgentContext) -> None:
        summary_path = self.logs_dir / SUMMARY_FILENAME
        if not summary_path.exists():
            return
        try:
            summary = json.loads(summary_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            return
        context.n_input_tokens = _coerce_int(summary.get("n_input_tokens"))
        context.n_output_tokens = _coerce_int(summary.get("n_output_tokens"))
        context.cost_usd = _coerce_float(summary.get("cost_usd"))
        metadata = summary.get("metadata")
        if isinstance(metadata, dict):
            context.metadata = metadata


def _coerce_int(value: Any) -> int | None:
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _coerce_float(value: Any) -> float | None:
    try:
        return float(value)
    except (TypeError, ValueError):
        return None
