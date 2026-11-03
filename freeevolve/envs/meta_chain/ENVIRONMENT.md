# Environment: meta_chain

## Goal

Improve the evolver itself, and get the inner agent as good as you can **in every
inner environment installed here**.

`SKILL.md` is the instructions given to an agent whose job is to improve some
other agent against some other goal. Your job is to make those instructions
produce better evolvers.

The inner setting is the same one you are in. An inner evolver is handed a run
directory with an environment installed in it, and works there until it is done.
Whatever it does in between — how it works, what it records, how it spends its
evaluations — is determined by `SKILL.md` and nothing else.

**There may be more than one inner environment.** The ones installed for this run
are the directories under `eval/freeevolve/envs/`; `setup.log` lists them by name.
Every one of them is part of the goal. A skill that improves the agent in one and
leaves another where it started has done part of the job, and an environment with
no inner run against it has no result at all.

Two things matter here, and they are not the same thing:

**The skill you leave behind.** It is the edit surface, and it is what outlives
this run.

**How far the inner agent actually got.** An inner run's improvements do not have
to be thrown away when it ends. `--from` starts a new inner run from an agent an
earlier one produced (see "How to evaluate"), so a later run begins where an
earlier one stopped instead of solving the same problems again. Improvements can
therefore stack across inner runs, and how good the agent becomes is a real
result of this run, not just a by-product of testing the skill.

These two pull on each other. An inner run tells you something about the skill
that ran it, and it also leaves an agent. A sequence of runs that stack tells you
more about the skill under sustained use than a single run does — and it is also
how the agent gets furthest. Neither reading is the whole of the goal.

## Key metric

How much better an inner evolver became at improving agents, and how good the agents
this run leaves behind are, in each inner environment installed here.

A better evolver improves more environments, and moves each one by a larger margin —
breadth and size are both part of what better means here.

There is no number here that says so. An evaluation produces an inner run
directory, and what that run achieved is legible only inside it: the inner
environment states its own key metric and its harness writes its own results, so
every evaluation the inner evolver chose to run is recorded there in that
environment's terms.

Reading a run is therefore part of the work, not something done for you. Nothing
aggregates those results into a score, because there is no aggregation that would
be right for every inner environment — each has its own metric and its own data —
and because what makes an evolve run good is not obviously a scalar. Two runs are
only as comparable as the evaluations they happened to run.

An inner run that inherited an agent is measuring from a different starting point
than one that did not, so their reported gains are not the same quantity. What is
comparable across every inner run, inherited or not, is the absolute quality of
the agent it ended with, measured on the inner environment's own terms.

Results from different inner environments are not comparable to each other and do
not add up: each environment has its own metric, its own data and its own starting
agent. So there is no single number for this run, and no environment's result
substitutes for another's. Each one is read on its own terms, and each one stands
or does not.

That is also the hard part of the goal. Deciding what counts as a better evolver,
what counts as a better agent, and what evidence would show either, is yours.

## Edit surface

`target/SKILL.md` — the evolver's instructions. This is what the evaluation runs,
always. Edit it in place.

This file is also the thing you are improving, so it is what any version you keep,
compare, or nominate refers to. Inner runs produce agents of their own, and a good
one is a real result worth recording — but it is an inner environment's agent, not
yours, and it is not what leaving your best behind means here. What outlives this
run is the skill.

The inner environments are not yours to edit. If an inner run scores well because
its environment got easier, nothing was learned.

### The dispositions

`SKILL.md` has two parts and they are not the same kind of thing. It opens with a
section stating who the evolver is — currently `## Who you are` — and everything
after that is method: what to measure, in what order, with what care.

Method is what you are here to improve. The dispositions are what method serves,
and they stay as they are: keep that section, and keep what it means. An edit that
reverses one of them is not an improvement to the skill, it is a change to what the
skill is for — and it is a change this evaluation cannot price, because a
disposition's whole effect is on how long and how hard a later evolver keeps
looking. The run that weakens one still measures fine. The cost lands on the next.

The obvious way to weaken that section is to delete it. The easier way is by
addition: a caution that is true, well-argued, and drawn from something that really
did go wrong, which nonetheless tells the evolver to stop where a disposition tells
it to keep going. Every word is still in the file and none of them decide anything
any more. So check what you add against that section, and say what you checked —
when a new paragraph and a disposition would give different instructions in the
same situation, the disposition wins and the paragraph is what needs rewriting.

Sharpening them is a different matter, and it is welcome. Saying what a disposition
looks like in a concrete situation, what evidence satisfies it, or how to act when
two of them pull in different directions is method in the best sense. The line is
between making a disposition operational and overruling it.

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
| `--inner-env <name>` | which inner environment to evolve against (required). One per invocation; the installed names are the directories under `eval/freeevolve/envs/` | |
| `--from <dir>` | start the inner run from an agent an earlier inner run produced **in the same inner environment** | that environment's own starting agent |

