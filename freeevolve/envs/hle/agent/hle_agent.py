"""Harbor shim for the HLE answering agent.

Installs the runner into the task container and executes it. All the behaviour
worth changing lives in run_hle_agent.py; this file is the wiring that gets it
there and hands back what it spent.
"""

from __future__ import annotations

import json
import os
import shlex
from pathlib import Path
from typing import Any

from harbor.agents.installed.base import BaseInstalledAgent
from harbor.environments.base import BaseEnvironment
from harbor.models.agent.context import AgentContext

RUNNER_FILENAME = "run_hle_agent.py"
RUNNER_TARGET_PATH = f"/{RUNNER_FILENAME}"
SUMMARY_FILENAME = "hle-agent-summary.json"
LITELLM_PIN = "1.94.0"
DEFAULT_VERSION = "1.0"
# The model capability, mirrored from the runner so a reader of either file sees
# the same numbers. FIXED, not a knob — see ENVIRONMENT.md.
DEFAULT_MAX_TOKENS = 16384
DEFAULT_REASONING_EFFORT = "medium"


class HLEAgent(BaseInstalledAgent):
    def __init__(
        self,
        *args: Any,
        max_tokens: int = DEFAULT_MAX_TOKENS,
        reasoning_effort: str = DEFAULT_REASONING_EFFORT,
        **kwargs: Any,
    ) -> None:
        super().__init__(*args, **kwargs)
        self._max_tokens = max_tokens
        self._reasoning_effort = reasoning_effort

    @staticmethod
    def name() -> str:
        return "hle-agent"

    def version(self) -> str | None:
        return self._version or DEFAULT_VERSION

    async def install(self, environment: BaseEnvironment) -> None:
        # The task image ships python but not litellm. Pinned, because a floating
        # client version would change what the agent is across runs for reasons
        # that have nothing to do with the agent.
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
            raise ValueError("model_name is required for HLEAgent")

        parts = [
            "python3",
            RUNNER_TARGET_PATH,
            "--model",
            shlex.quote(self.model_name),
            "--max-tokens",
            str(self._max_tokens),
            "--reasoning-effort",
            shlex.quote(self._reasoning_effort),
        ]
        command = " ".join(parts) + " 2>&1 | tee /logs/agent/hle-agent.txt"
        await self.exec_as_agent(environment, command=command, env=self._build_runner_env())

    def _build_runner_env(self) -> dict[str, str]:
        # Bedrock credentials come from the instance role, so only the region has
        # to travel; nothing secret is passed into the container.
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
