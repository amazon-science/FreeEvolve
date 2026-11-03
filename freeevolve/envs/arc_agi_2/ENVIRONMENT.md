# Environment: ARC-AGI-2

## Goal

Improve the puzzle agent so it solves more ARC-AGI-2 puzzles.

Each task shows a handful of input/output grid pairs that demonstrate one
transformation, then gives a test input grid. The transformation is different in
every puzzle and is not described anywhere. The agent works in a container and
leaves its answer — the transformed test grid — as JSON at `/testbed/output.json`.

The verifier compares that file with the expected grid **exactly**: same number of
rows, same number of columns in every row, same value in every cell. No model is
involved in grading, and there is no partial credit.

## Fixed: the model capability

The agent runs on a fixed model, at a fixed reasoning effort — `medium` — and with a
fixed per-call output budget of 16384 tokens, both set as `DEFAULT_REASONING_EFFORT`
and `DEFAULT_MAX_TOKENS` in each agent file. **Hold these constant.** Do not raise
them, lower them, remove them, or route around them (by env var, by a per-call
override, by a second model, or by changing which model is used). `run.sh` refuses to
evaluate an edit that changes a line setting one of them, and says which line.

The reason is that changing them does not make the agent better — it makes the agent
*bigger*. Buying more inference per attempt, or a stronger model, moves the score
without teaching anything about how to build a better agent, and that is the
improvement this environment is not asking for.

Everything about how the agent *uses* the capability it has is in scope: what it is
told, how the grids are presented to it, what it does with the container, how many
steps it takes and what it does with each, how it decides it is finished, and what it
leaves behind.

Because extended thinking requires `temperature=1.0`, the agent is sampled rather
than greedy: repeated attempts at the same puzzle differ. That variance is a property
of this setup, not a defect to remove.

The model's reasoning and its reply are drawn from the same 16384-token budget per
call, and a reply that reaches the end of it stops there. Each attempt records the
per-call `finish_reasons` in `<trial>/agent/arc-agent-summary.json`.

## Key metric

**The fraction of task-attempts solved.** The verifier's verdict is binary per
attempt: the grid matches or it does not.

The harness reports it in `job/result.json`:

```
stats.evals.<eval>.metrics[0].mean   the fraction of attempts that solved
stats.evals.<eval>.reward_stats      which trial got which reward, by trial id
stats.evals.<eval>.pass_at_k         pass@k, when more than one attempt was run
stats.evals.<eval>.n_trials          attempts that produced a reward
stats.evals.<eval>.n_errors          attempts that raised instead of scoring
stats.evals.<eval>.exception_stats   which trials those were, by type and trial id
stats.cost_usd                       what the evaluation spent
```

Nothing is computed on top of that. Every other view — per puzzle, per attempt count,
across evaluations — is yours to derive from `job/`, which holds every trial.

The published benchmark reports **pass@2**: two attempts per puzzle, solved if either
succeeds. `--attempts 2` reproduces that shape, and `pass_at_k` in the result carries
it. A single-attempt evaluation is a different and stricter number; both are useful
and they are not comparable to each other.

One distinction the mean cannot see, recorded per attempt in
`<trial>/agent/arc-agent-summary.json`: whether the agent **wrote an answer at all**
(`metadata.output_written`, `metadata.output_bytes`). An attempt that never wrote the
file and an attempt that wrote a wrong grid both score zero, and only that field tells
them apart.

## Edit surface

`agent/arc_agent/` — the agent, two files:

- `arc_agent.py` — the harbor shim: how the agent is installed, how the puzzle text
  gets into the container, and how the runner is launched.
- `run_arc_agent.py` — what runs inside the container: what the model is told, the
  loop, the tool it has, and what happens to the output of each command.

This is what the evaluation runs, always: edit it in place. Keep the directory where
it is and keep its name — harbor imports the agent as `arc_agent:ARCAgent`, so
`agent/arc_agent` is the import root and the module names must not change. `run.sh`
refuses to run if the entry module is missing. Copies kept elsewhere are not
evaluated.

Read-only, outside it: the puzzles, the expected grids, and the verifier.

Inside the edit surface but fixed: `DEFAULT_MAX_TOKENS`, `DEFAULT_REASONING_EFFORT`,
and anything else that would change the model or how much inference it buys per
attempt.

### The expected grids are on this disk

Each puzzle carries its expected output at
`eval/datasets/arc_agi_2/<task>/tests/expected.json`, and again under `solution/`,
because the verifier reads it at grading time. It is the verifier's input, not the
agent's. An agent that reads it has solved nothing, and every number the run reports
afterwards would be measuring nothing.