Two of the installed inner environments -- `dummy` and `gaia2_cli` -- have no
way to be handed a starting agent, and ignore `--from`: a run against either
always starts from the agent the environment ships.

### `--from`

Without it, an inner run starts from whatever agent its environment ships, so
every evaluation begins from the same place and its inner evolver has the same
work to do.

With it, the inner run starts from an agent that already carries an earlier run's
improvements. This is what lets improvements stack.

The directory you name must hold that environment's edit surface — the same files
the inner environment declares in its own `.target`, and it must be a directory
that holds an agent, not the run directory around it.

An agent belongs to the environment it was built in. Each inner environment declares
its own edit surface, with its own files and its own entry point, so an agent produced
in one cannot start a run in another. Lineages stack within an environment, not
across them.

A finished inner run usually contains several such directories, not one:

- **What it nominated as its best.** An inner evolver is asked to leave its
  strongest agent in its workspace, at `best/`, with a note saying what it scored
  and why the evidence says it is strongest. That is the run's own answer to
  "which version should be carried forward", and it is the obvious place to start
  reading.
- **What its `.target` path holds** — the agent as the run left it, which is what
  its last evaluation measured. Usually the same as its `best/`, but not
  necessarily: it is a last state, not automatically a best one.
- **The intermediates it kept** — the version it started from, and the candidates
  it evaluated along the way, wherever in its workspace it chose to put them and
  under whatever names it chose.

Each of those was measured, and its score is in that run's own results.

So there is a best, and the run says which it thinks it is. Whether to take that
nomination is still a question about the run's evidence rather than a path
convention: a nomination is a claim, and what backs it is in the run. A run's last
state may be a version it kept for reasons that do not apply to you; an
intermediate it set aside — a single mechanism fix without the prose changes
bundled on top, say — may be the cleaner thing to build on. Nothing here ranks
them for you.

It must point inside this run directory. An agent from outside it would make
these results depend on work that is not here, and a number reached that way
says nothing about the evolver being measured.

Two things follow from using it, and they are easy to get wrong:

- **The inner run's baseline is the agent it was handed**, not the environment's.
  Its own report of how much it improved is relative to that. Gains from a run
  started with `--from` and gains from one started without it are not the same
  measurement and do not add up. Absolute scores still are.
- **The inner evolver is not told.** It reads its environment, finds an agent at
  the edit path, and works. Nothing marks that agent as inherited, so a run that
  starts further along looks, from inside, exactly like one that does not.

**This is the only way improvements from separate runs combine.** Without it, every
inner run begins from the environment's own worker agent. A cold run therefore
measures the quality of the evolver skill and nothing more: whatever it found is left
where it found it. With it, a run inherits what the one before it found and spends its
effort past that point.

That matters most for improvements too small to see on their own.
Such stacking can turn small improvements into a noticeable one.

How deep to go, when to abandon a lineage and start fresh, how many lineages to keep
going at once, and which agent out of a finished run to build on — all yours. Nothing
here ranks them for you, and nothing here stops you.

The available inner environments are the directories under
`eval/freeevolve/envs/`. Each has its own `ENVIRONMENT.md` stating the goal an
inner evolver faces there, its system, and what data they run on. They differ in
this: some hold a set back, some measure on everything they have.

### Duration

An evaluation here runs one inner evolve loop, which takes as long as its evolver
takes to finish — hours, typically. Invocations with different `--artifacts`
directories are independent, so several can be in flight at once and a sequence
that has to wait for its predecessor is limited by how long each link takes.

**You have @@BUDGET_HOURS@@ hours of wall clock from the moment this run starts.** Nothing stops
the job before then, and nothing continues it afterwards. Since an inner run is
hours rather than minutes, that is a small number of sequential links and a larger
number of concurrent ones.

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
                  results of every evaluation it ran and, usually, copies of the
                  agent versions it tried. Named for the inner environment, so it
                  never collides with your own workspace.
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

**So do not stop at the report.** A write-up is a summary made at one moment by
someone who was still working, and it can be stale, incomplete, or simply mistaken
without anyone having been dishonest. A run's summary may name one number while its
results hold another; a conclusion it reached early may survive into the write-up
after its own later evaluations contradicted it; a version it measured well may go
unmentioned because it was measuring something else at the time. None of that is
visible from the summary — a summary that disagrees with its own results reads
exactly like one that does not.

When something matters — which version is actually best, whether a gain is real,
what a run actually did — go to the artifact. The per-evaluation results say what
was measured and on how many attempts; the agent directories say what the versions
actually are; `agent_trace.jsonl` says what the run did rather than what it says it
did. Every claim in a write-up has something underneath it that can be checked, and
the cost of checking is reading a file.
