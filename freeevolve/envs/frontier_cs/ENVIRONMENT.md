# Environment: Frontier-CS (algorithmic track)

## Goal

Improve the terminus-2 terminal agent so it earns a higher score on the Frontier-CS
algorithmic problems.

Each task puts the agent in a Docker container at `/app` with one competitive-
programming problem: `statement.txt` is the full problem, `config.yaml` gives the
time and memory limits and the number of test cases, and `AGENT.md` is the
workspace guide the benchmark ships. The agent drives a tmux session — it issues
shell commands, reads what comes back, and decides when it is finished. The
container has `g++` and `python3`, and public network access. The deliverable is
`/app/solution.cpp`; nothing else in the container is graded.

When the agent stops, the Frontier-CS judge compiles `solution.cpp` and runs it
against the problem's hidden test cases under the problem's own time and memory
limits.

### The graded submission endpoint

The benchmark gives the agent a way to be graded before it finishes, and says so in
the task's own first message:

```
bash /app/submit.sh           # grades /app/solution.cpp
bash /app/submit.sh other.cpp # grades any file
```

Each call runs the same judge that produces the final score and prints back a
status, the normalised score, the raw 0–100 score, the judge's message, and its
aggregate metrics. There is no submission limit and no penalty for a low score;
what a call costs is wall clock, because the judge runs every test case.

**The final reward is the higher of the final `solution.cpp` score and the best
`done` submission the agent made through `submit.sh`.** So an attempt that submits
something that scores, and then breaks the file or runs out of time, keeps the
score it reached. Every call, including failed ones, is recorded in
`/logs/agent/submissions.jsonl`, which lands in the trial directory.

What the endpoint returns is deliberately narrow: a score and a message. Three
containers run per task-attempt — the agent's, a judge proxy, and the judge engine —
and the engine sits on an internal Docker network the agent's container cannot
reach. The test data is never in the agent's container.

## Key metric

**The mean judge score, as a fraction.** The judge returns 0–100 for a submission
and the reward is that divided by 100 — the higher of the final `solution.cpp` and
the best `submit.sh` submission, as above — so the reward is **continuous, not
pass/fail**. Two things produce a partial score:

- 121 of the 188 problems ship a custom checker (`testlib`-based). A checker can
  award a fraction of a case, so a single-case problem can score 0.53. Problems
  with a checker report a status like `Wrong Answer` alongside a non-zero score;
  that is the checker's normal behaviour, not a bug.
- The other 67 compare output exactly (whitespace-normalised), so their score is
  the fraction of cases that matched.

Every problem is one subtask worth 100 points. Some checkers can return more than
100, and the judge reports that separately as `score_unbounded` while the reward
uses the capped `score`. A perfect score is not always reachable: upstream's own
reference solution for problem 0 scores 94.5 out of 100.

The mean over task-attempts is what `result.json` reports. Nothing else is
computed for you. Every other view — per task, per problem type, across runs — is
yours to derive.

## The model capability

The agent runs on a fixed model at fixed sampling and reasoning settings, listed in
`eval/defaults.env`, and those stay as they are: the model, the temperature,
`reasoning_effort`, `max_thinking_tokens`, the backend, interleaved thinking, and
any route to them through `llm_kwargs` or a per-call override.

**The per-attempt wall clock is fixed too, and is part of the same thing.** The
benchmark's own tasks allow three hours per attempt and terminus-2's episode cap is
effectively unbounded (1000000), which would make elapsed time the only limit on
how many model calls one attempt makes. `run.sh` fixes it at **2700 seconds** by
passing harbor an agent-timeout multiplier, so the budget is the same for every
agent measured here.

Changing any of this does not make the agent better, it makes the agent *bigger*.
Buying more inference per attempt moves the score without teaching anything about
how to build a better agent, and that is the improvement this environment is not
asking for. `run.sh` passes these itself, so they are not flags, and it refuses to
evaluate an edit that changes a line mentioning one of them — bluntly, so a
reflowed docstring that merely names `temperature` is refused too. The message says
which line.

Running out of the 2700 seconds is not a failure of the trial. The judge grades
whatever `/app/solution.cpp` holds when the agent stops, and the best-submission
rule above still applies, so a timed-out attempt still has a real reward.

Everything about how the agent *uses* the capability it has is yours: the prompt
templates, how it parses replies, how it drives and reads the terminal, how it
recovers from a hung command or an unparseable reply, when it summarizes its own
context, when it decides a task is done.

The agent is sampled rather than greedy, so repeated evaluations of the same agent
differ. That is a property of this setup, not a defect to remove.

## The judge's test data

The judge reads each problem's hidden inputs and expected outputs from
`eval/frontier-cs/algorithmic/problems/<id>/testdata/`, bind-mounted into the judge
container at grading time. Those files are in this run directory, and the agent's
control loop is a host process that can read them.

**Reading them is not allowed.** A score obtained by copying expected output, or by
passing it into the container, is not a score. Nothing prevents it at the
filesystem level, so `run.sh` refuses to evaluate an edit that introduces a
reference to those paths (the list is `INTEGRITY_REFS` in `eval/defaults.env`).
That check is a tripwire on the obvious route, not a proof.

Read-only, outside the edit surface: the problem statements and configs, the
container images, the judge, and its test data.

## Edit surface

