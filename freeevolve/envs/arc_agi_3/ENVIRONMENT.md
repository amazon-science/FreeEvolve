# Environment: ARC-AGI-3

## Goal

Improve the game agent so it gets further through ARC-AGI-3 games, using fewer actions.

Each game is an interactive environment nobody describes to the agent. There is no
instruction text, no statement of the goal, and no account of what the controls do. The
agent is shown a screen — a 64x64 grid of integers 0-15, one per cell — chooses an
action, and is shown the screen that action produced. What the game is, and what winning
it looks like, is only visible in that loop.

A game has several levels, six to ten in this set. Finishing one advances a counter the
agent is shown; finishing the last one wins the game. Nothing else is scored, and no
model is involved in grading.

## Fixed: the model capability

The agent runs on a fixed model, at a fixed reasoning effort — `high` — and with a fixed
per-call output budget of 32768 tokens, both set as `DEFAULT_REASONING_EFFORT` and
`DEFAULT_MAX_TOKENS` in the agent source. **Hold these constant.** Do not raise them,
lower them, remove them, or route around them (by env var, by a per-call override, by a
second model, or by changing which model is used). `run.sh` refuses to evaluate an edit
that changes a line setting one of them, and says which line.

The reason is that changing them does not make the agent better — it makes the agent
*bigger*. Buying more inference per call, or a stronger model, moves the score without
teaching anything about how to build a better agent, and that is the improvement this
environment is not asking for.

Everything about how the agent *uses* the capability it has is in scope: what it is
told, how the screen is presented to it, how many actions it commits to per call, what
it remembers between calls and in what form, how it decides an action was worth taking,
how it recovers, and when it gives up on an approach.

Because extended thinking requires `temperature=1.0`, the agent is sampled rather than
greedy: repeated attempts at the same game differ. That variance is a property of this
setup, not a defect to remove.

## Key metric

**Relative Human Action Efficiency**, the published benchmark's own score, as a fraction
of 1.0 rather than a percentage. It is a function of two things: which levels were
finished, and how many actions each one took compared with a human seeing the game for
the first time.

For each level, 1-indexed:

```
level_score = min((human_baseline_actions / actions_taken) ** 2, 1.15)   if finished
            = 0                                                          if not
```

and the game's score is the level scores averaged with each level weighted by its own
number:

```
score = sum(level_score[i] * i) / sum(i)      over EVERY level of the game
```

Three things follow from that shape, and they matter more than the formula:

- **Every level is in the denominator, finished or not.** A game with five levels of
  which four were finished perfectly cannot score above `(1+2+3+4)/(1+2+3+4+5)` = 0.667.
- **Later levels are worth more.** Level 6 counts for six times what level 1 does, so
  most of the score of most games is in levels the agent has not reached yet.
- **The squared ratio punishes wandering hard.** Twice the human's actions scores 0.25;
  ten times scores 0.01. Finishing a level is worth very little if it took hundreds of
  actions to stumble into.

The human baseline is the upper-median of several first-time players, per level. It is
not hidden: `session.baseline_actions` gives the agent the whole list. Across this set of
games it is 7 to 78 actions for level 1, with a median of 30, and 171 to 1843 for a whole
game.

**The score is exactly zero until a level is finished**, and small for a while after.
Finishing level 1 of a seven-level game in a hundred actions against a baseline of thirty
is worth `0.09 * 1/28` — about three thousandths. So `levels_completed` moves first and
by visible amounts, while the score is still rounding to nothing; `metrics[1..3]` are
reported alongside the score for that reason. Both are real, and neither is a substitute
for the other: levels say whether the agent got anywhere, and the score says whether it
got there the way a human would.

The harness reports the metric in `job/result.json`:

```
stats.evals.arc_agi_3.metrics[0].mean       mean score over attempts   <- the metric
stats.evals.arc_agi_3.metrics[0].stderr     its standard error
stats.evals.arc_agi_3.metrics[1..3].mean    levels as a fraction, levels, actions
stats.evals.arc_agi_3.official_score        best attempt per game, averaged over games
stats.evals.arc_agi_3.reward_stats          which attempt scored what, by trial id
stats.evals.arc_agi_3.per_game              per game: every attempt's score and levels
stats.evals.arc_agi_3.n_trials              attempts that produced a score
stats.evals.arc_agi_3.n_errors              attempts that failed without being scored
stats.evals.arc_agi_3.exception_stats       which those were, and why
stats.cost_usd                              what the evaluation spent
```

