# Environment: dummy

A cheap, fast environment for exercising the loop end to end. Each evaluation
takes a couple of minutes and costs cents.

## Goal

Improve a small question-answering agent so it answers more questions
correctly.

The agent is given one question at a time and must produce one answer. It is
graded by exact match against a reference answer, after light normalization
(case, surrounding whitespace, and a trailing period are ignored).

The questions are short but adversarial: counting inside strings, multi-step
arithmetic, ordering, and instruction-following traps of the kind that a model
answering off the cuff gets wrong and a model that works carefully gets right.

## Key metric

`metric` in `summary.json`: the fraction of question-attempts answered
correctly, averaged over all questions and attempts. Higher is better.

## Edit surface

`target/` — the agent. This is what the evaluation runs, always: edit it in place,
and leave the directory where it is.

- `agent.py` is the entry point. It is called as
  `python agent.py <question_file> <answer_file>` and must write its final
  answer to `<answer_file>`. Anything else it writes to stdout/stderr is
  captured as a trace.
- It may call a model through the `claude` CLI, which is on PATH. It may add
  files, split itself into modules, or restructure however it likes, as long as
  `agent.py` keeps that command-line contract.
- Each invocation gets 300 seconds of wall clock.

## How to evaluate

```
./run.sh --artifacts <dir> [options]
```

The evaluation always runs `target/` — the path this environment declared for its
edit surface, recorded in `.target` at the run root. There is no flag to point it
somewhere else, so what gets measured is always the agent as it will actually run,
at the path where it runs.

Copies of `target/` kept elsewhere are not evaluated. Only what is at `target/`
is.

Options:

| flag | meaning | default |
| --- | --- | --- |
| `--artifacts <dir>` | where to write evidence (required) | |
| `--questions <ids>` | comma-separated question ids, or `all` | `all` |
| `--attempts <n>` | how many times to run each question | 1 |
| `--concurrency <n>` | question-attempts run in parallel | 8 |
| `--split <name>` | `train` (20 questions) or `test` (20 held out) | `train` |

`train` and `test` are disjoint sets of questions drawn from the same generators.
`test` is held out: nothing evaluates it unless you ask for it.

Concurrent invocations with different `--artifacts` directories are safe.

### System

**Total concurrency at or under 32.** The ceiling is the node, not the command:
it covers every question-attempt running at once, across however many evaluations
are in flight. Nothing enforces it. Past the ceiling, attempts contend and start
timing out.

## Where the results appear

Inside the `--artifacts` directory:

```
summary.json          {"metric": ..., "n_tasks": ..., "n_attempts": ..., "detail": {...}}
results.jsonl         one row per question-attempt: id, attempt, answer,
                      expected, correct, seconds
attempts/<id>/<n>/    question.txt, answer.txt, stdout.log, stderr.log
```

`summary.json.detail.per_question` maps each question id to how many of its
attempts were correct, e.g. `"count-chars": [0, 3]` meaning 0 correct out of 3.
