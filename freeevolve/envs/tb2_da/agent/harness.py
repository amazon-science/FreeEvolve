"""
deepagents_default.py — a minimal deepagents harness (stock baseline).

This is deepagents in its unmodified form: no custom prompt, tools, subagents, skills,
or memory. It runs purely on deepagents' built-in defaults, so it captures the
framework's out-of-the-box behavior with nothing added.

The agent LOOP lives inside LangGraph (via LangChain's create_agent); it is not
defined here. What this file exposes are deepagents' configuration surfaces — system
prompt, tools, subagents, skills, memory — assembled in build_agent(). All are left
empty here; deepagents supplies the rest.

Built-in tools provided by deepagents (no configuration needed):
    write_todos                              manage a todo list
    ls, read_file, write_file, edit_file,    file operations
        glob, grep
    execute                                  run shell commands (needs a shell backend)
    task                                     call subagents

System prompt: with SYSTEM_PROMPT = None, deepagents uses its built-in
BASE_AGENT_PROMPT alone (plus any per-model HarnessProfile suffix). Set a string to
prepend custom guidance in front of that default.

The model and backend are not constructed here — they are passed into build_agent().

Sources (deepagents, pinned at the installed version):
    create_deep_agent : https://github.com/langchain-ai/deepagents
    skills            : https://docs.langchain.com/oss/python/deepagents/skills

Usage:
    from deepagents_default import build_agent
    agent = build_agent(model, backend)
    result = agent.invoke({"messages": [{"role": "user", "content": task}]})
"""

from __future__ import annotations

from typing import Any

from deepagents import create_deep_agent


# ───────────────────────── prompts & config (the editable harness surfaces) ─────────────────────────

# Front-of-prompt instructions. None = use deepagents' own BASE_AGENT_PROMPT alone
# (plus any per-model HarnessProfile suffix) — i.e. the stock, unmodified baseline.
# This keeps the default harness fully minimal: no extra prompt, tools, subagents,
# skills, or memory. Set a string here to prepend custom guidance.
SYSTEM_PROMPT: str | None = None

# Extra tools beyond deepagents' built-ins (write_todos, file ops, execute, task).
# Each entry is a LangChain BaseTool / callable / tool dict. Empty = built-ins only.
EXTRA_TOOLS: list[Any] = []

# Subagents to delegate to (isolated context windows). Empty = none.
SUBAGENTS: list[Any] = []

# Skill source paths (Agent Skills spec: each a folder with SKILL.md + optional
# scripts/resources). deepagents loads metadata up front and the body on demand.
# e.g. SKILLS = ["./skills/"]
SKILLS: list[str] = []

# Long-term memory source paths (markdown files preloaded as memory). Empty = none.
MEMORY: list[str] = []


# ───────────────────────── factory ─────────────────────────

def build_agent(model, backend):
    """Assemble the deepagents harness around an injected model and backend.

    The runner supplies:
      - model:   a provider model id string ("bedrock/...", "anthropic:...") or a
                 pre-initialized LangChain BaseChatModel.
      - backend: the execution backend (e.g. LocalShellBackend) — deepagents'
                 analogue of mini-swe-agent's environment; it enables the `execute`
                 shell tool and file operations.

    Returns a compiled LangGraph agent. Invoke it with:
        agent.invoke({"messages": [{"role": "user", "content": task}]})
    """
    return create_deep_agent(
        model=model,
        tools=EXTRA_TOOLS,
        system_prompt=SYSTEM_PROMPT,
        subagents=SUBAGENTS,
        skills=SKILLS or None,
        memory=MEMORY or None,
        backend=backend,
    )
