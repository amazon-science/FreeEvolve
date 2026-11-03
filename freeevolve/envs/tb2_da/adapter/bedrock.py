"""
bedrock.py — shared Amazon Bedrock model construction for deepagents harnesses.

The one place provider-specific request parameters live, so harnesses and benchmark
adapters never duplicate them. Callers (e.g. harbor_agent.py) import
`build_model` and supply their own execution backend.

deepagents uses LangChain model objects. `build_model` returns the right one for the
model id, on one of TWO paths:

  1. Bedrock Converse (langchain-aws ChatBedrockConverse) — the default. Works with ANY
     native Bedrock model id (Claude, gpt-oss, Qwen, Nova, …). No opinionated params are
     forced; optional knobs:
       - temperature: only sent if you pass it (some models reject an explicit value).
       - extended thinking for Claude: enabled only when the model is a Claude that
         supports it, since the request fields are Anthropic-specific.

  2. OpenAI-compatible "Mantle" Responses API (langchain-openai ChatOpenAI) — used ONLY
     for the GPT-5 family (e.g. openai.gpt-5.5). Those models are NOT served by Bedrock's
     Converse API (`bedrock list-foundation-models` does not list them) and reject
     `/v1/chat/completions`; they are reachable only through the Bedrock Mantle endpoint
     `https://bedrock-mantle.<region>.api.aws/openai/v1` via the Responses API. Auth is a
     minted Bedrock bearer token (12h TTL), so it works in-process from the host
     credential chain. gpt-oss is a NATIVE Converse model and stays on path (1).

Requires AWS credentials with Bedrock access.
"""

from __future__ import annotations

import base64
import os
from typing import Any

DEFAULT_MODEL = "global.anthropic.claude-opus-4-8"
DEFAULT_REGION = "us-west-2"

# OpenAI-compatible Mantle endpoint (path 2 above). GPT-5.x is served here, NOT via Converse.
# Region is independent of the Converse DEFAULT_REGION: the solver run sets AWS_REGION=us-west-2
# for Bedrock Converse (Claude/gpt-oss), but Mantle GPT-5.x lives in the us-east regions.
# Overridable via MANTLE_REGION so this never collides with the Converse region. NOTE: the
# per-account Mantle TPM quota (input 500k/min, output 100k/min) is PER-REGION, and a shared
# account can have us-east-2 saturated by other consumers (every request 429s there) while
# us-east-1 is free. So default to us-east-1; flip via MANTLE_REGION if that one fills up instead.
DEFAULT_MANTLE_REGION = "us-east-1"
# GPT-5 reasoning effort for the Responses API (minimal|low|medium|high). "high" mirrors the
# "max" effort the Claude path forces, so the optimizer/solver reasons hard by default.
DEFAULT_OPENAI_EFFORT = "high"

# Bedrock client timeouts + retries. botocore's defaults (60s read, no adaptive retries) are
# far too low for Opus with extended thinking under concurrency: a single converse call that
# takes >60s to start streaming raises ReadTimeoutError and fails the whole trial, which
# unfairly scores the harness 0 on what is really an infrastructure hiccup. We raise the read
# timeout generously and enable adaptive retries (which also back off on throttling). Applied
# in build_model, so EVERY caller benefits — the evolution loop AND run.sh seed benchmarking
# (both go through build_model via harbor_agent.py).
BEDROCK_READ_TIMEOUT_S = 600       # 10 min: ample for a long thinking + tool-call response
BEDROCK_CONNECT_TIMEOUT_S = 60
BEDROCK_MAX_RETRIES = 8            # adaptive retries (handles transient timeouts + throttling)

# Default per-call output budget for the Claude extended-thinking path. Thinking tokens are
# billed against this same budget, so it must comfortably exceed the max-effort thinking spend
# AND leave room for the tool call / final answer. This is a CEILING, not an allocation — we pay
# only for tokens actually generated — so a generous value costs nothing on a typical step and
# only protects the rare long-reasoning step (e.g. TB2's hard crypto/math tasks, whose single-step
# thinking can run long) from being truncated mid-step. 128000 matches the headroom the litellm-
# backed SoTA harnesses (mini-swe-agent, opencode, openhands, terminus-2) get for free — their
# model-cost map reports max_output_tokens=128000 and they set no explicit cap — so the DeepAgents
# seed/searched rows run at the SAME output budget as the SoTA rows (apples-to-apples). It is the
# model's documented max for opus-4.8, so known-safe. Only applied when the caller leaves max_tokens
# unset and thinking is on; an explicit max_tokens always wins. See build_model for the full rationale.
DEFAULT_THINKING_MAX_TOKENS = 128000