`agent/terminus_2/` — the terminus-2 agent: its control loop, prompt templates,
response parsers, tmux session handling, and context summarization.

This is what the evaluation runs, always: edit it in place. Keep the directory
where it is and keep its name — harbor imports the agent as
`terminus_2.terminus_2:Terminus2`, so `agent/` is the import root and the package
must stay `terminus_2`. `run.sh` refuses to run if it was renamed. Copies kept
elsewhere are not evaluated.

Note what the agent does *not* control: the first message it receives and the
`AGENT.md` in the container both come from the task definition, which is read-only.
The agent's own prompt templates wrap them.

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

All 188 problems of the Frontier-CS algorithmic track, listed by id in
`eval/defaults.env`, so `all` is **188 task-attempts**. Ids are
`frontier-cs-algorithm-<n>`, and upstream's numbering is sparse — it runs to 315
with gaps — so the count and the largest id do not agree. The list in
`defaults.env` is the authority, not a range.

114 of the problems are standard: the solution reads stdin and writes stdout. The
other 74 are interactive, where the solution exchanges messages with a hidden
interactor over stdin/stdout instead of reading a file. The task's first message
says which kind it is.

Every task is visible and every task is measured; there is no held-out split. An
improvement measured on the same tasks it was built against is measured on its
training set, and this environment cannot tell you whether it generalizes.
`--split` is rejected rather than aliased to the set the agent was tuned on.

### Concurrency

**Total concurrency at or under 24.** The ceiling is the node, not the command: it
covers every container running at once, across however many evaluations are in
flight, and each task-attempt runs three containers on two Docker networks.
Nothing enforces it. Past roughly 24 these containers start failing on
container-start and command timeouts rather than on anything the agent did.

Everything up to that ceiling is yours, and the wall clock above is spent whether
or not you are using it. **The default of 8 is not the fast setting.** Nor is the
ceiling a per-command limit: it is a budget for the node to divide as you like —
one evaluation at 24, two at 12, three at 8 — and an evaluation does not have to
wait for the one before it to finish.

The container images are built and pulled once, by `setup.sh`, and every task uses
the same three, so there is no per-task image build or pull.

## Where the results appear

Inside the `--artifacts` directory:

```
harbor.log        the harness's own log
job/              harbor's output — a symlink to the job directory it named
  result.json     the aggregate, described below
  <trial>/result.json           per-trial outcome and config; the reward is at
                                verifier_result.rewards.reward
  <trial>/verifier/reward.json  the one number harbor reads: reward
  <trial>/verifier/judge_result.json    the judge's own record — the raw 0-100
                                        score, score_unbounded, its status, its
                                        message, its aggregate metrics, and which
                                        submission the reward came from
  <trial>/verifier/submissions.jsonl    every graded submission of the attempt, as
                                        the judge recorded it
  <trial>/verifier/evaluation.log       the verifier's stdout, including which
                                        submission the reward came from
  <trial>/agent/submissions.jsonl       the same submissions as the agent's own
                                        client logged them, with elapsed time and
                                        code size
  <trial>/agent/                the agent's logs, trajectory, and terminal recording
  <trial>/trial.log             the trial's driver log
```

One trial directory per task-attempt, named `<task-id>__<suffix>`, so a task run
several times has several of them.

`job/result.json` holds:

```
stats.evals.<eval>.metrics[0].mean   the mean reward over attempts
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
is legible: the reward says an attempt scored what it scored, not what the agent
did. `verifier/evaluation.log` says what the judge did with the submission — that
it was missing, that it was empty, that it failed to compile, or what the judge's
verdict was, and whether the reward came from the final file or from an earlier
`submit.sh` call.

### Attempts that raise

An attempt can fail without measuring the agent — an image that will not start, a
judge container that never becomes reachable, a verifier that never finishes — and
**the reported mean counts every one of them as zero**. So an evaluation with
errors reports a number lower than the agent earned, by an amount proportional to
the error count rather than to anything the agent did. `reward_stats` lists which
trials scored what, so a mean over only the attempts that produced a reward is a
few lines away.

`AgentTimeoutError` is not one of these: when the agent runs out of its 2700
seconds the judge still grades what it left, so the attempt has a real reward and
belongs in the score. Check `exception_stats` before treating `n_errors` as lost
data. "Never finished" and "finished wrong" are different problems with different
fixes, and only the exception type tells you which you have.

There is also a failure that is not an error and scores zero anyway: if the judge
never became reachable, or the submission never appeared, or it did not compile, the
reward is 0 and `verifier/judge_result.json` carries a `detail` saying which. In
`result.json` that is indistinguishable from a wrong answer; in the trial directory
it is not.

Errors cluster in time rather than in tasks — container starts fail when the
machine is busy, so they arrive in bursts and the same task fails in one
evaluation and runs clean in the next. A burst also contaminates the attempts that
survive it: the contention that kills one container slows the others, and on this
benchmark that matters twice, because the judge enforces the problem's own time
limit on the solution it runs. A high `n_errors` is a verdict on the evaluation,
not just a smaller sample.

One more thing to check rather than assume: a task that fails at the verifier
produces no reward at all, and nothing warns you if a particular task does that in
*every* evaluation. It is then missing from every per-task view you build while
still being in the task list. Compare the task ids in `reward_stats` against the
list you asked for before trusting two numbers to share a denominator.
