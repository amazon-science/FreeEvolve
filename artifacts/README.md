# Research Artifacts

These are frozen outputs produced by FreeEvolve experiments. They are examples,
not runtime dependencies of the framework.

- `evolution-skills/arc-agi-3/SKILL.md` is an evolved evolution skill. Pass it as
  the optional third argument to `freeevolve/evolve.sh`.
- `evolution-skills/strong/SKILL.md` is the strongest bundled general evolution
  skill produced by meta-evolution. The launcher exposes it as `--skill strong`.
- `evolved-agents/` contains evolved edit surfaces for the named environments.
  The environment-specific source override variables are documented in
  [the running guide](../docs/running.md).

The seed evolution skill used by default is
[`freeevolve/SKILL.md`](../freeevolve/SKILL.md).
