# Environment: HLE (Humanity's Last Exam)

## Goal

Improve the answering agent so more of its answers are graded correct.

Each task is one question written by a subject expert — mathematics, physics,
chemistry, biology, linguistics, history, chess, and others — and some carry an
image the answer depends on. The agent runs in a container with the question, and
writes its answer to a file. A grader model then compares that answer with the
one the question's author supplied and returns correct or incorrect.

The questions are hard on purpose: the benchmark exists to be difficult for
frontier models, and most answers on most task sets are wrong.

## Fixed: the model capability

The agent runs on a fixed model, at a fixed reasoning effort — `medium` — and with
a fixed per-call output budget of 16384 tokens, both set as `DEFAULT_REASONING_EFFORT`
and `DEFAULT_MAX_TOKENS` in each agent file. **Hold these constant.** Do not raise
them, lower them, remove them, or route around them (by env var, by a per-call
override, by a second model, or by changing which model is used). `run.sh` refuses
to evaluate an edit that changes a line setting one of them, and says which line.

The reason is that changing them does not make the agent better — it makes the
agent *bigger*. Buying more inference per attempt, or a stronger model, moves the
score without teaching anything about how to build a better agent, and that is the
improvement this environment is not asking for.

Everything about how the agent *uses* the capability it has is in scope: what it is
told, how it approaches a question, what it does before committing to an answer,
how it handles a question it cannot finish, what it writes and in what shape.

Because extended thinking requires `temperature=1.0`, the agent is sampled rather
than greedy: repeated attempts at the same question differ. That variance is a
property of this setup, not a defect to remove.

Two facts about that output budget, because one budget serves two purposes. The
model's reasoning and its reply are drawn from the same 16384 tokens, and a reply
that reaches the end of them stops there rather than raising. On a hard question the
reasoning can consume the entire budget and leave nothing: the shipped agent has
been observed finishing with `finish_reason = "length"` and a response file of zero
characters, which the grader reads as no answer at all. Each attempt records that
outcome in `<trial>/agent/hle-agent-summary.json`, under `metadata.finish_reason`
and `metadata.response_chars`.

## Key metric

**The fraction of task-attempts graded correct.** The grader's verdict is binary
per attempt.

The harness reports it in `job/result.json`:

```
stats.evals.<eval>.metrics[0].mean   the fraction graded correct
stats.evals.<eval>.reward_stats      which trial got which reward, by trial id
stats.evals.<eval>.n_trials          attempts that produced a reward
stats.evals.<eval>.n_errors          attempts that raised instead of scoring
stats.evals.<eval>.exception_stats   which trials those were, by type and trial id
stats.cost_usd                       what the evaluation spent
```

Nothing is computed on top of that. Every other view — per subject, per attempt
count, across evaluations — is yours to derive from `job/`, which holds every
trial.

Two things the mean cannot see, both recorded per trial in
`<trial>/verifier/judgment.json`:

- **what the grader extracted as the answer** (`model_answer`), which is not always
  what the agent meant to say;
- **the confidence the agent stated**, which the grader records but does not score.

## Edit surface

`agent/hle_agent/` — the agent, two files:

- `hle_agent.py` — the harbor shim: how the agent is installed and launched.
- `run_hle_agent.py` — what runs inside the container: what the model is told, how
  the question and any image are presented, and what is written to the response
  file.

This is what the evaluation runs, always: edit it in place. Keep the directory
where it is and keep its name — harbor imports the agent as `hle_agent:HLEAgent`,
so `agent/hle_agent` is the import root and the module names must not change.
`run.sh` refuses to run if the entry module is missing. Copies kept elsewhere are
not evaluated.

Read-only, outside it: the questions, the graded answers, the grader, and the task
images.

Inside the edit surface but fixed: `DEFAULT_MAX_TOKENS`, `DEFAULT_REASONING_EFFORT`,
and anything else that would change the model or how much inference it buys per
attempt.

### The graded answers are on this disk

Each task carries the author's answer at `eval/datasets/hle/<task>/tests/answer.txt`,
because the grader reads it at grading time. It is the grader's input, not the
agent's. An agent that reads it has not answered anything, and every number the run
reports afterwards would be measuring nothing.

`run.sh` therefore refuses to evaluate an edit surface that names that path or the
dataset directory, or that contains a graded answer verbatim. The check is
mechanical and cannot be complete; the boundary is the point rather than the check.

