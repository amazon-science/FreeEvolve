# FreeEvolve

One universal file (`SKILL.md`) plus one directory per environment. Nothing else.

This file is the design document: what the seed leaves out and why, what a run
directory is, what an environment and its `run.sh` have to provide, and how the
double loop works. For what to install and how to start a run, see
[`../docs/running.md`](../docs/running.md).

The hypothesis: **improving is environment-agnostic.** There is a universal
pattern of learning, and a universal pattern of learning to learn. If that is
true, the same file that evolves a terminal agent can evolve itself.

So `SKILL.md` is deliberately minimal. Versioning, history curation, search
schedules, candidate spawning, budget management — these are *not* in the seed.
They are the things we hope the agent discovers, and writing them in by hand
would rig the experiment.

## Layout

```
SKILL.md              the evolver. universal, task-free.
evolve.sh             one invocation of the evolver against one environment.
envs/<name>/          setup assets for one environment. see below.
lib/                  resolves the third-party checkouts two of them read from,
                      cloning at a pinned commit on first use.
```

## Running

```bash
./evolve.sh dummy /path/to/run_dir       # env, run directory
```

That is one invocation of one agent. There is no outer loop and no wall-clock
bound: if segmenting work across fresh contexts is a good idea, the agent can
spawn them itself (`claude -p`, subagents) and choose its own boundaries, and it
decides when it is finished.

The model executing the evolution skill is selected independently from the
worker model being improved. `FREEEVOLVE_MODEL_PROVIDER=bedrock` uses the AWS
credential chain; `FREEEVOLVE_MODEL_PROVIDER=anthropic` uses a regular Claude
Code login or `ANTHROPIC_API_KEY`. `EVOLVER_MODEL` selects the Claude Code model
within that provider. Worker, simulator, and judge models remain part of each
environment definition.

## A run directory

`envs/<name>/` is not what the evolver sees. It is the **asset used to install**
an environment. `setup.sh` installs what it needs into a run directory, which
then holds the setup at its root and one empty directory for the agent:

```
<run_dir>/
  ENVIRONMENT.md    the goal, how to evaluate, where results land
  run.sh            the evaluation
  eval/             whatever run.sh needs (a venv, the datasets, the harness)
  .target           where the edit surface lives, relative to here
  <edit surface>    the agent being improved — what run.sh evaluates
  workspace/        EMPTY. everything the agent produces goes here
  agent_trace.jsonl every step the agent took
```

The split is the point. Above `workspace/` is the setup, fixed for the whole run.
Inside it is everything the agent made — versions, evaluation artifacts, notes,
checkpoints. So a finished run separates what was given from what was produced at
a glance. `.target_pristine/` keeps the starting agent, to diff against.

Where the edit surface sits inside the run directory is the environment's call,
declared in `.target` — see below.

The run directory is the evolver's cwd, so `ENVIRONMENT.md`, `run.sh` and the edit
surface are all right there. How it organizes `workspace/` is its own business:
the seed says only that the space is its own, and that the declared edit surface is
what gets measured.

After setup a run directory is **standalone**: nothing in it points back at this
repo. Editing this repo cannot change a running evaluation, two runs never share
state, and a finished run is reproducible from its directory alone.

## Writing an environment

An `envs/<name>/` directory needs one thing: a `setup.sh` that takes a run
directory path and installs `ENVIRONMENT.md`, `run.sh`, the edit surface, and a
`.target` file naming where that edit surface is. Everything else is up to the
environment.

`run.sh` has three obligations:

1. **It evaluates the declared edit surface, and nothing else.** `setup.sh` writes
   one relative path into `.target`; `run.sh` evaluates whatever is there, and
   there is deliberately no flag to aim it elsewhere. So what gets measured is
   always the agent as it will actually run, at the path where it runs — a copy
   whose layout or location drifted cannot be scored by mistake.

   The path is the environment's choice. `target/` when nothing constrains it (the
   dummy env). A real path when something does: tb2.1 declares
   `agent/terminus_2`, because harbor imports the agent as
   `terminus_2.terminus_2:Terminus2` and the package directory has to be named
   that, on an import root. Editing happens in place there, so no staging copy
   stands between the edit and the measurement. It may also be a single file —
   the meta env declares `target/SKILL.md`.

   The agent keeps versions by copying the edit surface around its workspace; to
   evaluate one, it puts it back at the declared path.