Nothing is computed on top of that. Every other view — per level, per action, across
evaluations — is yours to derive from `job/`, which holds every attempt's full record.

**Two aggregations, and they are not the same number.** `metrics[0].mean` averages every
attempt, so at matched attempt counts it is comparable between evaluations and its
standard error means something. `official_score` takes each game's *best* attempt and
averages the games, which is what the published benchmark reports — it rises with the
number of attempts, so it is only comparable between evaluations that ran the same
number. Use the first to compare versions; the second says where the agent stands.

**The score is computed twice.** The toolkit computes it from its own scorecard while
the game is played; the harness recomputes it from `steps.jsonl`, its own record of
every action. `scores_agree` on each attempt says whether they matched, and
`scores_disagreed` lists any that did not. A disagreement is not a small discrepancy to
average over — it means one of the two records of that play is wrong.

## Edit surface

`agent/arc3_agent/` — the agent, two files:

- `arc3_agent.py` — the harness-facing side: the class the harness constructs, and what
  the agent records about itself.
- `run_arc3_agent.py` — what the agent does with the game: what the model is told, how
  the screen is rendered for it, the loop, and how actions are chosen.

This is what the evaluation runs, always: edit it in place. Keep the directory where it
is and keep its name — the harness imports the agent as `arc3_agent:ARC3Agent`, so
`agent/arc3_agent` is the import root and the module names must not change. `run.sh`
refuses to run if the entry module is missing. Copies kept elsewhere are not evaluated.

The contract is small: the harness constructs `ARC3Agent(model=..., artifacts_dir=...)`
and calls `play(session)` once. Whatever `play` returns, if it is a dictionary, is
recorded with the attempt, and `cost_usd`, `n_input_tokens` and `n_output_tokens` are
read out of it for the evaluation's totals. Everything else about how the agent is
organised — how many modules, what it keeps on disk in `artifacts_dir`, what it spawns —
is the agent's own business.

Read-only, outside it: the game engine, the games, and the scoring.

Inside the edit surface but fixed: `DEFAULT_MAX_TOKENS`, `DEFAULT_REASONING_EFFORT`, and
anything else that would change the model or how much inference it buys per call.

### The game is not the agent's to read

The engine and the score run in a **different process** from the agent. The agent is
handed a session and every action it takes is a request across that boundary, which the
harness applies, counts and records. It cannot reach the scorecard, and the number the
evaluation reports is the harness's record of the play rather than the agent's report of
it.

The games themselves are on this disk, under `eval/games/`, because the engine has to
load them. Each is a few hundred kilobytes of Python: the rules, the levels, the win
conditions, in source. An agent that read one would not have learned anything about the
game, and an agent that loaded a private copy could practise a level unscored and then
walk the scored session straight through it. Either one leaves a number that measures
nothing.

`run.sh` therefore refuses to evaluate an edit surface whose changed lines name the
engine, the game directory, or the toolkit's own client. The check is mechanical and
cannot be complete; the boundary is the point rather than the check.

## What the agent works with

**The screen.** `obs.frame` is a list of 64x64 grids of integers 0-15. In every game in
this set it holds exactly one. Cell `(x, y)` is `frame[0][y][x]`, with `(0, 0)` at the
top left. The integers are colour indices; nothing says which colour, and nothing needs
to.

**The actions.** `RESET`, `ACTION1` through `ACTION5`, and `ACTION7` take no arguments.
`ACTION6` takes `x` and `y`, each 0-63, and is how a game that wants a click gets one.
`ACTION7`, where a game has it, is always an undo.

Which of them a game accepts is in `obs.available_actions`, and it varies: some games are
keyboard-only (`ACTION1`-`ACTION4`), some are click-only (`ACTION6`), some are both. It
can change within a game.

**Nothing stops the agent sending an action a game does not list, and doing so is not
free.** Measured on three games: an unlisted action is passed to the game like any other,
comes back with a screen, and is counted against the budget and the score exactly as a
listed one is. It simply does nothing. `available_actions` is information, not a guard.

