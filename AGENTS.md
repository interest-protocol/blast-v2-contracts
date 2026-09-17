# Blast V2 contracts

Source, tests, manifests, and lockfiles own executable facts. Documentation
records decisions and task-specific operations; it must not mirror module,
error, command, version, dependency, or implementation-status inventories.

Add or amend an ADR only when a change settles a durable protocol, authority,
storage, ABI, upgrade, dependency, deployment, or cross-package decision.

## Sui Move coding and review

For Sui Move design or implementation, read
[sui-move-guide](.agents/skills/sui-move-guide/SKILL.md) and apply the focused
standards selected for the affected boundaries.

For Sui Move code review, including both quality and behavior ticket reviewers,
read [sui-move-review](.agents/skills/sui-move-review/SKILL.md), its four required
focused standards, and every triggered reference. Reviewers use the same
standards as implementers. Preserve accepted repository decisions and the
assigned review scope; report inaccessible required guidance as a review gap.

## Conditional context

Load only the branch the task changes:

- Package or contract/SDK boundary: `docs/architecture.md`.
- Naming a module, one-time witness, coin, or event type that appears on an
  explorer: `docs/explorer-naming.md` and ADR 0085.
- Product inclusion or deferral: `docs/protocol-scope.md`.
- Numerical compatibility or release evidence: `docs/testing.md` and
  `docs/vectors/`.
- Leverage contracts: `docs/leverage-implementation-lessons.md` and the
  applicable accepted ADR.
- Venue dependency or live ABI: `sui/migrators/DEPENDENCIES.md`.
- Package publication: `deployments/README.md`; for Blast SUI, also use
  `sui/blast_sui/DEPLOYING.md`.
- Blast SUI upgrade: `sui/blast_sui/UPGRADING.md`.
