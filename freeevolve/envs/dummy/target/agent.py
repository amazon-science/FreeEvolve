#!/usr/bin/env python3
"""A question-answering agent.

Usage:  python agent.py <question_file> <answer_file>

Reads a question, answers it, writes the answer to <answer_file>.
"""

import subprocess
import sys

MODEL = "us.anthropic.claude-haiku-4-5-20251001-v1:0"

PROMPT = """Answer this question.

{question}

Reply with the answer only."""


def ask(prompt: str) -> str:
    """Send a prompt to the model and return its reply."""
    proc = subprocess.run(
        [
            "claude", "-p", prompt,
            "--model", MODEL,
            # The model answers on its own, without tools.
            "--disallowed-tools", "Bash", "Read", "Write", "Edit", "Glob",
            "Grep", "Task", "WebFetch", "WebSearch", "TodoWrite", "NotebookEdit",
        ],
        capture_output=True,
        text=True,
        timeout=150,
    )
    return proc.stdout.strip()


def main() -> None:
    question = open(sys.argv[1]).read().strip()
    answer = ask(PROMPT.format(question=question))
    open(sys.argv[2], "w").write(answer)


if __name__ == "__main__":
    main()
