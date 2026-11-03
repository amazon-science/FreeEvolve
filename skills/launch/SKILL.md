---
name: launch
description: Set up and run FreeEvolve, summarize an existing evolution run, inspect local and Slurm execution backends, choose a built-in environment, or adapt a user-provided agent and evaluator to the FreeEvolve environment contract.
argument-hint: "[environment or project path] [run directory] [--summarize run-directory] [--skill seed|strong|path] [--provider bedrock|anthropic] [--model id] [--backend local|slurm] [--partition name]"
disable-model-invocation: true
license: CC-BY-NC-4.0
---

# FreeEvolve Launcher

Launch FreeEvolve for `$ARGUMENTS`. Treat this skill as an operational layer:
prepare an environment and invoke FreeEvolve, but do not add search strategy or
improvement heuristics. The evolution policy belongs to the selected evolution
skill. FreeEvolve bundles a minimal seed and a strong meta-evolved skill.

## Start

1. Introduce FreeEvolve in one sentence: it gives an evolver an editable agent
   and an evaluation function, then lets the evolver organize the improvement
   campaign.
2. List the built-ins:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/skills/launch/scripts/list-environments.sh"
   ```

3. List the available evolution skills:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/skills/launch/scripts/list-skills.sh"
   ```

4. Select the Claude Code provider and evolver model:
   - Accept `--provider bedrock|anthropic`, `--model <id-or-alias>`, and
     `--region <aws-region>`.
   - Resolve an omitted choice with:

     ```bash
     bash "${CLAUDE_PLUGIN_ROOT}/skills/launch/scripts/resolve-model.sh" \
       --provider auto
     ```

     Auto-selection honors an explicit `CLAUDE_CODE_USE_BEDROCK` value, then
     direct Anthropic credentials, then the provider reported by
     `claude auth status`. If none is detectable, it defaults to Bedrock for
     compatibility with the published configurations.
   - Tell the user the resolved provider and model before a paid run. The
     defaults are `global.anthropic.claude-opus-4-8[1m]` on Bedrock and
     `claude-opus-4-8` through regular Anthropic Claude Code. Never switch
     providers after an authentication failure without asking.
   - Bedrock uses the AWS credential chain and `AWS_REGION`. Direct Anthropic
     uses the user's Claude Code login or `ANTHROPIC_API_KEY`. Never request,
     print, or write a credential value.
   - This choice controls the model executing the evolution skill. A published
     environment's worker, user simulator, and judge models remain fixed in its
     `defaults.env`; display those IDs when summarizing the environment. A
     custom environment may define its own worker provider and model.

5. Interpret `$ARGUMENTS`:
   - If it contains `--summarize <path>`, or names a directory containing
     `ENVIRONMENT.md`, `run.sh`, `.target`, and a `workspace-*` directory,
     follow **Summarize an evolution run**. A FreeEvolve run directory takes
     precedence over treating the same path as a custom project.
   - Resolve `--skill <name-or-path>` with:

     ```bash
     bash "${CLAUDE_PLUGIN_ROOT}/skills/launch/scripts/resolve-skill.sh" \
       "<name-or-path>"
     ```

     Recommend `strong` for practical evolution. Use `seed` when the user wants
     the minimal starting point for studying or reproducing meta-evolution.
     Never silently substitute one for the other.
     Accept `--backend local|slurm` and `--partition <name>` as execution
     choices. Remove `--summarize`, model, provider, backend, partition,
     `--skill`, and their values before interpreting the remaining
     environment/project and run-directory arguments.
   - If it names `meta_chain` or `meta_chain_local`, follow
     **Launch meta-evolution**.
   - If it names a built-in environment, follow **Launch a built-in**.
   - If it is a directory or describes an external agent/evaluator, follow
     **Adapt a project**.
   - If it is empty or ambiguous, show both lists and ask which environment or
     project and which evolution skill the user wants.

After the intended environment is known, inspect the execution substrates:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/launch/scripts/inspect-execution.sh" \
  "<environment>"
