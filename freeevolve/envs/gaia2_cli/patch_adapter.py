#!/usr/bin/env python3
"""Point the GAIA2 CLI adapter's judge at Bedrock instead of an OpenAI endpoint.

    patch_adapter.py <adapter_dir> <judge_model>

The upstream CLI verifier calls an OpenAI-compatible endpoint (OpenRouter by
default) with `JUDGE_MODEL=openai/gpt-4o-mini`. There is no OpenAI key on this
cluster and every other model role here runs on Bedrock, so the judge does too.

What changes is the transport and the judge model, not the rubric: the prompts,
the alias tables, the write-tool whitelist, the count gate, and the answer/action
routing are all left exactly as upstream wrote them. That distinction matters,
because a number produced here is comparable to the adapter's own reported
numbers only to the extent that the *judging* is the same, and a different judge
model is already a difference worth stating out loud.

Every substitution is asserted. If upstream edits one of these lines the patch
fails loudly rather than silently leaving the OpenAI path in place, which would
surface much later as a verifier that cannot reach its endpoint.
"""

from __future__ import annotations

import sys
from pathlib import Path

ADAPTER = Path(sys.argv[1])
JUDGE_MODEL = sys.argv[2]

JUDGE = ADAPTER / "template" / "tests" / "llm_judge.py"
TEST_SH = ADAPTER / "template" / "tests" / "test-cli.sh"
TASK_TOML = ADAPTER / "template" / "task-cli.toml"


def sub(path: Path, old: str, new: str, what: str) -> None:
    text = path.read_text()
    if old not in text:
        sys.exit(f"[patch] {path.name}: could not find {what} — upstream changed")
    path.write_text(text.replace(old, new, 1))
    print(f"[patch] {path.name}: {what}")


# --- the judge's LLM call -----------------------------------------------------
sub(
    JUDGE,
    "from openai import OpenAI",
    "import litellm\n\nlitellm.drop_params = True",
    "import swapped to litellm",
)

sub(
    JUDGE,
    'JUDGE_MODEL_DEFAULT = "openai/gpt-4o-mini"',
    f'JUDGE_MODEL_DEFAULT = "{JUDGE_MODEL}"',
    "default judge model",
)

sub(
    JUDGE,
    """def _get_client() -> OpenAI:
    api_key = os.environ.get("OPENAI_API_KEY", "").strip()
    if not api_key:
        raise JudgeConfigurationError("OPENAI_API_KEY is required for GAIA2 CLI judge")
    base_url = os.environ.get("OPENAI_BASE_URL") or None
    return OpenAI(api_key=api_key, base_url=base_url)""",
    """def _get_client() -> None:
    # Bedrock credentials come from the instance role, so there is no client to
    # build and nothing to check here. Kept as a no-op so the call sites below
    # stay recognisably upstream.
    return None""",
    "client construction",
)

sub(
    JUDGE,
    """    client = _get_client()
    response = client.chat.completions.create(
        model=_get_model(),
        messages=[
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ],
        temperature=0,
        max_tokens=max_tokens,
    )
    return response.choices[0].message.content or \"\"""",
    """    response = litellm.completion(
        model=_get_model(),
        messages=[
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ],
        temperature=0,
        max_tokens=max_tokens,
        # A judge call that fails is not a verdict — it would be recorded as a
        # verifier_error and the trial would score zero for a reason the agent
        # had no part in. Retry before letting that happen.
        num_retries=4,
    )
    return response.choices[0].message.content or \"\"""",
    "chat completion call",
)

# --- what the verifier container installs and requires -----------------------
sub(
    TEST_SH,
    'OPENAI_PACKAGE_VERSION="1.82.0"',
    'LITELLM_PACKAGE_VERSION="1.94.0"',
    "verifier package pin",
)

sub(
    TEST_SH,
    """if [[ -z "${OPENAI_API_KEY:-}" ]]; then
  echo "OPENAI_API_KEY is required for GAIA2 CLI verifier" >&2
  exit 1
fi""",
    """if [[ -z "${AWS_REGION:-}" ]]; then
  echo "AWS_REGION is required for GAIA2 CLI verifier (the judge runs on Bedrock)" >&2
  exit 1
fi""",
    "credential guard",
)

sub(
    TEST_SH,
    """# Install a pinned OpenAI SDK for the LLM judge.
python3 -m pip install --quiet "openai==${OPENAI_PACKAGE_VERSION}\"""",
    """# Install a pinned LiteLLM plus boto3 for the Bedrock-backed LLM judge.
python3 -m pip install --quiet "litellm==${LITELLM_PACKAGE_VERSION}" boto3""",
    "verifier install line",
)

# --- what the task hands the verifier ----------------------------------------
# The upstream table interpolates ${OPENAI_API_KEY} with no default, so an unset
# variable aborts task loading before anything runs — the same failure mode tau3
# has with its own host-env references.
sub(
    TASK_TOML,
    """GAIA2_CONFIG = "__CONFIG__"
OPENAI_API_KEY = "${OPENAI_API_KEY}"
OPENAI_BASE_URL = "${OPENAI_BASE_URL:-https://openrouter.ai/api/v1}"
JUDGE_MODEL = "${JUDGE_MODEL:-openai/gpt-4o-mini}\"""",
    f"""GAIA2_CONFIG = "__CONFIG__"
AWS_REGION = "${{AWS_REGION:-us-west-2}}"
AWS_DEFAULT_REGION = "${{AWS_REGION:-us-west-2}}"
JUDGE_MODEL = "${{JUDGE_MODEL:-{JUDGE_MODEL}}}\"""",
    "verifier env table",
)

print("[patch] adapter patched for Bedrock judging")