def _install_b64_padding_fix() -> None:
    """Make langchain-aws tolerant of unpadded base64 in data/file content blocks.

    When an agent feeds binary file content (e.g. a PDF or image read from the
    sandbox) to the model as a base64 data block, the string can arrive without
    correct '=' padding. langchain-aws' ChatBedrockConverse decodes it with
    base64.b64decode(), which raises `binascii.Error: Incorrect padding` and aborts
    the whole trial. We wrap that one helper to pad to a multiple of 4 first, so a
    malformed-but-recoverable block degrades gracefully instead of crashing the run.
    Idempotent; a no-op if the helper isn't present in the installed version.
    """
    try:
        from langchain_aws.chat_models import bedrock_converse as _bc
    except Exception:
        return
    if getattr(_bc, "_b64str_to_bytes_padsafe", False):
        return

    def _b64str_to_bytes(base64_str: str) -> bytes:
        s = base64_str.encode("utf-8") if isinstance(base64_str, str) else base64_str
        s += b"=" * ((-len(s)) % 4)  # restore missing padding
        return base64.b64decode(s)

    _bc._b64str_to_bytes = _b64str_to_bytes
    _bc._b64str_to_bytes_padsafe = True


_install_b64_padding_fix()


def _image_format(raw_b64) -> str | None:
    """Sniff the real image format from base64 bytes via magic numbers; None if the
    bytes are not a Bedrock-supported image (png/jpeg/gif/webp).

    Root cause this addresses: deepagents' read_file turns ANY binary file into an
    `image` content block (filesystem.py routes encoding=="base64" to a media block).
    When the agent reads a non-image binary, that mislabeled block makes Bedrock reject
    the whole request with "Could not process image". Real images sniff fine and pass
    through (vision works); mislabeled binaries are caught here.
    """
    import base64 as _b64
    if not raw_b64:
        return None
    try:
        b = _b64.b64decode((raw_b64.encode() if isinstance(raw_b64, str) else raw_b64) + b"=" * ((-len(raw_b64)) % 4))
    except Exception:
        return None
    if b[:8] == b"\x89PNG\r\n\x1a\n":
        return "png"
    if b[:3] == b"\xff\xd8\xff":
        return "jpeg"
    if b[:6] in (b"GIF87a", b"GIF89a"):
        return "gif"
    if b[:4] == b"RIFF" and b[8:12] == b"WEBP":
        return "webp"
    return None


def _fix_mislabeled_images(messages):
    """Convert image blocks whose bytes are NOT a real supported image into a text
    summary (path/size/sha256 + a hint to use shell tools), leaving genuine images
    untouched. This stops a binary-read mislabeled as an image from aborting the trial,
    without removing real vision. Model-agnostic.
    """
    import base64 as _b64
    import hashlib
    out = []
    for m in messages:
        content = getattr(m, "content", None)
        if not isinstance(content, list):
            out.append(m)
            continue
        blocks, changed = [], False
        for b in content:
            is_img = isinstance(b, dict) and (b.get("type") in ("image", "image_url") or "base64" in b)
            if is_img and _image_format(b.get("base64") or b.get("data")) is None:
                changed = True
                raw = b.get("base64") or b.get("data") or ""
                try:
                    by = _b64.b64decode((raw.encode() if isinstance(raw, str) else raw) + b"=" * ((-len(raw)) % 4))
                    desc = f"{len(by)} bytes, sha256={hashlib.sha256(by).hexdigest()}"
                except Exception:
                    desc = "undecodable"
                blocks.append({"type": "text", "text":
                    f"[binary file ({desc}) — not a viewable image; inspect/convert it "
                    f"with shell tools (file, xxd, sha256sum, python+PIL/OpenCV, OCR)]"})
            else:
                blocks.append(b)
        out.append(m.model_copy(update={"content": blocks}) if (changed and hasattr(m, "model_copy")) else m)
    return out


def _install_multimodal_guard() -> None:
    """Stop deepagents' mislabeled binary-as-image blocks from aborting a trial.

    Root cause: deepagents' read_file wraps every binary file in a multimodal `image`
    block; a non-image binary then makes Bedrock reject the request. Fix: before each
    model call, convert image blocks whose bytes are not a real supported image into a
    text summary. GENUINE images pass through untouched — vision still works. This is a
    deterministic pre-call sanitizer (not a strip-on-error), so it never silently drops
    real images and works for any Bedrock LLM.
    """
    try:
        from langchain_aws.chat_models.bedrock_converse import ChatBedrockConverse as _C
    except Exception:
        return
    if getattr(_C, "_multimodal_guarded", False):
        return
    _gen = getattr(_C, "_generate", None)
    if _gen is not None:
        def _generate_guarded(self, messages, *a, **k):
            return _gen(self, _fix_mislabeled_images(messages), *a, **k)
        _C._generate = _generate_guarded
    _strm = getattr(_C, "_stream", None)
    if _strm is not None:
        def _stream_guarded(self, messages, *a, **k):
            yield from _strm(self, _fix_mislabeled_images(messages), *a, **k)
        _C._stream = _stream_guarded
    _C._multimodal_guarded = True


