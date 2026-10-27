# Blast V2 contracts

Source, tests, manifests, and lockfiles own executable facts. Documentation
records decisions and task-specific operations; it must not mirror module,
error, command, version, dependency, or implementation-status inventories.
The one exception is the integrator references, `llms-full.txt` and the
per-product files under `llms/`, that `scripts/gen_llms.py` generates from
source; CI fails when they are stale.

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

- Explaining a package or routing a question about the contracts: `llms.txt`.
- Changing a public function, type, event, error, fee, or flow:
  `docs/llms/AUTHORING.md`; update the affected guide in `docs/llms/` and
  regenerate `llms-full.txt` and `llms/` with `python3 scripts/gen_llms.py`.
- Package or contract/SDK boundary: `docs/architecture.md`.
- Naming a module, one-time witness, coin, or event type that appears on an
  explorer: `docs/explorer-naming.md` and ADR 0085.
- Product inclusion or deferral: `docs/protocol-scope.md`.
- Numerical compatibility or release evidence: `docs/testing.md` and
  `docs/vectors/`.
- Leverage contracts: `docs/leverage-implementation-lessons.md` and the
  applicable accepted ADR.
- Launchpad, presale or their venue ABI: the source and documentation moved to
  `https://github.com/interest-protocol/blast-v2-move`; this checkout retains
  historical publication records.
- Package publication: `deployments/README.md`; for Blast SUI, also use
  `sui/blast_sui/DEPLOYING.md`.
- Blast SUI upgrade: `sui/blast_sui/UPGRADING.md`.
- Partner one-off contract: `https://github.com/interest-protocol/blast-v2-move/tree/main/sui/vendors`
  and ADR 0104.

## Unrelated issues found during a task

When you discover an actionable issue outside the current task, file a GitHub
issue in the owning repository and continue the current task. This instruction
authorizes filing these issues without asking for confirmation each time.
Search existing issues first; reuse a matching issue and add only new evidence.
Include the impact, affected files or components, reproduction steps or concrete
evidence, and expected versus actual behavior. Distinguish confirmed findings
from hypotheses and keep credentials and private data out of issue content.
Keep fixes scoped to the current task unless the unrelated issue blocks it or
the user expands the scope. Include created or reused issue links in the final
handoff. If GitHub access prevents filing, report the blocker and the finding
in the handoff so it is not lost.