```

This check distinguishes the machine running Claude Code from the machine that
will execute evolution. A missing local Docker daemon is a local-backend
constraint, not a blocker, when Slurm compute nodes are available. Never ask the
user to install or start a local service before selecting the execution backend.

If the user explicitly selected a backend, honor it. Otherwise:

- use local execution when it is the only ready backend;
- recommend Slurm when local requirements are missing and Slurm is available;
- for a costly container environment on a scheduler login node, present local
  and Slurm and recommend Slurm even if local execution is technically possible;
- ask only when both backends remain reasonable choices.

List scheduler partitions with `sinfo`; do not launch probes across every
partition. Use an explicit `--partition`, an existing Slurm default, or ask the
user to select one partition. Then verify that partition with exactly one short
compute-node preflight before submitting a paid campaign.

Run the prerequisite doctor after the backend is chosen:

```bash
FREEEVOLVE_MODEL_PROVIDER="<provider>" EVOLVER_MODEL="<model>" \
  bash "${CLAUDE_PLUGIN_ROOT}/skills/launch/scripts/doctor.sh" \
    "<environment>" "<provider>" "<local-or-slurm>"
```

Do not start a paid or long-running evolution campaign until the environment,
edit surface, metric, execution backend, run directory, and major resource
requirements are clear to the user.

## Summarize an evolution run

Treat run analysis as read-only. Do not resume evolution, invoke the evaluator,
modify the target, or repair artifacts unless the user separately asks.

First establish the run configuration:

- read `ENVIRONMENT.md` for the goal, metric, edit surface, evaluation controls,
  constraints, and declared resource budget;
- read `.target`, `.skill.md`, `.freeevolve-model.env`, `.claude/settings.json`,
  and `setup.log` to identify the target, evolution skill, provider/model,
  installed environment, and setup state;
- inspect scheduler logs when present to recover the node, partition, wall
  clock, job outcome, and infrastructure failures.

Then examine what happened:

- read `agent_trace.jsonl` and `agent_stderr.log` for the evolver's actions,
  decisions, tool calls, failures, and stopping point;
- inspect every `workspace-*` directory, including notes, candidate copies,
  checkpoints, branches, histories, `best/`, and every `RESULT.md`;
- locate evaluation artifact directories and their native result files. Use the
  metric defined by the environment rather than inventing a common schema;
- compare the initial or baseline measurement, intermediate candidates,
  confirmations, and final/best measurement when those exist;
- record task subsets, repetitions, seeds, concurrency, timeouts, token or
  dollar cost, errored trials, and wall-clock timing whenever the artifacts
  expose them;
- distinguish a low score from an invalid or infrastructure-damaged
  evaluation. Do not count missing, errored, or incomparable measurements as
  evidence of regression or improvement;
- for meta-evolution, recurse into inner run directories and connect each
  candidate `SKILL.md` to the worker campaign and score that evaluated it.

Reconstruct the campaign in chronological order using trace order, logs,
artifact metadata, and the evolver's notes. Look specifically for evolution
strategies such as:

- inexpensive subset probes followed by broader confirmation;
- changing repetitions in response to noise;
- branching, parallel exploration, or division of hypotheses;
- preserving, promoting, merging, reverting, or revisiting candidates;
- reallocating concurrency, timeouts, tasks, or evaluation budget;
- diagnosing failures from transcripts or per-task evidence before editing;
- changing direction after negative evidence;
- stopping based on evidence or resource limits.

Report a strategy only when the run contains observable evidence for it. Cite
the relevant relative paths and, when useful, the commands, task sets, scores,
or trace events. Label interpretations as interpretations rather than facts.
Do not infer a sophisticated strategy merely from the final code.

Organize the summary around:

1. **Run configuration:** environment, skill, models, target, backend, and
   budget.
2. **Evolution outcome:** baseline, best/final result, absolute improvement,
   reliability, cost, and whether the declared goal was met.
3. **Campaign trajectory:** the important candidates and decisions in order.
4. **Notable evolution strategies:** what the evolver adapted and the evidence
   showing it.
5. **Failures and caveats:** errored evaluations, missing artifacts,
   confounders, or an unfinished run.
6. **Produced artifacts:** the selected target or skill and where it lives.

Prefer a concise account of the decisions that changed the campaign over a
transcript-like inventory of every command.

## Built-in environment integrity

Treat files under `${CLAUDE_PLUGIN_ROOT}/freeevolve/envs/` as versioned,
authoritative assets. Do not delete or rewrite task lists, `TRAIN_*`, `VAL_*`,
benchmark rules, model pins, or constraints during launch.

Some source `defaults.env` files record a frozen held-out split for evaluation
and reproducibility. The corresponding `setup.sh` installs only the evolution
split and removes held-out identifiers from the run directory. This is
intentional: source metadata may describe more than the evolver is allowed to
see. Summarize the installed environment, not apparent contradictions in
source-only metadata. If source files are genuinely inconsistent, stop and
report a repository integrity issue rather than asking the user to choose a
different experimental protocol.

## Launch a built-in

1. Confirm the evolution skill, provider, and evolver model. Record their
   resolved values.
2. Resolve the environment under
   `${CLAUDE_PLUGIN_ROOT}/freeevolve/envs/<name>`.
3. Select and validate the execution backend as described in **Start**. Read the
   environment's `ENVIRONMENT.md`,
   `defaults.env`, and `README.md` when present. Summarize only the important
   prerequisites, fixed capability constraints, environment-defined worker
   model roles, data requirements, and likely setup cost.
4. Refuse to pass an evaluation-only asset such as `gaia2_cli` to `evolve.sh`;
   explain that it first needs a declared edit surface.
5. Use the supplied run directory, or propose a descriptive directory outside
   the plugin checkout. Never place a run inside
   `${CLAUDE_PLUGIN_ROOT}/freeevolve`.
6. For local execution, invoke exactly one campaign:

   ```bash
   FREEEVOLVE_MODEL_PROVIDER="<provider>" \
   EVOLVER_MODEL="<model>" \
   AWS_REGION="<region-if-bedrock>" \
     bash "${CLAUDE_PLUGIN_ROOT}/freeevolve/evolve.sh" \
       "<environment>" "<run-directory>" "<resolved-skill-file>"
   ```

7. For Slurm execution:
   - Confirm one partition and the standalone wall-clock budget. Use 12 hours
     when the user accepts the documented default; do not infer a shorter or
     longer paid run.
   - Ensure the run parent and a log directory are on storage visible to the
     compute node.
   - Run one preflight on the selected partition:

     ```bash
     FREEEVOLVE_ROOT="${CLAUDE_PLUGIN_ROOT}/freeevolve" \
     FREEEVOLVE_MODEL_PROVIDER="<provider>" \
     EVOLVER_MODEL="<model>" \
     AWS_REGION="<region-if-bedrock>" \
       sbatch --wait --parsable -p "<partition>" \
         --output="<log-directory>/preflight-%j.out" \
         "${CLAUDE_PLUGIN_ROOT}/skills/launch/scripts/slurm-preflight.sbatch" \
         "<environment>" "<run-parent>"
     ```

     Read the preflight log and stop on any failure. Do not treat a missing
     Docker daemon or Claude runtime on the submission host as evidence about
     the compute node.
   - Submit the campaign through the bundled batch launcher:

     ```bash
     FREEEVOLVE_ROOT="${CLAUDE_PLUGIN_ROOT}/freeevolve" \
     FREEEVOLVE_MODEL_PROVIDER="<provider>" \
     EVOLVER_MODEL="<model>" \
     AWS_REGION="<region-if-bedrock>" \
     EVOLVE_BUDGET_HOURS="<hours>" \
       sbatch --parsable -p "<partition>" \
         --output="<log-directory>/evolve-%j.out" \
         "${CLAUDE_PLUGIN_ROOT}/freeevolve/submit_evolve.sbatch" \
         "<environment>" "<run-directory>" "<resolved-skill-file>"
     ```

8. For a local run, stay with the process until it exits. For a Slurm run,
   capture the job ID, wait until its compute-node preflight has passed or the
   job has failed, and report the job ID, partition, log path, run directory,
   budget, and monitoring command. Do not leave a failed submission
   unreported.

## Launch meta-evolution

Meta-evolution edits the evolution skill rather than a worker. Each call to its
evaluation function launches a complete inner worker-evolution campaign using
the candidate `SKILL.md`.

1. Confirm the starting evolution skill and outer evolver model. `seed` studies
   learning from the minimal policy; `strong` continues improving the bundled
   meta-evolved policy. The selected file becomes both the outer evolver and,
   unless deliberately overridden, the initial editable `SKILL.md`.
   The inner evolver uses the same provider and model by default.
   `INNER_EVOLVER_MODEL` or `INNER_EVOLVER_MODEL_<ENV>` may deliberately pin a
   different inner model; report that distinction before launch.
2. Ask the user to select one or more non-meta worker environments from
   `${CLAUDE_PLUGIN_ROOT}/freeevolve/envs/`. Do not leave
   `META_INNER_ENVS` unset: an explicit selection avoids copying and preparing
   every environment when only a few provide the intended meta-evolution data.
3. Explain that the selected environments define the experience used to improve
   the evolution skill. A comma-separated selection such as
   `tau3,arc_agi_3` allows the meta-evolver to test candidate skills in both.
4. Reject meta-environments and evaluation-only assets as inner environments.
   Every selected entry must install a worker edit surface.
5. If the required data or evaluator is not represented yet, follow
   **Adapt a project** first. For meta-evolution, place the validated,
   self-contained adapter under
   `${CLAUDE_PLUGIN_ROOT}/freeevolve/envs/<name>/` so the meta setup can copy it
   into its private inner-environment catalog.
6. Clarify the backend:
   - `meta_chain_local`: local inner runs with worker inheritance;
   - `meta_chain`: Slurm inner runs with worker inheritance.
   `meta_chain` requires `sbatch`, `squeue`, and storage shared with its compute
   nodes. It is not a fallback for an ordinary local machine; use
   `meta_chain_local` there.
7. Check prerequisites for the meta-environment and every selected inner
   environment. Then launch:

   ```bash
   FREEEVOLVE_MODEL_PROVIDER="<provider>" \
   EVOLVER_MODEL="<outer-model>" \
   AWS_REGION="<region-if-bedrock>" \
   META_INNER_ENVS="<comma-separated-environments>" \
     bash "${CLAUDE_PLUGIN_ROOT}/freeevolve/evolve.sh" \
       "<meta-environment>" "<run-directory>" "<resolved-skill-file>"
   ```

   Add `INNER_EVOLVER_MODEL="<inner-model>"` only when the user deliberately
   wants it to differ from the outer model.

The launcher selects the available experience and execution backend. The outer
evolver decides which inner campaign to run next, how to interpret its evidence,
and how to revise `SKILL.md`.

## Adapt a project

Read
`${CLAUDE_PLUGIN_ROOT}/skills/launch/references/environment-contract.md`
before editing anything.

1. Inspect the project with the user-supplied agent and evaluator. Identify:
   - the exact file or directory the evolver may edit;
   - the evaluator command and immutable benchmark assets;
   - the primary metric and where results are written;
   - useful evaluation controls such as subsets, repetitions, seeds,
     concurrency, and timeouts;
   - fixed model, hardware, time, or integrity constraints.
2. State the proposed edit surface, evaluation command, metric, and constraints
   before creating the adapter.
3. Create a self-contained adapter at
   `<project>/.freeevolve/environments/<name>/`. It must install a standalone
   run directory and must not require modifications to FreeEvolve itself.
   If the user intends to use it for meta-evolution, copy the validated adapter
   into `${CLAUDE_PLUGIN_ROOT}/freeevolve/envs/<name>/` only after confirming
   that destination with the user.
4. Validate the adapter:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/skills/launch/scripts/validate-environment.sh" \
     "<adapter-directory>"
   ```

   When setup is cheap and credentials are available, also validate an
   installation in a fresh temporary directory and run the smallest practical
   baseline evaluation.
5. Launch by passing the adapter directory as the environment argument:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/freeevolve/evolve.sh" \
     "<adapter-directory>" "<run-directory>" "<resolved-skill-file>"
   ```

Keep the evaluator and answer-bearing data outside the declared edit surface.
Never weaken benchmark rules to make an adapter easier to build.

## Installation handling

- Diagnose before changing the machine.
- For straightforward user-space prerequisites, explain the command and install
  only after the user agrees.
- For Docker permissions, model authentication, gated data, system packages, or
  scheduler access, report the exact missing prerequisite and the command or
  account action needed. Do not bypass it.
- Re-run the relevant check after any installation.
