# FreeEvolve: Learning to Evolve Beyond Fixed Loops

This is the detailed setup and operations guide for FreeEvolve. The framework
code lives in `freeevolve/`; its paths and variables use the same name
(`FREEEVOLVE_ROOT`, `~/.cache/freeevolve/`).

This guide covers prerequisites, direct launches, cluster launches, built-in
environments, and credentials. For a guided start, load the repository as a
Claude Code plugin and run `/freeevolve:launch`. The launcher inspects local and
Slurm execution separately; an unavailable Docker daemon on a scheduler login
node is not treated as a blocker when the selected compute partition passes its
preflight. For the framework design and environment contract, see
[`freeevolve/README.md`](../freeevolve/README.md).

```
artifacts/evolution-skills/  evolved evolution skills.
artifacts/evolved-agents/    evolved agent edit surfaces for four environments.
freeevolve/
  SKILL.md              the evolver: the seed. One file, task-free.
  evolve.sh             one invocation of the evolver against one environment.
  envs/<name>/          setup assets for one environment.
  lib/                  resolves the two large third-party checkouts, cloning them
                        at pinned commits on first use and caching them.
  submit_evolve.sbatch  one evolve run as a batch job.
  submit_eval.sbatch    one evaluation, no agent, as a batch job.
```

## What you need

- **Linux** for the published benchmark setup. The container-backed environments
  also need **Docker** running and usable by your user. `dummy` and `arc_agi_3`
  do not require Docker; meta-environments inherit the requirements of their
  selected inner environments. `docker compose` v2 is installed by setup into
  `~/.docker/cli-plugins/` if it is missing.
