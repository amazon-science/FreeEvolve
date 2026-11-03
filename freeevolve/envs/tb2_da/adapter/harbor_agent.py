"""
harbor_agent.py — harbor BaseAgent that runs a deepagents harness on Terminal-Bench 2.

VENDORED from the source repo's harbor_agent.py.
Four changes from that original, each marked `# VENDORED:` below:
  1. the sibling imports resolve next to THIS file instead of at a repo layout, because
     the adapter is installed flat into a run directory's eval/adapter/;
  2. `harness` must be a path to a .py file — the shorthand table named modules in the
     source repo's seed_harnesses/, which is not vendored;
  3. the resolved model configuration is written to logs_dir/model_config.json, so the
     output cap the request actually carries is readable from the artifacts;
  4. DEEPAGENTS_MAX_TOKENS is required rather than optional — this environment fixes the
     output cap, and a missing value would silently fall back to a different one.

This is the class harbor loads via `--agent-import-path harbor_agent:DeepAgentsHarbor`.
It follows the official deepagents<->harbor pattern (langchain-ai/deepagents
libs/evals/deepagents_harbor), but kept thin and routed through OUR pieces:

  - model:   built by bedrock.py  (one place for Bedrock/provider params)
  - harness: the .py file `harness=` names, which supplies build_agent(model, backend)
  - backend: HarborSandbox(environment) from harbor_sandbox.py (vendored), so the
             agent's file/shell ops run INSIDE harbor's per-task container

harbor's contract (harbor.agents.base.BaseAgent): implement name(), version(),
async setup(environment), async run(instruction, environment, context). The agent
executes against the container via the backend; we populate `context` with token
usage / cost so harbor can record it.

Selected via harbor agent-kwargs (--ak key=value):
    harness=/path/to/harness.py  the harness file      (required)
    model=bedrock/<id>           Bedrock model id      (default: from bedrock.py)
    region=<aws-region>          AWS region
"""

from __future__ import annotations

import importlib
import os
import sys
from pathlib import Path

from harbor.agents.base import BaseAgent
from harbor.environments.base import BaseEnvironment
from harbor.models.agent.context import AgentContext

# VENDORED (1): bedrock.py and harbor_sandbox.py sit BESIDE this file in the run
# directory's eval/adapter/, not at `../../runners` and `../../seed_harnesses` of a repo.
# Resolving against __file__ is what makes the installed run directory standalone: it
# holds its own copy of the adapter and cannot reach back into any source checkout.
_HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(_HERE))

from bedrock import build_model, DEFAULT_MODEL, DEFAULT_REGION  # noqa: E402
from harbor_sandbox import HarborSandbox  # noqa: E402



