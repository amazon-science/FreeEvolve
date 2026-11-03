#!/usr/bin/env python3
"""Dummy-environment evaluator: run an agent over questions, score exact match.

Invoked via the workspace's run.sh. Writes summary.json / results.jsonl /
attempts/ into the artifacts directory. See ENVIRONMENT.md for the flags and the
output layout.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

EVAL_DIR = Path(__file__).resolve().parent
RUN_DIR = EVAL_DIR.parent
# The edit surface, as the environment declared it at setup. The evaluation always
# runs THIS directory — there is no way to aim it at a copy, so what gets measured
# is always the agent as it will actually run, at the path where it works.
TARGET_DIR = RUN_DIR / (RUN_DIR / ".target").read_text().strip()
PER_ATTEMPT_TIMEOUT_S = 300


def normalize(s: str) -> str:
    """Light normalization: case, whitespace, trailing period, surrounding quotes."""
    s = s.strip().strip('"').strip("'").strip()
    s = re.sub(r"\s+", " ", s)
    return s.rstrip(".").strip().lower()


def load_questions(split: str, wanted: str) -> list[dict]:
    path = EVAL_DIR / "questions" / f"{split}.jsonl"
    if not path.exists():
        sys.exit(f"unknown split {split!r} (no {path})")
    qs = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    if wanted != "all":
        ids = [q.strip() for q in wanted.split(",") if q.strip()]
        by_id = {q["id"]: q for q in qs}
        missing = [i for i in ids if i not in by_id]
        if missing:
            sys.exit(
                f"unknown question ids in --questions: {', '.join(missing)}\n"
                f"available in split {split!r}: {', '.join(by_id)}"
            )
        qs = [by_id[i] for i in ids]
    return qs


def run_one(agent: Path, question: dict, attempt: int, attempts_dir: Path) -> dict:
    d = attempts_dir / question["id"] / str(attempt)
    d.mkdir(parents=True, exist_ok=True)
    q_file, a_file = d / "question.txt", d / "answer.txt"
    q_file.write_text(question["question"] + "\n")

    t0 = time.time()
    error = ""
    try:
        proc = subprocess.run(
            [sys.executable, str(agent), str(q_file), str(a_file)],
            capture_output=True,
            text=True,
            timeout=PER_ATTEMPT_TIMEOUT_S,
            cwd=str(agent.parent),
        )
        (d / "stdout.log").write_text(proc.stdout)
        (d / "stderr.log").write_text(proc.stderr)
        if proc.returncode != 0:
            error = f"agent exited {proc.returncode}"
    except subprocess.TimeoutExpired:
        error = f"timeout after {PER_ATTEMPT_TIMEOUT_S}s"
        (d / "stderr.log").write_text(error + "\n")

    answer = a_file.read_text() if a_file.exists() else ""
    correct = bool(answer) and normalize(answer) == normalize(question["answer"])
    return {
        "id": question["id"],
        "attempt": attempt,
        "question": question["question"],
        "answer": answer.strip(),
        "expected": question["answer"],
        "correct": correct,
        "seconds": round(time.time() - t0, 1),
        "error": error,
        "dir": str(d),
    }


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--artifacts", required=True)
    p.add_argument("--questions", default="all")
    p.add_argument("--attempts", type=int, default=1)
    p.add_argument("--concurrency", type=int, default=8)
    p.add_argument("--split", default="train")
    args = p.parse_args()

    agent = TARGET_DIR / "agent.py"
    if not agent.exists():
        sys.exit(f"no agent.py in {TARGET_DIR}")

    artifacts = Path(args.artifacts).resolve()
    attempts_dir = artifacts / "attempts"
    attempts_dir.mkdir(parents=True, exist_ok=True)

    questions = load_questions(args.split, args.questions)
    jobs = [(q, a) for q in questions for a in range(1, args.attempts + 1)]
    print(
        f"[eval] {len(questions)} questions x {args.attempts} attempts "
        f"= {len(jobs)} runs, concurrency {args.concurrency}, split {args.split}",
        flush=True,
    )

    t0 = time.time()
    with ThreadPoolExecutor(max_workers=max(1, args.concurrency)) as pool:
        futures = [
            pool.submit(run_one, agent, q, a, attempts_dir) for q, a in jobs
        ]
        rows = []
        for i, f in enumerate(futures, 1):
            row = f.result()
            rows.append(row)
            mark = "PASS" if row["correct"] else "FAIL"
            print(
                f"[eval] {i}/{len(jobs)} {mark} {row['id']} #{row['attempt']} "
                f"({row['seconds']}s) got={row['answer'][:40]!r} "
                f"want={row['expected']!r}{' ' + row['error'] if row['error'] else ''}",
                flush=True,
            )

    rows.sort(key=lambda r: (r["id"], r["attempt"]))
    with (artifacts / "results.jsonl").open("w") as f:
        for row in rows:
            f.write(json.dumps(row) + "\n")

    per_question: dict[str, list[int]] = {}
    for row in rows:
        got, total = per_question.setdefault(row["id"], [0, 0])
        per_question[row["id"]] = [got + int(row["correct"]), total + 1]

    n_correct = sum(r["correct"] for r in rows)
    metric = n_correct / len(rows) if rows else 0.0
    summary = {
        "metric": round(metric, 4),
        "n_tasks": len(questions),
        "n_attempts": args.attempts,
        "detail": {
            "n_correct": n_correct,
            "n_runs": len(rows),
            "split": args.split,
            "target": str(TARGET_DIR),
            "seconds": round(time.time() - t0, 1),
            "n_errors": sum(1 for r in rows if r["error"]),
            "per_question": per_question,
            "solved_always": sorted(k for k, (c, n) in per_question.items() if c == n),
            "solved_never": sorted(k for k, (c, n) in per_question.items() if c == 0),
        },
    }
    (artifacts / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(f"[eval] metric={summary['metric']} ({n_correct}/{len(rows)}) -> {artifacts}/summary.json")


if __name__ == "__main__":
    main()
