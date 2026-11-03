# Environment: tau3-bench

## Goal

Improve the tau3-bench customer-service agent so it resolves more of its users'
requests correctly.

Each task is a conversation. The agent talks turn by turn with a simulated user
who wants something done — change a flight, return an order, fix a phone that
won't connect, answer a question about a bank's policies. The agent has a set of
domain tools it calls through an MCP runtime, and a written domain policy it is
required to follow. When the conversation ends, a grader checks whether the
required tool actions were actually taken and the required information was
actually communicated.

The domain here is `banking_knowledge`: the user asks about a bank's products and
policies, and the agent has to retrieve the relevant passages and answer from
them.

## Fixed: the model capability

The agent runs on a fixed model, at a fixed reasoning effort — `medium`, set by
`DEFAULT_REASONING_EFFORT` in both agent files — and with a fixed per-call output
budget of 16384 tokens, set by `DEFAULT_MAX_TOKENS` in `run_tau3_llm_agent.py`.
**Hold these constant.** Do not raise them, lower them, remove them, or route
around them (by env var, by `llm_args`, by a per-call override, or by changing
which model is used). `run.sh` refuses to evaluate an edit that changes a line
setting one of them, and the message says which line.

This is the one part of the setup that is not yours to change, and the reason is
that changing it does not make the agent better — it makes the agent *bigger*.
Buying more inference per attempt, or a stronger model, moves the score without
teaching anything about how to build a better agent, and it is the improvement
this environment is explicitly not asking for.

Two facts about that output budget, because one budget serves two purposes: the
model's reasoning and its reply are both drawn from the same 16384 tokens, and a
reply that reaches the end of them stops there rather than raising — the turn
arrives truncated, and nothing in the logs records that it was.

Because extended thinking requires `temperature=1.0`, the agent is sampled rather
than greedy: repeated evaluations of the *same* agent differ. That variance is a
property of this setup, not a defect to remove.

This installed evolution environment contains one set of 68 such tasks, listed
in `eval/defaults.env`. The repository records a separate held-out split for
offline reporting, but setup excludes those tasks and their identifiers from
the run directory, so they are not available to the evolver.

## Key metric

The fraction of task-attempts that pass, on the task set above. The reward is
binary per attempt — the grader either finds every required action and
communication, or it does not.

The harness reports this itself, in `job/result.json`:

```
stats.evals.<eval>.metrics[0].mean   the fraction of attempts that passed
stats.evals.<eval>.reward_stats      which trial got which reward, by trial id
stats.evals.<eval>.pass_at_k         pass@k, when more than one attempt was run
stats.evals.<eval>.n_trials          attempts that completed
stats.evals.<eval>.n_errors          attempts that raised instead of scoring
stats.evals.<eval>.exception_stats   which trials those were, by trial id and type
stats.cost_usd                       what the evaluation spent
```

Nothing is computed on top of that. Any other view of a run — per task, per
subset, across runs — is yours to derive from `job/`, which holds every trial.

### Errored trials

A trial can fail without measuring the agent: a container that does not start in
time, a provider that refuses the call, a package index that answers 502 during an
image build. `n_errors` counts those and `exception_stats` names them.

Two facts about them:

**The reported mean includes them as zeros.** A trial that raised is recorded at
reward 0 and divided into `metrics[0].mean` alongside the trials that ran. So an
evaluation with errors reports a number lower than the agent earned, and the
shortfall is proportional to the error count rather than to anything the agent did.
An evaluation whose errors are a large fraction of its trials is reporting a failure
rate wearing the costume of a score.

**They cluster in time rather than in tasks.** Container starts and provider calls
fail when the machine or the provider is busy, so errors arrive in bursts and the
same task errors in one evaluation and runs clean in the next. They are a property
of the moment, not of the agent or the task.

So an errored trial is missing data, not a zero the agent earned, and a burst of
them does not have to cost the whole evaluation: `exception_stats` names the trials
that raised, and `--tasks` takes exactly that kind of list, so the tasks a burst hit
can be evaluated again on their own. Whether to re-run them, and what to do with the
two sets of results afterwards — pool them, let the later one stand, discard both —
is yours.

