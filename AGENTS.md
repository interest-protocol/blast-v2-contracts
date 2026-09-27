# Blast V2 contracts

Source, tests, manifests, and lockfiles own executable facts. Documentation
records decisions and task-specific operations; it must not mirror module,
error, command, version, dependency, or implementation-status inventories.

Add or amend an ADR only when a change settles a durable protocol, authority,
storage, ABI, upgrade, dependency, deployment, or cross-package decision.

## Greenfield development

Treat first-party contracts as undeployed work in progress with no users.
Change APIs and their callers together; delete obsolete paths and compatibility
wrappers. Delete removed errors and renumber each error namespace sequentially
from zero. Update exact-abort tests and source gates with the new codes; retain
only current errors, without reserved gaps or retirement tombstones. External
venue interfaces still follow their upstream ABI.

## Module layout

Use one declaration order across first-party Move sources and tests, omitting
empty sections: Constants, Package Constants, Errors, Public Types, Private
Initialization, Public Functions, Package Functions, Private Functions,
Test-Only Types, Test-Only Functions, Tests, Test Helpers, Imports. A module
may instead end with Events, Constants, Package Constants and Errors, just
before Imports (`blast_partners` does); Events then holds every struct the
module emits. Use `// === Title ===` headings. Keep imports
and receiver aliases together at the end, overriding the generic skill's import
placement. Keep domain subdivisions as ordinary comments within these sections.

Group all constants together. In error registries, put all `#[test_only]`
constants first, then all `macro public(package) fun` declarations in matching
numeric order. Keep invariant-owned local errors in their owning module.
Run `python3 scripts/check_move_style.py` after editing Move files.

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