At run time the question is the only thing the agent's container holds: the task's
`workspace/` becomes `/app`, while `tests/` — question, answer, grader — is given to
the verifier's container instead. So an answer cannot be read while answering. It can
only be carried in, by an edit made before the evaluation starts.

## What the container has

The task image is `python:3.11-slim` with the agent's own dependencies installed at
setup. The container has outbound network and the agent runs as a normal process in
it, so anything reachable from Python is reachable — the standard library, packages
that can be installed at run time, and the shell.

The response file is `/logs/agent/response.txt` and the grader reads only that
file. Its required shape is stated in each task's instruction, which the agent
reads at `/app/instruction.md`; an image, when there is one, sits beside it in
`/app`.

## How to evaluate

```
./run.sh --artifacts <dir> [options]
```

| flag | meaning | default |
| --- | --- | --- |
| `--artifacts <dir>` | where to write evidence (required) | |
| `--tasks <ids>` | comma-separated task ids, or `all` | `all` |
| `--attempts <n>` | how many times to run each task | 1 |
| `--concurrency <n>` | task-attempts run in parallel | 8 |
| `--timeout <s>` | wall-clock cap for the whole evaluation | none |

So an evaluation is any number of tasks from the set, run any number of times each.
Concurrent evaluations with different `--artifacts` directories are safe.

### The task set

The tasks generated into `eval/datasets/hle/`, one directory each. Every task there
is visible and every one is measured; there is no held-out split inside this run.
An improvement measured on the same questions it was built against is measured on
its training set, and this environment cannot tell you whether it generalizes.

Questions the run directory does not contain are simply absent — the benchmark has
2500 and only these were materialized.

### Cost and time

A task-attempt is one container, and it is cheap by the standards of an agent
benchmark: a single model call in the shipped agent, a few seconds of container
start, and a grader call afterwards. Attempts run `--concurrency` at a time.

Each attempt spends model calls on two roles: the agent and the grader.
`job/result.json` records the total at `stats.cost_usd`.

**Total concurrency at or under 24.** The ceiling is the node, not the command: it
covers every container running at once, across however many evaluations are in
flight. Nothing enforces it. The default of 8 is not the fast setting.

The first evaluation on a fresh machine also pays a one-time image build.

## Where the results appear

Inside the `--artifacts` directory:

```
harbor.log        the harness's own log
job/              harbor's output — a symlink to the job directory it named
  result.json     the aggregate, described above
  <trial>/result.json           per-trial outcome and config; the reward is at
                                verifier_result.rewards.reward
  <trial>/agent/response.txt    what was submitted
  <trial>/agent/hle-agent-*     the agent's own log, summary, and transcript
  <trial>/verifier/judgment.json  the grader's extraction, verdict, and reasoning
  <trial>/verifier/test-stdout.txt  the verifier's own output
  <trial>/trial.log             the trial's driver log
```

One trial directory per task-attempt, named `<task-id>__<suffix>`, so a task run
several times has several of them.

`judgment.json` is where a wrong answer becomes legible: the reward says an attempt
failed, not whether the agent was wrong, wrote something the grader could not
extract, or never answered.

### Attempts that raise

An attempt can fail without measuring the agent — an image that will not build, a
container that does not start in time, a grader call that never returns — and **the
reported mean counts every one of them as zero**. So an evaluation with errors
reports a number lower than the agent earned, by an amount proportional to the
error count rather than to anything the agent did. `exception_stats` names the
trials and their types, and `reward_stats` lists which trials produced a reward, so
a mean over only those is a few lines away.

Two failure modes are worth telling apart from a wrong answer:

**`AgentTimeoutError`.** The agent ran past the task's own cap. Whatever it had
written by then is what gets graded, and if it had written nothing there is nothing
to grade.

**A grader that could not reach its model** raises rather than returning a verdict,
so the attempt has no reward at all rather than a reward of zero. Check
`exception_stats` before treating `n_errors` as lost data.

Errors cluster in time rather than in tasks — container starts and provider calls
fail when the machine or the provider is busy, so they arrive in bursts and the
same task errors in one evaluation and runs clean in the next. A burst also
contaminates the attempts that survive it. A high `n_errors` is a verdict on the
evaluation, not just a smaller sample.
