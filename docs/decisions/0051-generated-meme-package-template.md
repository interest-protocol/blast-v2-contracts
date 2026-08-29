# 0051: Generated Meme package template

- Status: accepted
- Date: 2026-08-29
- Amends: [0001](0001-sui-package-and-module-layout.md),
  [0002](0002-coin-creation-and-currency-authority.md),
  [0048](0048-sui-package-workspace.md)

## Context

Blast launch intake accepts only a `LaunchTicket<Meme>` created from the
generated Meme package's one-time witness. The core constructor and tests exist,
but the Sui workspace has no external package that exercises the intended
initializer boundary. Premise P6 in ADR 0002 therefore remains unconverted.

Each generated package must also make its immutable metadata, supply mode, and
sell-burn selection before publication. These values cannot be transaction
arguments to a Sui module initializer.

## Decision

Add one buildable package at `sui/templates/blast_fun_template/`. Its only
module:

- defines the package's one-time witness;
- uses the publishing sender as the address creator identity;
- calls `blast_fun::launch_ticket::new` with package-local metadata, supply mode,
  and sell-burn literals; and
- transfers the returned `LaunchTicket<Meme>` to the publishing sender.

The checked-in package uses safe example values. A generated package changes
only the metadata and policy literals before publication. The module and witness
names can remain stable because the published package ID makes each Meme type
unique.

The template depends inward on the local `sui/launchpad/` package for workspace
builds. Production generation must resolve that dependency to the intended
published Blast package and must not publish another launchpad copy.

## Alternatives considered

**Create the currency directly in the generated package.** Rejected because it
would duplicate supply and capability handling outside Blast and weaken ticket
provenance.

**Add a public setup function after publication.** Rejected because it would
permit repeated calls and would not consume the package's one-time witness at
the initializer boundary.

**Generate a different module and witness name for every Meme.** Rejected
because the original published package ID already gives each type a unique
identity. Only metadata and selected policy values need generation.

## Consequences

- The generated package contains no mint, metadata-cap, or treasury-cap logic.
- Blast remains the sole owner of currency creation, supply finalization, and
  pre-launch custody.
- The initializer's direct transfer is deliberate because an initializer cannot
  return an owned value to its publisher.
- Building the template with the pinned Sui toolchain converts P6 into compile
  evidence.

## Verification

From `sui/templates/blast_fun_template/`, run:

```bash
sui move build
sui move lint --warnings-are-errors
bash scripts/check_source_boundaries.sh
```

The source must contain one OTW, one `launch_ticket::new` call, and one transfer
of its returned ticket to `ctx.sender()`.