An action a game *does* accept also always costs one, whether or not anything happened.
Walking into a wall costs an action; so does a click on empty space.

The one thing that costs nothing is a request the harness will not pass on at all: an
action name that does not exist, `ACTION6` without coordinates, or coordinates outside
0-63. Those raise and no action is spent.

**The state.** `obs.state` is `NOT_FINISHED`, `WIN`, or `GAME_OVER`. `GAME_OVER` is not
the end of the attempt — it is a position the agent has to get out of, and `RESET` is
how. That `RESET` costs one action like any other. `WIN` is the end: every level is
finished and the harness will not accept another action.

**Two `RESET`s in a row throw the attempt's progress away.** The first `RESET` after any
action restarts the current attempt within the same play: it costs an action and the level
counter is unaffected. A second `RESET` immediately after it is a *full* reset — it starts
a new play, back at level 1, with `obs.plays` incremented and `obs.levels_completed` back
to 0. Verified on this engine. The score keeps the best play, so a run that does this by
accident does not lose the score it had already earned; what it loses is every remaining
action, now spent re-solving levels it had already solved. `RESET` is for recovering from
`GAME_OVER`, once.

**An action sent while the state is already `GAME_OVER` does nothing at all.** The game
returns no screen for it; `obs.frame_returned` is false, `obs.frame` is the previous
screen, and — because the published scoring ignores such a response completely — it is
not counted against the budget either. This is the one case where an action is free, and
it is free because it never happened. An agent that keeps playing after `GAME_OVER`
instead of resetting is not spending its budget, but it is spending its clock, and every
screen it sees is the same one.

**The counter.** `obs.levels_completed` and `obs.win_levels` say where the agent is. This
is the only feedback about progress there is: no score, no reward, no hint that the last
action helped. A level boundary is the one thing that is unambiguous, and the frame that
crosses it is the one that says so.

**The session.** `eval/harness/session.py` is the whole of what the agent can do, and its
docstring is the contract. Nothing else about the harness is reachable from the agent.

## How to evaluate

```
./run.sh --artifacts <dir> [options]
```

| flag | meaning | default |
| --- | --- | --- |
| `--artifacts <dir>` | where to write evidence (required) | |
| `--tasks <ids>` | comma-separated game ids, or `all` | `all` |
| `--attempts <n>` | how many times to play each game | 1 |
| `--concurrency <n>` | attempts run in parallel | 8 |
| `--timeout <s>` | wall clock for the whole evaluation | none |

So an evaluation is any number of games from the set, played any number of times each.
Concurrent evaluations with different `--artifacts` directories are safe.

**Every attempt gets 2000 actions and 7200 seconds. Both are fixed and are not flags.**
`run.sh` refuses `--max-actions` and `--attempt-timeout`, and refuses to evaluate if
`eval/defaults.env` has changed since setup. The same agent scores higher under a longer
clock or a larger action budget, so two evaluations run under different budgets do not
measure the same thing.

Of the two, **the clock is the one that binds.** The action budget is deliberately set
high enough that every game in the set is winnable within it at human efficiency, so the
harness does not clip the metric.

### The game set

The games installed into `eval/games/`, one directory each, drawn from the public set of
25. Each carries its own human baseline, per level, in its `metadata.json`.

Every game there is visible and every one is measured; there is no held-out split inside
this run. An improvement measured on the same games it was built against is measured on
its training set, and this environment cannot tell you whether it generalises. Games the
run directory does not contain are simply absent rather than hidden.

**The set is small, and that is the hard constraint on measurement here.** With 25 games
one game's swing is four points of the total; with fewer, more. A game is also not one
sample of one thing — it is a chain, where reaching level 3 requires having solved levels
1 and 2, so scores across games are not drawn from anything like a common distribution.
Two evaluations of the same agent on the same games will differ; how much is worth
finding out early, because it sets the size of a difference that means anything.

### Cost and time

Attempts run `--concurrency` at a time, each as two processes: the harness holding the
game, and the agent. The engine itself runs at over a thousand actions per second, so
the game is never what an attempt is waiting for — a model call is, every time.