- **`uv`** (https://docs.astral.sh/uv/) on `PATH` for benchmark environments. Each
  setup builds its own Python 3.12 virtualenv; nothing is installed system-wide.
- **`git`**, **`rsync`**, **`curl`**.
- **Claude Code** (`claude`) on `PATH`. This is what an evolver *is*: `evolve.sh`
  hands one `SKILL.md` to one `claude -p` invocation.
- **Model access.** Two separate roles, and they are configured separately:
  - the **evolver** model, pinned by `evolve.sh` into `<run_dir>/.claude/settings.json`.
    `FREEEVOLVE_MODEL_PROVIDER=bedrock` uses the AWS credential chain and defaults
    to `EVOLVER_MODEL=global.anthropic.claude-opus-4-8[1m]`.
    `FREEEVOLVE_MODEL_PROVIDER=anthropic` uses a normal Claude Code login or
    `ANTHROPIC_API_KEY` and defaults to `EVOLVER_MODEL=claude-opus-4-8`.
  - the **agent under evolution**, whose model each environment sets for itself — see
    that environment's `defaults.env` and `ENVIRONMENT.md`. The published
    benchmark configurations use fixed Bedrock model IDs from inside the
    evaluation harnesses. This is independent of the provider chosen for the
    evolver.

  `FREEEVOLVE_MODEL_PROVIDER=auto` honors an explicit
  `CLAUDE_CODE_USE_BEDROCK` value, then direct Anthropic credentials, then the
  provider reported by `claude auth status`. If none is detectable, it uses
  Bedrock for compatibility with the published runs. Each run records the
  resolved provider/model in `.freeevolve-model.env`. No credential value is
  stored.

Nothing else has to be prepared by hand: each `setup.sh` installs its own harness,
data and agent into the run directory, and a run directory is standalone once set up.

## Quickstart

```bash
cd freeevolve

# 1. The smoke test. No containers and no benchmark data: setup is seconds, and one
#    evaluation is 22 small tasks the agent under evolution answers with a model
#    (a couple of minutes, and the cheapest way to check your model access works).
./evolve.sh dummy /tmp/run_dummy

# Use regular Anthropic Claude Code instead of Bedrock for the evolver.
FREEEVOLVE_MODEL_PROVIDER=anthropic \
  EVOLVER_MODEL=claude-opus-4-8 \
  ./evolve.sh dummy /tmp/run_dummy_direct

# 2. A real environment. Setup pulls images and builds a dataset — minutes to tens
#    of minutes, once per run directory.
./evolve.sh tau3 /tmp/run_tau3

# 3. The double loop, no scheduler: the evolver improves SKILL.md, and each of its
#    evaluations is a whole inner evolve run in one selected worker environment.
META_INNER_ENVS=tau3,arc_agi_3 \
  ./evolve.sh meta_chain_local /tmp/run_meta
```

In meta-evolution, the inner evolver inherits the outer provider and model by
default. Set `INNER_EVOLVER_MODEL` for one global override, or
`INNER_EVOLVER_MODEL_<ENV>` (for example,
`INNER_EVOLVER_MODEL_ARC_AGI_3`) when different inner environments require
different pinned models.

`./evolve.sh <env> <run_dir> [skill_file]` is the whole interface. With no skill file
it runs `SKILL.md`, which is the **seed**: 171 lines of dispositions and situation,
with no versioning scheme, search schedule, measurement protocol or budget management
in it. Those omissions are deliberate — `freeevolve/README.md` says why.

Name a file to run a different skill:
`../artifacts/evolution-skills/strong/SKILL.md` is the strongest bundled general
skill produced by meta-evolution. The launcher exposes it as `--skill strong`.
`../artifacts/evolution-skills/arc-agi-3/SKILL.md` is an additional evolved
artifact. Nothing reads either file unless you select it or name its path.

`artifacts/evolved-agents/` holds an evolved agent for four environments. From
inside `freeevolve/`, point an environment at one to start from that edit surface:

```bash
TAU3_AGENT_SRC=../artifacts/evolved-agents/tau3/tau3_agent      ./evolve.sh tau3      /tmp/run_tau3
ARC3_AGENT_SRC=../artifacts/evolved-agents/arc_agi_3/arc3_agent ./evolve.sh arc_agi_3 /tmp/run_arc3
ARC_AGENT_SRC=../artifacts/evolved-agents/arc_agi_2/arc_agent   ./evolve.sh arc_agi_2 /tmp/run_arc2
TB2DA_AGENT_SRC=../artifacts/evolved-agents/tb2_da/agent        ./evolve.sh tb2_da    /tmp/run_tb2da
```

The same variables work with `submit_eval.sbatch`, to measure one of them with no
evolver involved.

There is no outer loop and no wall clock: the agent decides when it is finished.
Standalone runs are told how long they have by `EVOLVE_BUDGET_HOURS` (the batch
launcher sets 12; `evolve.sh` alone says nothing unless you set it).

For meta-evolution, `META_INNER_ENVS` is the comma- or space-separated catalog of
worker environments available to the outer evolver. Each evaluation of a
candidate `SKILL.md` launches one complete evolution campaign in one selected
environment. Select existing names from `envs/`; to use new data, implement that
data and evaluator once as a normal environment directory, then include its name
in `META_INNER_ENVS`.

To evaluate without an agent — a baseline, or a fixed agent at higher n:

```bash
./evolve.sh dummy /tmp/run_eval    # or install by hand: envs/<env>/setup.sh <run_dir>
cd /tmp/run_eval && ./run.sh --artifacts artifacts/baseline
```

## On a cluster

`submit_evolve.sbatch` and `submit_eval.sbatch` run one evolve run, or one
evaluation, on a node. Neither carries a partition or a node list — those were
properties of one cluster and have been removed. Choose them at submit time:

```bash
FREEEVOLVE_ROOT="$PWD" sbatch -p <partition> submit_evolve.sbatch tau3 /path/to/run
```

`FREEEVOLVE_ROOT` has to be exported because Slurm copies the script into its spool
directory, so `$0` no longer points at this repo.

The guided launcher first lists available partitions without launching jobs,
then runs one short compute-node preflight on the selected partition. That
preflight verifies that the repository and run parent are visible, required
commands and Docker are usable, and the selected Claude provider/model can be
reached. It does not probe every partition or require the login node itself to
run the benchmark stack.

One node property matters: container evaluations at high concurrency exhaust
Docker's default address pool. Environments that run containers ship a
`configure-docker-pool.sh` that widens it, and the launchers run it as a pre-flight.
Where that needs privileges the job does not have, widen the pool on the nodes
beforehand and restrict jobs to those nodes.

`envs/meta_chain` is the source of truth and submits inner runs as Slurm jobs, so it requires `sbatch`,
`squeue`, and shared storage visible to the compute nodes.
`envs/meta_chain_local` delegates to that same protocol and changes only dispatch,
running the inheritable inner campaigns directly on
the current machine and needs no scheduler.

## The environments

| env | what the agent is improved on | data / images |
| --- | --- | --- |
| `dummy` | a toy scoring script | none |
| `tau3` | tau3-bench customer-service tool use | generated at setup from a `tau2-bench` clone (public) via the harbor adapter; containers built locally |
| `tb2_1` | Terminal-Bench 2.1 terminal tasks | harbor task registry; images pulled |
| `tb2_da` | Terminal-Bench 2, deepagents harness | as above, with a pinned langchain stack |
| `arc_agi_2` | ARC-AGI-2 puzzles | generated at setup by the harbor adapter |
| `arc_agi_3` | ARC-AGI-3 interactive games, offline | games vendored in `envs/arc_agi_3/games/` |
| `frontier_cs` | Frontier-CS algorithmic problems | upstream problem tree cloned on first setup (2.6 GB, mostly generated test data); judge image pulled |
| `hle` | Humanity's Last Exam | **gated**: needs a HuggingFace token with `cais/hle` access |
| `gaia2_cli` | GAIA2 CLI scenarios; evaluation-only until an edit surface is declared | HuggingFace; a dataset whose terms may need accepting on your account |
| `meta_chain` | `SKILL.md`, with inheritable inner runs submitted through Slurm | whatever the inner environment needs |
| `meta_chain_local` | `SKILL.md`, with inheritable inner runs executed locally | whatever the inner environment needs |

Every evolution environment states its own goal, metric, evaluation flags, costs
and concurrency ceiling in the `ENVIRONMENT.md` it installs. That file is what
the evolver reads. `gaia2_cli` is the one evaluation-only asset: it measures a
stock agent and intentionally does not yet install `.target` or `ENVIRONMENT.md`.

Two credentials are the only things setup cannot provision for you:

- **`hle`** needs `HF_TOKEN` (or a file named by `HF_TOKEN_FILE`, default
  `~/.hf_token`) from an account granted access to the gated `cais/hle` dataset.
- **`gaia2_cli`** downloads its scenarios from HuggingFace; if the dataset requires
  accepting terms, do that on your account and have `huggingface_hub` credentials
  available.

Two large public repositories are fetched rather than shipped, by
`lib/ensure_checkout.sh`, on the first setup that needs them:

| | repo | cached at | pin / override |
| --- | --- | --- | --- |
| benchmark adapters for `tau3`, `arc_agi_2`, `hle`, `gaia2_cli` — they live in the harbor repo, not the published package | `harbor-framework/harbor` | `~/.cache/freeevolve/harbor` | `HARBOR_COMMIT` / `HARBOR_ROOT` |
| the `frontier_cs` problem tree — 2.6 GB, almost all of it generated test data | `FrontierCS/Frontier-CS` (MIT) | `~/.cache/freeevolve/frontier-cs` | `FRONTIER_CS_COMMIT` / `FRONTIER_CS_ROOT` |

Both are pinned to a fixed commit, cloned under a lock
so concurrent setups are safe, and reused by every run directory afterwards. Point
`HARBOR_ROOT` or `FRONTIER_CS_ROOT` at a checkout you already have and nothing is
cloned. `FREEEVOLVE_CACHE_DIR` moves the cache — worth putting on the same
filesystem as your run directories, since the Frontier-CS tree is hardlinked into a
run when it can be and copied when it cannot.

So the package itself is about 5 MB. `frontier_cs` is the one environment whose setup
needs real disk: its cached checkout is ~2.8 GB (a 2.1 GB working tree, almost all
test data, plus 0.7 GB of git objects) and takes several minutes to clone, once;
after that each run directory hardlinks it.

## Portability notes

Machine-specific and installation-specific details are exposed through portable
configuration:

- absolute paths into one home directory (a harbor checkout, a prebuilt tau3
  dataset, a HuggingFace token file, two vendored-from paths) are now environment
  variables with portable defaults, or are resolved automatically;
- the Slurm partition and the explicit node list are gone from all four batch
  scripts, with what the node has to provide documented instead;
- `meta_chain_local` reads the CPU count and memory of the machine it installs
  on and states those in `ENVIRONMENT.md`, rather than the numbers of the
  machine this was developed on;
- the environment set is the ones above; narrower variants of them (task subsets,
  split flips, an earlier fixed-chain meta environment) are not included;
- `SKILL.md` is the seed rather than a more developed version, so a default
  launch starts from the seed; evolved examples are isolated under
  `artifacts/` and are used only when named explicitly;
- the Frontier-CS problem tree, which was vendored in the working copy, is fetched
  from upstream instead — the package carries no benchmark data it did not author,
  beyond the 4 MB of ARC-AGI-3 game files.

Four defects found while assembling it are fixed here: a `pipefail` interaction that
made a chain-meta setup abort when an inner environment had no `defaults.env`;
`--from` reaching only three of the seven environments that can inherit an agent, so
a stacked run against any of the others would silently have started cold; the meta
environments being removed from a run's inner-environment catalogue by name, which
left later-added ones in it; and a glob that could abort setup once they were all
already absent.