def _install_tool_choice_downgrade_guard() -> None:
    """Downgrade an unsupported forced `tool_choice` to `auto` instead of erroring.

    Root cause: langchain frameworks that force structured output (e.g. deepagents'
    RubricMiddleware grader, or any `response_format=`/`with_structured_output` call) bind the
    output schema as a tool with `tool_choice="any"`. Claude on Bedrock only advertises
    `("auto",)` for tool_choice, so langchain-aws's `_resolve_tool_choice` raises ValueError
    and the trial dies at the grader.

    langchain-aws already has the right fallback (downgrade to "auto") but gates it on
    `_is_thinking_enabled()`. That gate is wrong for us for TWO reasons:
      1. Opus 4.8 declares thinking as `type=="adaptive"`, which the library's
         `_is_thinking_enabled` (only matches `"enabled"`) doesn't recognise; and
      2. more fundamentally, the limitation is NOT about thinking at all — Opus 4.8 rejects
         `tool_choice="any"` whether or not thinking is on. (An earlier version of this guard
         only widened the thinking check; that broke the moment the scientist grader was made
         thinking-free, because the downgrade was still gated on thinking — see
         deepagents_scientist._thinking_free.)

    Correct fix: wrap `_resolve_tool_choice` so that whenever a forced tool_choice is
    unsupported but `auto` IS supported, we resolve to `auto` unconditionally (thinking
    irrelevant). The model still runs its full structured-output evaluation; it just chooses
    tools rather than being forced. If `auto` isn't supported either, we defer to the original
    (which raises) — we never silently mask a genuinely unsupported configuration. This is the
    one place provider-specific request quirks live, so it protects every structured-output
    harness, not just one seed.
    """
    try:
        from langchain_aws.chat_models.bedrock_converse import (
            ChatBedrockConverse as _C,
            _format_tool_choice,
        )
    except Exception:
        return
    if getattr(_C, "_tool_choice_downgrade_guarded", False):
        return
    _orig = getattr(_C, "_resolve_tool_choice", None)
    if _orig is None:
        return

    def _resolve_tool_choice_patched(self, tool_choice):
        try:
            return _orig(self, tool_choice)
        except ValueError:
            # Original raised because the forced tool_choice isn't supported. If the model
            # supports "auto", downgrade to it (the library's own sanctioned fallback);
            # otherwise re-raise — don't mask a configuration the model truly can't honor.
            if tool_choice and "auto" in list(self.supports_tool_choice_values or []):
                return _format_tool_choice("auto")
            raise

    _C._resolve_tool_choice = _resolve_tool_choice_patched
    _C._tool_choice_downgrade_guarded = True


_install_multimodal_guard()
_install_tool_choice_downgrade_guard()


def _claude_thinking_fields(model_id: str) -> dict[str, Any] | None:
    """Anthropic-only reasoning request fields, or None for non-Claude / unsupported.

    Claude Opus 4.8 (and the 4.6/4.7 line) use adaptive thinking + output_config.effort
    and require the default temperature when thinking is on. Other Bedrock providers
    (Llama, Nova, Mistral, ...) do not accept these fields, so we return None for them.
    """
    if "anthropic" not in model_id and "claude" not in model_id:
        return None
    if any(tag in model_id for tag in ("claude-opus-4", "claude-sonnet-4", "claude-haiku-4")):
        return {"thinking": {"type": "adaptive"}, "output_config": {"effort": "max"}}
    return None


def _is_openai_responses_model(model_id: str) -> bool:
    """True for Bedrock-hosted OpenAI GPT-5.x models that must go through the Mantle
    Responses API rather than Converse.

    Scope it narrowly to the gpt-5 family: gpt-oss (openai.gpt-oss-*) IS a native Converse
    model and must stay on the ChatBedrockConverse path, so we match on the "gpt-5" stem
    only. Accepts ids with or without the "openai." prefix (openai.gpt-5.5, gpt-5.5, …).
    """
    mid = model_id.removeprefix("bedrock/").removeprefix("openai.").lower()
    return mid.startswith("gpt-5")