That makes the arithmetic simple, and worth doing before planning an evaluation: an
attempt costs one model call per decision, and how many decisions it makes is up to the
agent. An agent that decides one action at a time and takes 200 of them makes 200 calls;
one that commits to five actions per call makes 40 for the same 200 actions. Wall clock
and dollars both follow the call count, not the action count.

**Total concurrency at or under 48.** The ceiling is the node, not the command: it
covers every attempt running at once, across however many evaluations are in flight.
Nothing enforces it. The default of 8 is not the fast setting — the node has 192 CPUs
and 373 GB, and an attempt uses about one core. Attempts are latency-bound rather than
CPU-bound, so raising this is close to free until the model provider starts refusing
calls; watch `n_errors` and `exception_stats` and back off if they climb.

There is no image to build and no container to start, so a fresh machine pays nothing
extra for the first evaluation.

Two measured facts about this machine, which hold whatever the agent does:

**Concurrency above about 40 does not work.** At `--concurrency 25`, ten thousand actions
ran with zero provider errors and no latency penalty. At `--concurrency 45`, the provider
returned 76 rate-limit errors and every attempt in flight died. The ceiling between those
two is unmeasured; 25 is known-safe.

**An evaluation takes as long as the 7200s attempt clock, not less.** With 25 games at
`--concurrency 25` every attempt runs at once, so the evaluation's wall clock is its
slowest attempt — and on this set the slowest attempt reaches the deadline every time.
Cutting `--tasks` therefore saves money but not time.

What an evaluation costs is the number of model calls it makes: 25 games, each running
to its own action cap or its own deadline, at this environment's fixed effort and output
budget. Both of those are large, so a single call can think for minutes, and cost scales
with actions taken rather than with games attempted.

## Where the results appear

Inside the `--artifacts` directory:

```
eval.log          the harness's own log, one line per finished attempt
job/
  result.json     the aggregate, described above
  <game>__<n>/    one directory per attempt
    result.json   that attempt's score, levels, actions, timings, cost, stop reason
    steps.jsonl   every action and the state it produced, in order
    scorecard.json  the toolkit's own scorecard for the attempt
    attempt.log   the attempt process's log
    agent/
      arc3-agent-summary.json     what the agent recorded about itself
      arc3-agent-transcript.json  every message of the attempt
      agent-stdout.txt            anything the agent printed
      agent-stderr.txt            anything it printed to stderr, and its traceback
```

`steps.jsonl` is where a failure becomes legible, and it is the harness's record rather
than the agent's. One line per action: what was sent, what state came back, how many
levels were finished by then. Reading it tells you whether the agent was going in
circles, whether it noticed a level boundary, whether it spent a hundred actions on a
screen that never changed — none of which the score can say.

There are two accounts of how an attempt ended and they answer different questions.
`result.json`'s `closed_reason` is the harness's: `agent_finished` (the agent returned),
`budget_exhausted`, `deadline_reached`, `game_won`, `agent_killed`,
`deadline_reached_no_report` (the deadline passed and the agent never came back to say
what it had spent, so its tokens and cost are missing from the totals — `cost_complete`
is false), or `harness_error`. `agent_summary.stop_reason` is the agent's own, and is
where a provider error or an agent that stopped choosing actions shows up.

An agent that returned early with budget left made a choice — or hit something. Read both.

### Attempts that raise

An attempt can fail without measuring the agent — a game that will not load, a process
that will not start — and those are **not** counted in the mean. They appear in
`n_errors` and `exception_stats`, and the mean is taken over the attempts that produced a
score, so an evaluation with errors reports a number over fewer attempts rather than a
number pulled down by zeros.

An attempt whose agent hit an error is not one of these, and does not appear in
`n_errors`. Its score is whatever it had achieved before, which is a real score and
belongs in the mean — but only some of those are the agent's fault. A model provider
returns errors, and one arriving forty actions in ends the attempt exactly where it was,
which reads from the outside like an agent that gave up. That has happened here: a first
full evaluation of this set had 24 of 25 attempts end on the first transient provider
error, and reported a mean that was really a measure of how long each attempt lasted
before one arrived. So before reading a low score as a strategy that did not work, check
`agent_summary.stop_reason` across the attempts: if the same error ended most of them, the
evaluation measured the provider and not the agent.
