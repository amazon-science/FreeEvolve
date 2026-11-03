# Environment: meta

## Goal

Improve the evolver itself.

`SKILL.md` is the instructions given to an agent whose job is to improve some
other agent against some other goal. Your job is to make those instructions
produce better evolvers.

The inner setting is the same one you are in. An inner evolver is handed a run
directory with an environment installed in it, and works there until it is done.
Whatever it does in between — how it works, what it records, how it spends its
evaluations — is determined by `SKILL.md` and nothing else.

## Key metric

How much better an inner evolver became at improving its agent.

There is no number here that says so. An evaluation produces an inner run
directory, and what that run achieved is legible only inside it: the inner
environment states its own key metric and its harness writes its own results, so
every evaluation the inner evolver chose to run is recorded there in that
environment's terms.

Reading a run is therefore part of the work, not something done for you. Nothing
aggregates those results into a score, because there is no aggregation that would
be right for every inner environment — each has its own metric, its own data,
its own costs — and because what makes an evolve run good is not obviously a
scalar. Two runs are only as comparable as the evaluations they happened to run.

That is also the hard part of the goal. Deciding what counts as a better evolver,
and what evidence would show it, is yours.

## Edit surface

`target/SKILL.md` — the evolver's instructions. This is what the evaluation runs,
always. Edit it in place.

The inner environments are not yours to edit. If an inner run scores well because
its environment got easier, nothing was learned.

## How to evaluate

```
./run.sh --artifacts <dir> --inner-env <name>
```

The evaluation always runs `target/SKILL.md`. There is no flag to point it
somewhere else — what gets measured is always the evolver as it stands.

One invocation submits one Slurm job and waits for it. The job gets a whole node,
installs the inner environment into a fresh run directory, and runs that
environment's evolve loop with the skill under evaluation — exactly as that
environment would run on its own. Nothing is added afterwards and nothing is
measured on top: whatever the inner run leaves behind is the result.

Invocations with different `--artifacts` directories are independent and can
proceed at the same time.

Options:

| flag | meaning | default |
| --- | --- | --- |
| `--artifacts <dir>` | where to write evidence (required) | |
| `--inner-env <name>` | which inner environment to evolve against (required) | |

The available inner environments are the directories under
`eval/freeevolve/envs/`. Each has its own `ENVIRONMENT.md` stating the goal an
inner evolver faces there, its system, what its evaluations cost, and what data
they run on. They differ in this: some hold a set back, some measure on everything
they have.

### Cost

An evaluation here costs one inner evolve loop, running until its evolver decides
it is done, plus that inner environment's own evaluation costs inside it. It is by
far the most expensive thing in this system, and it is not bounded — an inner
evolver that keeps working keeps costing. What one came to is recoverable from the
inner run's own results, which record what each of its evaluations spent.

What one run costs depends on the inner environment, and varies between
environments by orders of magnitude.

### System

A Slurm cluster. One job per invocation, each getting a whole node to itself.

**No more than 10 inner runs at a time** — that is the share of the cluster this
experiment may hold, counted across invocations in flight. Nothing enforces it.

Each run has a whole node, so whatever concurrency budget the inner environment
describes applies within that run, separately from this limit.

## Where the results appear

Inside the `--artifacts` directory:

```
run.log           the inner invocation's log
slurm_logs/       the submitted job's .out and .err
run/              the inner run directory. Standalone: the environment it was held
                  to is installed in it, so the run is reproducible from the
                  directory alone.
  ENVIRONMENT.md  the goal it was given, and the key metric it was held to
  run.sh          the evaluation it was held to
  .target         the edit surface it was given
  <edit surface>  the agent as it left it — what its last evaluation measured
  workspace-<env>/  the inner evolver's own space, exactly as it left it —
                  everything it wrote, in whatever form it chose, including the
                  results of every evaluation it ran. Named for the inner
                  environment, so it never collides with your own workspace.
  agent_trace.jsonl  every step it took
```

A run's workspace has no imposed layout: the inner evolver named everything in it,
so what is there and where differs from run to run. Its `ENVIRONMENT.md` states
what its evaluations produce and where, which is what makes the contents legible.

`agent_trace.jsonl` is the record of how it worked, as distinct from what it
achieved — every command it ran and every file it touched, in order.

## A note on evidence

An inner evolver's own write-up reports what it believed. Its environment's
results report what was measured. These can disagree, and the second is the
evidence.
