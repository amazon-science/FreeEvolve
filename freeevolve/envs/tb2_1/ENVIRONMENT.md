# Environment: terminal-bench 2.1

## Goal

Improve the terminus-2 terminal agent so it resolves more terminal-bench 2.1
tasks.

Each task puts the agent in a Docker container with a terminal and a written
problem — build something, fix something, recover something. The agent drives a
tmux session: it issues shell commands, reads what comes back, and decides when it
is finished. Once it stops, a pytest suite runs inside the container and grades
what it left behind.

## The model capability

The agent runs on a fixed model at fixed sampling and reasoning settings, listed in
`eval/defaults.env`, and those stay as they are: the model, the temperature,
`reasoning_effort`, `max_thinking_tokens`, the backend, interleaved thinking, and
any route to them through `llm_kwargs` or a per-call override.

Changing them does not make the agent better, it makes the agent *bigger*. Buying
more inference per attempt moves the score without teaching anything about how to
build a better agent, and that is the improvement this environment is not asking
for. `run.sh` passes these itself, so they are not flags, and it refuses to
evaluate an edit that changes a line mentioning one of them — bluntly, so a
reflowed docstring that merely names `temperature` is refused too. The message says
which line.

Everything about how the agent *uses* the capability it has is yours: the prompt
templates, how it parses replies, how it drives and reads the terminal, how it
recovers from a hung command or an unparseable reply, when it summarizes its own
context, when it decides a task is done.

The agent is sampled rather than greedy, so repeated evaluations of the same agent
differ. That is a property of this setup, not a defect to remove.

## Key metric

**The fraction of task-attempts resolved.** A task resolves only when its entire
pytest suite passes. That is the benchmark's own measure and the reward here.

One intermediate signal is worth naming, because it is much the sharper instrument.
Each task is graded by a suite of several named tests, recorded individually in
every trial's `verifier/ctrf.json`. The resolved fraction cannot see a task going
from 2 of 9 tests to 8 of 9; a mean per-test fraction can, and across this task set
it carries roughly half the run-to-run noise of the resolved fraction. It is not
the reward — a change that lifts test counts without completing a suite has
resolved nothing — but it is what lets you tell a real change from a lucky draw,
and computing it is a few lines over the trial directories.

Nothing else is computed for you. Every other view — per task, per subset, across
runs — is yours to derive.

## Edit surface

`agent/terminus_2/` — the terminus-2 agent: its control loop, prompt templates,
response parsers, tmux session handling, and context summarization.

This is what the evaluation runs, always: edit it in place. Keep the directory
where it is and keep its name — harbor imports the agent as
`terminus_2.terminus_2:Terminus2`, so `agent/` is the import root and the package
must stay `terminus_2`. `run.sh` refuses to run if it was renamed. Copies kept
elsewhere are not evaluated.

Read-only, outside it: the task definitions, the container images, the pytest
suites, and the verifier.

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

The terminal-bench 2.1 tasks listed by id in `eval/defaults.env`. One,
`extract-moves-from-video`, is excluded from every run — its failure mode is about the
task rather than the agent. `all` means the ids listed there.

Every task there is visible and every one is measured; there is no held-out split inside
this run. An improvement measured on the same tasks it was built against is measured on
its training set, and this environment cannot tell you whether it generalizes.

### Concurrency

**Total concurrency at or under 24.** The ceiling is the node, not the command: it
covers every container running at once, across however many evaluations are in
flight. Nothing enforces it. Past roughly 24 these containers start failing on
container-start and command timeouts rather than on anything the agent did.

Everything up to that ceiling is yours, and the wall clock above is spent whether or
not you are using it. **The default of 8 is not the fast setting**. Nor is the ceiling a per-command limit:
it is a budget for the node to divide as you like — one evaluation at 24, two at 12,
three at 8 — and an evaluation does not have to wait for the one before it to finish. Two
running together cost the same containers as two running in sequence and half the
clock.

The first evaluation on a fresh machine also pays a one-time image pull per task it
touches. Across 88 images that is substantial, and it is paid once per machine
rather than once per evaluation.

## Where the results appear

Inside the `--artifacts` directory:

```
harbor.log        the harness's own log
job/              harbor's output — a symlink to the job directory it named
  result.json     the aggregate, described below
  <trial>/result.json           per-trial outcome and config; the binary reward is
                                at verifier_result.rewards.reward
  <trial>/verifier/ctrf.json    per-test results: which named tests passed
  <trial>/agent/                the agent's own logs and terminal recording
  <trial>/trial.log             the trial's driver log
```

One trial directory per task-attempt, named `<task-id>__<suffix>`, so a task run
several times has several of them.

`job/result.json` holds:

```
stats.evals.<eval>.metrics[0].mean   the fraction of attempts that resolved
stats.evals.<eval>.reward_stats      which trial got which reward, by trial id
stats.evals.<eval>.n_trials          attempts that produced a reward
stats.evals.<eval>.n_errors          attempts that raised
stats.evals.<eval>.exception_stats   which trials those were, by type and trial id
stats.cost_usd                       what the evaluation spent
```

**The record of an evaluation is its job directory.** Nothing is derived and no
index is written, so there is no summary that could disagree with the trials
underneath it — and an evaluation you run some other way, calling harbor yourself
to compare two agents in one wall-clock window, leaves a record of the same kind.
Read job directories rather than looking for a file that lists them.

The terminal recording and logs under `<trial>/agent/` are where a failure's cause
is legible: the reward says an attempt failed, not what the agent did wrong.
`verifier/ctrf.json` says *which* tests failed, by name, which is usually the
fastest route from a score to a mechanism.

### Attempts that raise

An attempt can fail without measuring the agent — an image that will not pull, a
container that does not start in time, a verifier that never finishes — and **the
reported mean counts every one of them as zero**. So an evaluation with errors
reports a number lower than the agent earned, by an amount proportional to the
error count rather than to anything the agent did. `reward_stats` lists which trials
scored what, so a mean over only the attempts that produced a reward is a few lines
away.

`AgentTimeoutError` is the most common exception here and is not one of these: when
the agent runs out of time the verifier still grades the state it left, so the
attempt has a real reward and belongs in the score. Check `exception_stats` before
treating `n_errors` as lost data. "Never finished" and "finished wrong" are
different problems with different fixes, and only the exception type tells you
which you have.

Errors cluster in time rather than in tasks — container starts fail when the machine
is busy, so they arrive in bursts and the same task fails in one evaluation and runs
clean in the next. A burst also contaminates the attempts that survive it: the
contention that kills one container slows the others, so those attempts complete and
are scored on a run the machine spoiled. A high `n_errors` is a verdict on the
evaluation, not just a smaller sample.

One more thing to check rather than assume: a task that fails at the verifier
produces no reward at all, and nothing warns you if a particular task does that in
*every* evaluation. It is then missing from every per-task view you build while
still being in the task list. Compare the task ids in `reward_stats` against the
list you asked for before trusting two numbers to share a denominator.