def _load_build_agent(harness: str):
    """Load build_agent(model, backend) from the .py file `harness` names.

    VENDORED (2): the original also accepted a shorthand name or a module name resolved
    against the source repo's seed_harnesses/ directory. That directory is not part of a
    run, so only the path form remains, and anything else is an error rather than a
    confusing ModuleNotFoundError. A relative path resolves against this file's directory.
    """
    import importlib.util

    if not harness.endswith(".py"):
        raise ValueError(
            f"harness={harness!r} is not a .py file. This adapter loads the harness from "
            "a path; pass the harness file the run declares in .target."
        )
    path = Path(harness)
    if not path.is_absolute():
        path = (_HERE / harness).resolve()
    if not path.is_file():
        raise FileNotFoundError(f"no harness file at {path}")
    spec = importlib.util.spec_from_file_location(path.stem, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    if not hasattr(mod, "build_agent"):
        raise AttributeError(
            f"{path} defines no build_agent(model, backend); that function is how harbor "
            "gets an agent out of the harness."
        )
    return mod.build_agent


class DeepAgentsHarbor(BaseAgent):
    """Run a deepagents harness against a Terminal-Bench 2 task via harbor."""

    # We don't emit Harbor's standard trajectory format (ATIF); _dump_trajectory writes
    # our own trajectory.json for the proposer instead. (False is BaseAgent's default;
    # stated explicitly so it's a decision, not an oversight.)
    SUPPORTS_ATIF = False

    def __init__(self, *args, harness: str = "default", model: str | None = None,
                 region: str | None = None, **kwargs):
        # harbor passes model via -m/--model into model_name; accept --ak model= too
        super().__init__(*args, model_name=(model or kwargs.pop("model_name", None)), **kwargs)
        self._harness_name = harness
        self._model_id = self.model_name or model or DEFAULT_MODEL
        self._region = region or DEFAULT_REGION
        self._build_agent = _load_build_agent(harness)

    @staticmethod
    def name() -> str:
        return "deepagents-harbor"

    def version(self) -> str | None:
        return "0.1.0"

    async def setup(self, environment: BaseEnvironment) -> None:
        # No agent install needed — deepagents runs in-process; the container only
        # needs to execute the commands the agent emits (handled by HarborSandbox).
        return None

    async def run(self, instruction: str, environment: BaseEnvironment,
                  context: AgentContext) -> None:
        # backend = harbor's container, presented to deepagents as its sandbox
        backend = HarborSandbox(environment)
        # our model (bedrock.py) + the harness file assemble the agent.
        #
        # DEEPAGENTS_MAX_TOKENS is the per-call output cap, passed straight to
        # build_model(max_tokens=...) and from there to ChatBedrockConverse(max_tokens=...),
        # which is Converse's `inferenceConfig.maxTokens` on every request.
        #
        # VENDORED (4): the original treated it as optional, falling back to bedrock.py's
        # own default when unset. Here it is REQUIRED. The cap is fixed capability in this
        # environment, so it is passed explicitly by the caller and a missing value is an
        # error rather than a silent second policy.
        _mt = os.environ.get("DEEPAGENTS_MAX_TOKENS", "").strip()
        if not _mt:
            raise RuntimeError(
                "DEEPAGENTS_MAX_TOKENS is not set. This environment fixes the per-call "
                "output cap and passes it explicitly; running without it would measure a "
                "different capability than the one declared in eval/defaults.env."
            )
        max_tokens = int(_mt)
        model = build_model(self._model_id, self._region, max_tokens=max_tokens)
        # VENDORED (3): record what the model was actually built with, so the output cap
        # carried by the request is readable from the artifacts instead of assumed.
        self._dump_model_config(model, max_tokens)
        agent = self._build_agent(model, backend)

        result = await agent.ainvoke(
            {"messages": [{"role": "user", "content": instruction}]}
        )

        # populate harbor's context with token usage / cost from the run
        self._populate_context(result, context)
        # dump a lightweight trajectory for later trace analysis (the proposer's input)
        self._dump_trajectory(instruction, result)

    def _dump_model_config(self, model, requested_max_tokens: int) -> None:
        """Write the resolved model configuration to logs_dir/model_config.json.

        `max_tokens` is read back off the constructed LangChain model object rather than
        echoed from the request, so the file says what the object will send, and a harness
        that rebuilt or rebound the model would show up as a different number here.
        """
        try:
            import json
            (self.logs_dir / "model_config.json").write_text(json.dumps({
                "harness": self._harness_name,
                "model_id": getattr(model, "model_id", None) or self._model_id,
                "region": getattr(model, "region_name", None) or self._region,
                "requested_max_tokens": requested_max_tokens,
                "model_max_tokens": getattr(model, "max_tokens", None),
                "temperature": getattr(model, "temperature", None),
                "additional_model_request_fields":
                    getattr(model, "additional_model_request_fields", None),
                "class": type(model).__name__,
            }, indent=2, default=str))
        except Exception:  # never fail a trial over logging
            self.logger.warning("model config dump failed", exc_info=True)

    def _dump_trajectory(self, instruction: str, result: dict) -> None:
        """Write a simple messages dump to logs_dir/trajectory.json (best-effort)."""
        try:
            import json
            steps = [{"role": "user", "content": instruction}]
            for m in result.get("messages", []):
                steps.append({
                    "type": type(m).__name__,
                    "content": getattr(m, "content", None),
                    "tool_calls": getattr(m, "tool_calls", None) or None,
                })
            (self.logs_dir / "trajectory.json").write_text(json.dumps(steps, indent=2, default=str))
        except Exception:  # never fail a trial over logging
            self.logger.warning("trajectory dump failed", exc_info=True)

    @staticmethod
    def _populate_context(result: dict, context: AgentContext) -> None:
        n_in = n_out = 0
        cost = 0.0
        for msg in result.get("messages", []):
            usage = getattr(msg, "usage_metadata", None)
            if usage:
                n_in += usage.get("input_tokens", 0) or 0
                n_out += usage.get("output_tokens", 0) or 0
            meta = getattr(msg, "response_metadata", {}) or {}
            cost += float(meta.get("total_cost", 0) or 0)
        if n_in:
            context.n_input_tokens = n_in
        if n_out:
            context.n_output_tokens = n_out
        if cost:
            context.cost_usd = cost