def _build_openai_mantle_model(
    model_id: str,
    *,
    region: str | None = None,
    temperature: float | None = None,
    max_tokens: int | None = None,
    reasoning_effort: str | None = None,
):
    """Construct a ChatOpenAI pointed at the Bedrock Mantle Responses API for GPT-5.x.

    Auth: mint a Bedrock bearer token (12h TTL) from the host credential chain. The token is
    passed as the OpenAI api_key; the base_url is the Mantle OpenAI-compatible endpoint.
    `use_responses_api=True` because GPT-5.x rejects /v1/chat/completions and only serves
    /v1/responses. Generous retries so a throttled Mantle call (429 input-tpm) backs off and
    retries instead of failing the trial.
    """
    from aws_bedrock_token_generator import provide_token
    from langchain_openai import ChatOpenAI

    model_id = model_id.removeprefix("bedrock/")  # ChatOpenAI wants the bare "openai.gpt-5.5"
    region = region or os.environ.get("MANTLE_REGION") or DEFAULT_MANTLE_REGION
    bearer = provide_token(region=region)
    effort = reasoning_effort or os.environ.get("OPENAI_REASONING_EFFORT") or DEFAULT_OPENAI_EFFORT

    kwargs: dict[str, Any] = {
        "model": model_id,
        "base_url": f"https://bedrock-mantle.{region}.api.aws/openai/v1",
        "api_key": bearer,
        "use_responses_api": True,   # GPT-5.x: Responses API only (no chat/completions)
        "reasoning_effort": effort,
        "max_retries": 8,            # back off on 429 input-tpm throttling (Mantle quota)
    }
    if temperature is not None:
        kwargs["temperature"] = temperature
    if max_tokens is not None:
        kwargs["max_tokens"] = max_tokens
    return ChatOpenAI(**kwargs)


def build_model(
    model_id: str = DEFAULT_MODEL,
    region: str = DEFAULT_REGION,
    *,
    temperature: float | None = None,
    max_tokens: int | None = None,
    additional_model_request_fields: dict[str, Any] | None = None,
):
    """Construct a Bedrock-backed LangChain chat model for deepagents.

    Dispatches on the model id: GPT-5.x (openai.gpt-5.*) goes to the OpenAI-compatible
    Mantle Responses API (ChatOpenAI); everything else — Claude, gpt-oss, Qwen, Nova — goes
    to Bedrock Converse (ChatBedrockConverse). The GPT-5.x path ignores
    `additional_model_request_fields` (those are Converse-specific).

    Converse path is model-agnostic by default: only params the caller explicitly sets are
    sent, so the model/Bedrock defaults apply otherwise. `temperature` and `max_tokens` are
    sent only if not None. Claude reasoning fields are auto-added when applicable unless you
    override `additional_model_request_fields`; when Claude thinking is active an explicit
    temperature is dropped (the model requires its default).
    """
    if _is_openai_responses_model(model_id):
        return _build_openai_mantle_model(
            model_id, temperature=temperature, max_tokens=max_tokens
        )

    from botocore.config import Config
    from langchain_aws import ChatBedrockConverse

    model_id = model_id.removeprefix("bedrock/")  # accept either form
    # Generous read timeout + adaptive retries so a slow/throttled Bedrock call retries
    # instead of failing the trial. "adaptive" mode also rate-limits client-side on throttling.
    boto_config = Config(
        read_timeout=BEDROCK_READ_TIMEOUT_S,
        connect_timeout=BEDROCK_CONNECT_TIMEOUT_S,
        retries={"max_attempts": BEDROCK_MAX_RETRIES, "mode": "adaptive"},
    )
    kwargs: dict[str, Any] = {"model": model_id, "region_name": region, "config": boto_config}

    fields = additional_model_request_fields
    if fields is None:
        fields = _claude_thinking_fields(model_id)
    thinking_on = bool(fields and "thinking" in fields)
    if fields:
        kwargs["additional_model_request_fields"] = fields

    # CRITICAL: with extended thinking on, thinking tokens are billed against the SAME
    # per-call output budget as the tool call / final text. If max_tokens is left unset,
    # ChatBedrockConverse sends maxTokens=None and Bedrock applies Claude's conservative
    # default (4096) — and the library only auto-unsets that cap for the *legacy* schema
    # (reasoningConfig.type=="enabled" + maxReasoningEffort=="high"), NOT the adaptive
    # schema we send (thinking.type=="adaptive" + output_config.effort=="max"). The result:
    # max-effort thinking eats the whole 4096, the model is truncated mid-step, and on many
    # tasks it never emits a single tool call (observed: 39/445 trials capped at out==4096
    # with tool_calls==0). litellm-based harnesses (mini-swe, openhands) dodge this because
    # litellm reads max_output_tokens (128k) from its model-cost map and passes it through.
    # So: when thinking is on and the caller didn't set max_tokens, supply a generous
    # default so thinking + the action both fit in one step (matches the litellm path).
    if max_tokens is None and thinking_on:
        max_tokens = DEFAULT_THINKING_MAX_TOKENS
    if max_tokens is not None:
        kwargs["max_tokens"] = max_tokens
    # only send temperature if the caller asked for one AND the model accepts it
    if temperature is not None and not thinking_on:
        kwargs["temperature"] = temperature

    return ChatBedrockConverse(**kwargs)