2. **`--artifacts <dir>` is where evidence goes**, and concurrent calls with
   different artifacts directories must be safe.

3. **It leaves its results under `<artifacts>/`,** and `ENVIRONMENT.md` says
   where and in what form. The environment produces the numbers, not the agent.

   Whatever the harness underneath already reports *is* the result — do not
   rewrite it into a house format. A summarizer is worth adding only when it
   derives a metric the harness does not have: `tb2_1` computes the fraction of
   each task's test suite that passes, where harbor only records binary pass, and
   that finer metric is the goal that environment sets. Where the harness already
   answers the question, point at its file. Re-deriving a number that exists is
   how the two of them drift apart, and it costs the detail the harness reported
   and the summarizer dropped.

   An environment need not produce a single number at all. `meta_chain` does
   not: an evaluation there produces an inner evolve run, and judging it is the
   outer agent's work. There is no aggregation that would be right across every
   possible inner environment, and inventing one puts a fixed scalar outside
   the environment that defines it.

Beyond that, expose whatever knobs the evaluation has — task subsets, repeat
counts, concurrency, splits — and document them in `ENVIRONMENT.md` along with
what they cost. Evaluation is the only real cost in the system, and the agent
decides how to spend it.

## The double loop

Meta-evolution does not introduce a second environment format. It chooses one or
more ordinary worker environments from `envs/` and uses complete evolution runs
in those environments as evidence for improving `SKILL.md`.
`META_INNER_ENVS=tau3,arc_agi_3`, for example, makes those two environment
directories available to the outer evolver. If a new dataset is needed, the
only new component is its normal environment directory (`setup.sh`,
`ENVIRONMENT.md`, `run.sh`, and an edit surface); the meta machinery remains
unchanged and selects the new directory by name.

`envs/meta_chain/` installs an environment whose edit surface is `SKILL.md` and
whose `run.sh` launches one inner evolve loop — one invocation, one run, saved
where the caller asked. It launches that inner environment exactly as it would
run on its own, and adds nothing afterwards: the run's own evaluation artifacts
are the data point. How many runs to spend, and against which environment, is the
outer evolver's judgment, made the same way any agent spends evaluations.

The outer evolver is the same file as the inner one; only `ENVIRONMENT.md`
differs. Its `eval/` holds a full copy of this repo, so inner runs launched from a
meta run directory stay inside it — the recursion nests rather than escaping. The
meta environments are removed from that copy's `envs/`, so they are never offered
as candidates to themselves.

`run.sh --from <dir>` starts an inner run from an agent an earlier inner run
produced, so improvements can stack rather than every run starting cold. What
that is worth, how deep to go, and which agent out of a finished run to build on
are the outer evolver's decisions.

`envs/meta_chain/` is canonical and submits inner runs through Slurm. It requires
`sbatch`, `squeue`, and paths visible from the compute nodes.
`envs/meta_chain_local/` changes only the dispatch backend and runs
the same inner campaigns directly on the current machine and needs no scheduler.
The Slurm variant can run from a local host only when that host is configured as
a Slurm submit node; otherwise use the local variant.

When the outer loop finds a better `SKILL.md`, it is promoted: it becomes both the
evolver and the meta-evolver for the next generation.

`SKILL.md` here is the seed described above, with none of the method an evolver
is supposed to work out. That is what runs unless a launch names another file.
An evolved example is stored at
[`../artifacts/evolution-skills/arc-agi-3/SKILL.md`](../artifacts/evolution-skills/arc-agi-3/SKILL.md);
`evolve.sh` uses it only when a launch explicitly supplies that path. Keeping
finished skills outside the source directory prevents an evolving agent from
turning improvement into copying an answer already present in its run.

The strongest bundled general skill is
[`../artifacts/evolution-skills/strong/SKILL.md`](../artifacts/evolution-skills/strong/SKILL.md).
The launcher exposes it as `strong`; it remains outside the source directory
for the same isolation reason.
