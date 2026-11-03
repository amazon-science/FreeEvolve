# Environment: terminal-bench 2.1 (deepagents harness)

## Goal

Improve the deepagents harness so it resolves more terminal-bench 2.1 tasks.

Each task puts an agent in a Docker container with a terminal and a written problem —
build something, fix something, recover something. Once the agent stops, a pytest suite
runs inside the container and grades what it left behind.

## The system

The agent is [deepagents](https://github.com/langchain-ai/deepagents): its loop lives
inside LangGraph, and the harness is the file that configures it. `build_agent(model,
backend)` is handed a model and an execution backend and returns a compiled agent; what
it does with them is the edit surface.

Three pieces stand around it, in `eval/adapter/`:

- `harbor_agent.py` — harbor's agent class. It loads the harness file, builds the model,
  constructs the backend, and calls `build_agent(model, backend)`, then invokes the
  returned agent once with the task instruction.
- `harbor_sandbox.py` — the backend. It is deepagents' sandbox protocol implemented over
  harbor's container, so the agent's shell commands and file operations run inside the
  task's container rather than on the host.
- `bedrock.py` — the model builder. It returns a `ChatBedrockConverse` for the model id
  in `eval/defaults.env`.

The harness runs in the harbor process on the host; only the commands it issues run in
the container.

deepagents supplies built-in tools without configuration: `write_todos`; `ls`,
`read_file`, `write_file`, `edit_file`, `glob`, `grep`; `execute` (shell, via the
backend); `task` (subagents). Its configuration surfaces are the system prompt, extra
tools, subagents, skills, memory, middleware, and the arguments to `create_deep_agent`.

## The model capability

The harness runs on a fixed model with a fixed per-call output cap, both in
`eval/defaults.env`:

- the model id,
- `DEFAULT_MAX_OUTPUT_TOKENS` — the per-call output cap, in tokens. `run.sh` exports it
  as `DEEPAGENTS_MAX_TOKENS`; `harbor_agent.py` passes it to `bedrock.build_model`, which
  passes it to `ChatBedrockConverse(max_tokens=...)`, i.e. Bedrock Converse's
  `inferenceConfig.maxTokens` on every request. Claude extended thinking is on, and
  thinking tokens are billed against this same per-call budget as the tool call and the
  final text.

Temperature is not passed: `bedrock.py` drops an explicit temperature whenever Claude
extended thinking is active, because the model requires its default there.

The same harness scores differently under a different model or a different output cap, so
two evaluations run under different ones do not measure the same thing. `run.sh` passes
both itself — they are not flags — and it refuses to evaluate when a changed line in the
edit surface matches one of the names in `CAPABILITY_KNOBS`, which covers the output cap,
the thinking budget, the sampling parameters, the model id, and the constructors that
would build a different model. The check is a case-insensitive text match on the diff, so
an edit to a line that merely names one of them — a reflowed docstring — is refused too;
the message prints the line. `run.sh` also refuses if `eval/defaults.env` itself has
changed since setup.

Everything about how the harness *uses* the model it is handed is in scope.

The model is sampled rather than greedy, so repeated evaluations of the same harness
differ.

## Key metric

**The fraction of task-attempts resolved.** A task resolves only when its entire pytest
suite passes. That is the benchmark's own measure and the reward here.

Each task is also graded by a suite of several named tests, recorded individually in
every trial's `verifier/ctrf.json`.

Nothing else is computed. Every other view — per task, per subset, across runs — is
yours to derive.

## Edit surface

`agent/harness.py` — the deepagents harness.

This is the file the evaluation loads, always: edit it in place. Copies kept elsewhere
are not evaluated. It must define `build_agent(model, backend)`. Extra modules may be
added beside it; `run.sh`'s capability check reads them too.

Read-only, outside it: `eval/adapter/` (the harbor agent class, the sandbox backend, the
model builder), `eval/defaults.env`, the task definitions, the container images, the
pytest suites, and the verifier.

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

An evaluation is any number of tasks from the set, run any number of times each.
Concurrent evaluations with different `--artifacts` directories are safe.

### The task set

The terminal-bench 2.1 tasks listed by id in `eval/defaults.env`. One,
`extract-moves-from-video`, is excluded from every run — its failure mode is about the
task rather than the agent. `all` means the ids listed there.

Every task there is visible and every one is measured; there is no held-out split inside
this run. An improvement measured on the same tasks it was built against is measured on
its training set, and this environment cannot tell you whether it generalizes.

### Concurrency

`MAX_CONCURRENCY` in `eval/defaults.env` is a ceiling `run.sh` enforces on
`--concurrency`. It is per invocation; the number of containers on the node is the sum
across every evaluation in flight. Above roughly that number, containers start failing on
container-start and command timeouts, and Bedrock throttles, for reasons that are not
about the agent.

The first evaluation on a fresh machine pays a one-time image pull per task it touches.
That is paid once per machine rather than once per evaluation.

## Where the results appear

Inside the `--artifacts` directory:

```
harbor.log        the harness's own log
job/              harbor's output — a symlink to the job directory it named
  result.json     the aggregate, described below
  <trial>/result.json               per-trial outcome and config; the binary reward is
                                    at verifier_result.rewards.reward
  <trial>/verifier/ctrf.json        per-test results: which named tests passed
  <trial>/agent/model_config.json   the model id, region and output cap the trial built
  <trial>/agent/trajectory.json     every message of the run, with tool calls
  <trial>/trial.log                 the trial's driver log
```

One trial directory per task-attempt, named `<task-id>__<suffix>`, so a task run several
times has several of them.

`job/result.json` holds:

```
stats.evals.<eval>.metrics[0].mean   the fraction of attempts that resolved
stats.evals.<eval>.reward_stats      which trial got which reward, by trial id
stats.evals.<eval>.n_trials          attempts that produced a reward
stats.evals.<eval>.n_errors          attempts that raised
stats.evals.<eval>.exception_stats   which trials those were, by type and trial id
stats.cost_usd                       what the evaluation spent
```

**The record of an evaluation is its job directory.** Nothing is derived and no index is
written, so there is no summary that could disagree with the trials underneath it — and
an evaluation run some other way, calling harbor directly, leaves a record of the same
kind. Read job directories rather than looking for a file that lists them.

`trajectory.json` and the logs under `<trial>/agent/` are where a failure's cause is
legible: the reward says an attempt failed, not what the agent did wrong.
`verifier/ctrf.json` says *which* tests failed, by name.

### Attempts that raise

An attempt can fail without measuring the agent — an image that will not pull, a
container that does not start in time, a verifier that never finishes — and **the
reported mean counts every one of them as zero**. So an evaluation with errors reports a
number lower than the agent earned. `reward_stats` lists which trials scored what.

`AgentTimeoutError` is not one of these: when the agent runs out of time the verifier
still grades the state it left, so the attempt has a real reward and belongs in the
score. `exception_stats` gives the type of every error, and "never finished" and
"finished wrong" are different problems.

Container-start errors cluster in time rather than in tasks: they arrive when the machine
is busy, so the same task fails in one evaluation and runs clean in the next. The
contention that kills one container also slows the others, so attempts that survive a
burst were scored on a machine under load.

A task that fails at the verifier produces no reward at all, and nothing warns you if a
particular task does that in every evaluation; it is then absent from `reward_stats`
while still being in the task list.
