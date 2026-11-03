# FreeEvolve Environment Contract

Use this reference when adapting a new project. An environment defines the
improvement problem and the legal interaction surface; the evolution skill
decides how the campaign unfolds.

## Asset directory

Create an adapter directory with a required executable `setup.sh`:

```text
<project>/.freeevolve/environments/<name>/
  setup.sh
  ENVIRONMENT.md      # source template, if convenient
  run.sh              # source evaluator wrapper, if convenient
  ...                 # evaluator and initial-agent assets
```

`setup.sh <run-directory>` installs a standalone run. It may copy project files,
create a virtual environment, download data, or build containers, but the
installed run must not point back to the adapter directory.

Setup should be idempotent where practical and must not overwrite an existing
edited target without making that behavior explicit.

## Installed run

The installed run must contain:

```text
<run-directory>/
  ENVIRONMENT.md
  run.sh
  .target
  <edit-surface>
  .target_pristine/    # strongly recommended
  eval/                # conventional location for immutable evaluator assets
```

`.target` contains exactly one relative path naming the edit surface. It may name
a directory or one file. Keep it inside the run directory and outside evaluator
assets. FreeEvolve creates the campaign workspace and records the evolution
skill when it launches.

## ENVIRONMENT.md

Write for the evolver. State:

1. the improvement goal;
2. the primary metric and whether higher or lower is better;
3. the exact edit surface and its runtime contract;
4. how to invoke `run.sh`, including optional controls;
5. where results and diagnostic artifacts appear;
6. immutable model, benchmark, integrity, hardware, time, and resource
   constraints;
7. evaluation costs or concurrency limits the evolver needs to manage.

Do not prescribe a search schedule, candidate population, curriculum, or stopping
rule. Those decisions belong to the evolver.

## run.sh

The installed evaluator must support:

```bash
./run.sh --artifacts <directory> [environment-specific options]
```

It must:

- evaluate the current object at the path in `.target`, with no alternative flag
  that silently evaluates a copy;
- place scores, trajectories, logs, and other evidence under the requested
  artifacts directory;
- be safe when concurrent calls use distinct artifacts directories;
- preserve the benchmark's native result format unless a derived metric is
  genuinely needed;
- return nonzero for evaluator failures and distinguish them from a valid low
  score where possible;
- prevent the target from reading answer-bearing evaluator assets or changing
  fixed capability settings.

Expose useful legal controls rather than hard-coding one evaluation schedule.
Typical controls include task subsets, attempts or repetitions, random seeds,
concurrency, per-task timeouts, and diagnostic/full evaluation modes. Every
control remains bounded by the environment's fixed constraints.

## Minimal setup pattern

```bash
#!/usr/bin/env bash
set -euo pipefail

ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR="${1:?usage: setup.sh <run-directory>}"
mkdir -p "$RUN_DIR"
RUN_DIR="$(cd "$RUN_DIR" && pwd)"

cp "$ENV_DIR/ENVIRONMENT.md" "$RUN_DIR/ENVIRONMENT.md"
cp "$ENV_DIR/run.sh" "$RUN_DIR/run.sh"
chmod +x "$RUN_DIR/run.sh"

if [ ! -e "$RUN_DIR/target" ]; then
    cp -R "$ENV_DIR/target" "$RUN_DIR/target"
fi
rm -rf "$RUN_DIR/.target_pristine"
cp -R "$ENV_DIR/target" "$RUN_DIR/.target_pristine"
printf '%s\n' "target" > "$RUN_DIR/.target"

rm -rf "$RUN_DIR/eval"
cp -R "$ENV_DIR/eval" "$RUN_DIR/eval"
```

Adapt the paths to the project. Do not copy this skeleton blindly when the
runtime imports the target from a required package path.

## Validation sequence

1. Run `validate-environment.sh <adapter-directory>`.
2. Install into a fresh temporary directory and validate the installed contract.
3. Run the smallest baseline evaluation.
4. Modify the declared target in an obvious reversible way and confirm the
   evaluator sees that exact target.
5. Launch two small evaluations with distinct artifact directories when
   concurrency is supported.
6. Confirm a finished run is still evaluable after the adapter source is moved.

Launch a custom adapter by path:

```bash
bash <FreeEvolve>/freeevolve/evolve.sh \
  <project>/.freeevolve/environments/<name> \
  <run-directory>
```