`run.sh` therefore refuses to evaluate an edit surface that names those paths or the
dataset directory, or that contains an expected grid verbatim (compared with
whitespace collapsed). The check is mechanical and cannot be complete; the boundary is
the point rather than the check.

At run time the puzzle is the only thing the agent's container holds: the instruction
is written into `/testbed/instruction.md` and the working directory is `/testbed`,
while `tests/` and `solution/` are given to the verifier's container instead. So an
expected grid cannot be read while solving. It can only be carried in, by an edit made
before the evaluation starts.

## What the container has

The task image is `python:3.11-slim` with `curl` and `uv`, plus the agent's own client
installed at agent-install time. **That is all it has** — the standard library, but no
numpy, no scipy, nothing scientific. The container has outbound network, `uv` is on
the path, and the agent runs as a normal process with a shell.

The working directory is `/testbed`. The answer goes to `/testbed/output.json` as a
JSON 2D array of integers.

## How to evaluate

```
./run.sh --artifacts <dir> [options]
```

| flag | meaning | default |
| --- | --- | --- |
| `--artifacts <dir>` | where to write evidence (required) | |
| `--tasks <ids>` | comma-separated task ids, or `all` | `all` |
| `--attempts <n>` | how many times to run each puzzle | 1 |
| `--concurrency <n>` | task-attempts run in parallel | 8 |
| `--timeout <s>` | wall-clock cap for the whole evaluation | none |

So an evaluation is any number of puzzles from the set, run any number of times each.
Concurrent evaluations with different `--artifacts` directories are safe.

### The task set

The puzzles generated into `eval/datasets/arc_agi_2/`, one directory each, drawn from
the public evaluation split. Puzzles with several test inputs become several tasks
(`<puzzle>_0`, `<puzzle>_1`, …), so task count and puzzle count are not the same
number.

Every task there is visible and every one is measured; there is no held-out split
inside this run. An improvement measured on the same puzzles it was built against is
measured on its training set, and this environment cannot tell you whether it
generalizes.

### Cost and time

Each task-attempt is one container with **1 CPU and 1 GB of memory**, so a program the
agent writes has one core and a gigabyte to work in. Attempts run `--concurrency` at a
time.

The agent is given **1800 seconds** per attempt, the verifier 60. When the agent's time
runs out, whatever is at `/testbed/output.json` is what gets graded, and if nothing is
there the attempt scores zero.

**Total concurrency at or under 48.** The ceiling is the node, not the command: it
covers every container running at once, across however many evaluations are in flight.
Nothing enforces it. The default of 8 is not the fast setting — the node has 192 CPUs
and 373 GB, and an evaluation of 334 attempts has been run at `--concurrency 40` with
one provider error in 334. Attempts are latency-bound rather than CPU-bound, so raising
this is close to free until the model provider starts refusing calls; watch
`n_errors` and `exception_stats` for `ApiOverloadedError` and back off if they climb.

The first evaluation on a fresh machine also pays a one-time image build.

## Where the results appear

Inside the `--artifacts` directory:

```
harbor.log        the harness's own log
job/              harbor's output — a symlink to the job directory it named
  result.json     the aggregate, described above
  <trial>/result.json             per-trial outcome and config; the reward is at
                                  verifier_result.rewards.reward
  <trial>/agent/arc-agent.txt     the runner's own stdout
  <trial>/agent/arc-agent-summary.json     steps used, stop reason, finish reasons,
                                           whether an answer was written
  <trial>/agent/arc-agent-transcript.json  every message and command of the attempt
  <trial>/verifier/test-stdout.txt         the verifier's output
  <trial>/trial.log               the trial's driver log
```

One trial directory per task-attempt, named `<task-id>__<suffix>`, so a puzzle run
several times has several of them.

The transcript is where a failure becomes legible: the reward says an attempt failed,
not whether the agent misread the transformation, wrote a malformed grid, ran out of
steps, or never answered.

### Attempts that raise

An attempt can fail without measuring the agent — an image that will not build, a
container that does not start in time — and **the reported mean counts every one of
them as zero**. So an evaluation with errors reports a number lower than the agent
earned, by an amount proportional to the error count rather than to anything the agent
did. `exception_stats` names the trials and their types, and `reward_stats` lists which
trials produced a reward, so a mean over only those is a few lines away.

`AgentTimeoutError` is not one of these: when the agent runs out of time the verifier
still grades whatever is at `/testbed/output.json`, so the attempt has a real reward
and belongs in the score. Check `exception_stats` before treating `n_errors` as lost
data.

Errors cluster in time rather than in tasks — container starts fail when the machine is
busy, so they arrive in bursts and the same task errors in one evaluation and runs
clean in the next. A burst also contaminates the attempts that survive it. A high
`n_errors` is a verdict on the evaluation, not just a smaller sample.
