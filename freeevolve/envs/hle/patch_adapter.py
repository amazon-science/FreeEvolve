#!/usr/bin/env python3
"""Point the HLE adapter's judge at Bedrock instead of an OpenAI endpoint.

    patch_hle_adapter.py <adapter_dir> <judge_model>

<adapter_dir> is a copy of harbor/adapters/hle — copied, because the shared
checkout is not ours to edit.

There is no OpenAI key on this cluster and every other model role here runs on
Bedrock, so the judge does too. The judge *prompt* is untouched: it is the
official HLE prompt, and the structured schema (extracted_final_answer,
reasoning, correct, confidence) is left exactly as upstream declared it, because
the calibration numbers are computed from those fields.

What does change, and what it costs: upstream uses the OpenAI SDK's
`beta.chat.completions.parse`, which enforces the schema server-side and returns
a parsed object. LiteLLM's Bedrock path asks the model for JSON instead and hands
back a string, so validation moves to our side. A malformed reply therefore
raises here rather than being rejected by the provider — which is why it stays
inside upstream's existing 20-attempt retry loop, where a bad parse is retried
like any other transient failure.

Every substitution is asserted, so an upstream edit fails the patch instead of
silently leaving the OpenAI path in place.
"""

from __future__ import annotations

import sys
from pathlib import Path

ADAPTER = Path(sys.argv[1])
JUDGE_MODEL = sys.argv[2]

TEMPLATE = ADAPTER / "src" / "hle" / "task-template"
JUDGE = TEMPLATE / "tests" / "test_judge.py"
DOCKERFILE = TEMPLATE / "environment" / "Dockerfile"
TASK_TOML = TEMPLATE / "task.toml"


def sub(path: Path, old: str, new: str, what: str) -> None:
    text = path.read_text()
    if old not in text:
        sys.exit(f"[patch] {path.name}: could not find {what} — upstream changed")
    path.write_text(text.replace(old, new, 1))
    print(f"[patch] {path.name}: {what}")


# --- the judge's client and call ----------------------------------------------
sub(
    JUDGE,
    """from openai import OpenAI
from pydantic import BaseModel""",
    """import litellm
from pydantic import BaseModel

litellm.drop_params = True""",
    "import swapped to litellm",
)

sub(
    JUDGE,
    """    api_key = os.environ.get("OPENAI_API_KEY")
    if not api_key:
        raise ValueError("OPENAI_API_KEY environment variable is not set")

    base_url = os.environ.get("OPENAI_BASE_URL")
    print(f"OPENAI_BASE_URL: {base_url or '(not set, using default)'}")

    client = OpenAI(
        api_key=api_key,
        base_url=base_url,
        timeout=300.0,
        max_retries=1,
    )
""",
    """    # Bedrock credentials come from the instance role, so there is nothing to
    # check and no client to build.
    print(f"judge region: {os.environ.get('AWS_REGION', '(unset)')}")
""",
    "client construction",
)

sub(
    JUDGE,
    """            response = client.beta.chat.completions.parse(
                model=model_name,
                max_completion_tokens=16384,
                messages=[{"role": "user", "content": prompt}],
                response_format=ExtractedAnswer,
            )

            content = response.choices[0].message.parsed
            if content is None:
                raise ValueError("Judge returned empty parsed content")""",
    """            response = litellm.completion(
                model=model_name,
                max_tokens=16384,
                messages=[{"role": "user", "content": prompt}],
                response_format=ExtractedAnswer,
                num_retries=0,  # the surrounding loop already retries
            )

            raw = response.choices[0].message.content
            if not raw:
                raise ValueError("Judge returned empty content")
            # Validation is ours now: the provider returns JSON text rather than a
            # schema-checked object. A bad parse raises and the retry loop handles
            # it, which is the same treatment a transient API error gets.
            content = ExtractedAnswer.model_validate_json(raw)""",
    "structured-output call",
)

sub(
    JUDGE,
    'model_name = os.environ.get("JUDGE_MODEL", "o3-mini-2025-01-31")',
    f'model_name = os.environ.get("JUDGE_MODEL", "{JUDGE_MODEL}")',
    "default judge model",
)

# The stripped-empty-env-var guard was there for the OpenAI SDK, which rejects an
# empty base_url. Harmless to leave, but name the reason it no longer applies.
sub(
    JUDGE,
    """# Clean up empty *_BASE_URL env vars that break SDK clients.
# Harbor's verifier.env passes "${VAR:-}" which resolves to "" when unset,
# but the OpenAI SDK will fail on "".""",
    """# Clean up empty *_BASE_URL env vars that break SDK clients. Kept for the case
# where a run still passes one through: harbor's verifier.env resolves "${VAR:-}"
# to "", which some clients reject outright.""",
    "base-url guard comment",
)

# --- what the task image installs --------------------------------------------
sub(
    DOCKERFILE,
    "RUN pip install --no-cache-dir openai>=1.59.0 pydantic>=2.10.0",
    'RUN pip install --no-cache-dir "litellm==1.94.0" boto3 "pydantic>=2.10.0"',
    "judge dependencies",
)

# --- what the task hands the verifier ----------------------------------------
# Upstream interpolates ${OPENAI_API_KEY} with no default, so an unset variable
# aborts task loading before anything runs.
sub(
    TASK_TOML,
    """[verifier.env]
OPENAI_API_KEY = "${OPENAI_API_KEY}"
OPENAI_BASE_URL = "${OPENAI_BASE_URL:-}"
JUDGE_MODEL = "${JUDGE_MODEL:-o3-mini-2025-01-31}\"""",
    f"""[verifier.env]
AWS_REGION = "${{AWS_REGION:-us-west-2}}"
AWS_DEFAULT_REGION = "${{AWS_REGION:-us-west-2}}"
JUDGE_MODEL = "${{JUDGE_MODEL:-{JUDGE_MODEL}}}\"""",
    "verifier env table",
)

print("[patch] HLE adapter patched for Bedrock judging")
