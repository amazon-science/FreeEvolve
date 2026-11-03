# GAIA2, CLI mode — an evaluation environment

This measures an agent on GAIA2 and declares no edit surface. There is no
`.target` and no `ENVIRONMENT.md`, because nothing here has been picked as the
thing to improve. It exists to answer one question first: what does a stock agent
score, and does the machinery run at all on this cluster.

## What a task is

One GAIA2 scenario: a simulated world of ~12 apps with populated state (emails,
chats, calendar, contacts, shopping, files, apartments, cabs — around 2.4 MB of
it), a user request, and an oracle sequence of the actions a correct agent would
take. The world runs on ARE (Meta's Agents Research Environments) inside a sidecar
container that exposes each app method as an individual MCP tool, roughly 101 of
them, plus `are_wait_for_notification` and `are_get_time`.

The simulated clock is paused and only advances when the agent acts, so an
"asynchronous" scenario is deterministic in wall-clock terms but not in ordering.

Five configs, 160 validation scenarios each, 800 total, no train split:

| config | what it turns on | how it is scored |
| --- | --- | --- |
| `search` | retrieval and arithmetic over app state | the final user-facing answer |
| `ambiguity` | under-specified requests | the final user-facing answer |
| `execution` | multi-step tool work | the write-actions taken |
| `time` | events arriving mid-episode | the write-actions taken |
| `adaptability` | the plan has to change mid-episode | the write-actions taken |

## How it is scored

Two modes, routed by config, both in the adapter's `llm_judge.py`.

**Answer mode** (`search`, `ambiguity`). The agent's last message to the user is
compared with the oracle answer: exact match after normalization, else a
reward-hacking sanity filter, else an LLM judge. Binary.

**Action mode** (`execution`, `time`, `adaptability`). The agent's write-actions
are matched against the oracle's, one LLM judgment per candidate pair, over a
whitelist of 28 canonical write tools; reads are ignored. Then:

```
reward = matched_fraction if counts_match else 0.0
```

`counts_match` demands the agent's write-tool multiset equal the oracle's exactly,
tolerating one extra message to the user. **One surplus write call scores a
perfect trajectory at zero.** This is worth knowing before reading any number from
these three configs: the metric is a fraction gated by an equality, so it is
neither binary nor continuous, and an agent that does more than asked is
indistinguishable from one that did nothing.

## What is patched, and what is not

The upstream verifier calls an OpenAI-compatible endpoint. There is no OpenAI key
here and every other model role on this cluster runs on Bedrock, so `setup.sh`
copies the adapter out of the harbor checkout and `patch_adapter.py` swaps the
judge's transport to LiteLLM/Bedrock and its default model.

The rubric is untouched: prompts, alias tables, write-tool whitelist, the count
gate, and the answer/action routing are exactly as upstream wrote them. Every
substitution is asserted, so an upstream edit fails the patch instead of silently
restoring the OpenAI path.

A number from here is therefore comparable to the adapter's own reported numbers
only as far as the *judging* is comparable, and the judge model is already
different. Reference points the adapter publishes, both on its deterministic
100-task subset: the ARE native `default` agent with gpt-5-mini scores 6%, and
`opencode` with gpt-5-mini in this CLI mode scores 15% (search 12/20, ambiguity
3/20, and zero task-level passes across the three action-mode configs).

## Setting up and running

```bash
# a two-task smoke test
GAIA2_CONFIGS=search GAIA2_LIMIT=2 ./setup.sh <run_dir>

# the deterministic 100-task subset the adapter reports against
GAIA2_IDS_FILE=parity ./setup.sh <run_dir>

# all 800
./setup.sh <run_dir>

cd <run_dir>
./run.sh --artifacts evals/base --concurrency 8
```

There is no oracle path here. CLI-mode tasks are generated without a `solution/`
directory, so `--agent oracle` has nothing to run; the oracle exists only in the
adapter's native mode, where it scores 800/800. A CLI-mode failure therefore has to
be attributed by reading logs — the agent's, the sidecar's, and the verifier's —
rather than by comparing against a reference run.

Generation downloads the official dataset from HuggingFace: ~400 MB per config,
and every scenario is a ~2.5 MB JSON, so the full set is around 2 GB in each
place it lands. `GAIA2_DATASET_SRC=<dir>` reuses an already-generated task
directory instead.

## Costs and limits worth knowing before a full run

- Two containers per task-attempt, so concurrency `n` puts `2n` containers on the
  node — the same arithmetic as tau3.
- The task allows the agent 2400 s and the verifier 300 s; images take up to
  1800 s to build the first time, because each one installs ARE and snapshots the
  official GAIA2 filesystem dataset. Those layers sit above the per-task `COPY`,
  so they are paid once per node rather than once per task.
- Three model roles are billed per attempt: the agent, the judge, and whatever
  small model the agent's own scaffold uses internally.
- The adapter documents `time` notification delivery in paused mode as an open
  issue and its own judge as "a Harbor-side approximation" of ARE's. Numbers from
  those configs inherit that.