## Edit surface

`agent/tau3_agent/` — the agent, two files:

- `tau3_llm_agent.py` — the harbor shim: how the agent is constructed and
  launched.
- `run_tau3_llm_agent.py` — the conversation loop that runs inside the
  container: the system prompt, how tool calls are made and parsed, how errors
  and retries are handled, when the conversation is ended.

This is what the evaluation runs, always: edit it in place.

Leave the directory where it is and keep its name. harbor imports the agent as
`tau3_llm_agent:Tau3LLMAgent`, so `agent/tau3_agent` is the import root and the
module names must not change. `run.sh` refuses to run if the entry module is
missing.

Read-only, outside the edit surface: the task data, the domain policies, the MCP
tool implementations, and the grader.

Inside the edit surface but fixed: `DEFAULT_REASONING_EFFORT`, `DEFAULT_MAX_TOKENS`,
and anything else that would change the model or how much inference it buys per
attempt. See "Fixed: the model capability" above.

## How to evaluate

```
./run.sh --artifacts <dir> [options]
```

The evaluation always runs `agent/tau3_agent/` — the path this environment
declared for its edit surface, recorded in `.target` at the run root.

Copies kept elsewhere are not evaluated. Only what is at `agent/tau3_agent/` is.

Options:

| flag | meaning | default |
| --- | --- | --- |
| `--artifacts <dir>` | where to write evidence (required) | |
| `--tasks <ids>` | comma-separated task ids, or `all` for the whole set | `all` |
| `--attempts <n>` | how many times to run each task | 1 |
| `--concurrency <n>` | task-attempts run in parallel | 8 |
| `--model <id>` | model the agent runs on | see `defaults.env` |
| `--user-model <id>` | model that plays the simulated user | see `defaults.env` |
| `--timeout <s>` | wall-clock cap for the whole evaluation | none |

So an evaluation is any number of tasks from the set, run any number of times
each. `all` at one attempt is 68 task-attempts; a named subset at three attempts
is `3 x` that subset.

### Cost

A task attempt takes roughly 1 to 5 minutes of wall clock. Task-attempts run
`--concurrency` at a time, so an evaluation takes about
`ceil(tasks x attempts / concurrency)` batches of that.

The concurrency ceiling below is a budget for the node, not a per-command limit,
so it is yours to divide: one evaluation at 32, two at 16, four at 8 — the same
containers either way. Which shape to use is a question about what you are trying
to learn, not about capacity. The default of 8 is not the fast setting.

Every attempt spends model calls on three roles at once: the agent, the
simulated user, and the grader's judge. `job/result.json` records the total at
`stats.cost_usd`.

The first evaluation on a fresh machine also pays a one-time Docker image build
per task image, which can add tens of minutes.

Concurrent evaluations with different `--artifacts` directories are safe.

### System

**Total concurrency at or under 32.** The ceiling is the node, not the command:
it covers every container running at once, across however many evaluations are
in flight. Nothing enforces it.

Each task-attempt runs two containers — the task environment and an MCP sidecar
— so a concurrency of `n` puts `2n` containers on the node.

### The task set

68 tasks from the `banking_knowledge` domain, listed by id in
`eval/defaults.env`.

## Where the results appear

Inside the `--artifacts` directory:

```
harbor.log        the harness's own log
job/              harbor's output — a symlink to the job directory it named
  result.json     the aggregate: the metric above, reward distribution by trial
                  id, token counts, cost
  <trial>/result.json    per-trial outcome, reward, and config. The reward is at
                         verifier_result.rewards.reward
  <trial>/agent/         the agent's own logs
  <trial>/artifacts/     the conversation transcript and tool calls
  <trial>/verifier/      the grader's output: which checks passed
  <trial>/trial.log      the trial's driver log
```

One trial directory per task-attempt, named `<task-id>__<suffix>`, so a task run
several times has several of them.

The transcripts under `<trial>/artifacts/` are where a failure's cause is legible:
the reward says an attempt failed, not what the agent did wrong.
