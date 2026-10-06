# 0051: Generated Meme package template

- Status: accepted; publish-time immutability amended by [0088](0088-reusable-launch-accounting-and-atomic-migration.md);
  package renamed `launch_ticket_template` by [0108](0108-standalone-coin-template.md)
- Date: 2026-08-29
- Amends: [0001](0001-sui-package-and-module-layout.md),
  [0002](0002-coin-creation-and-currency-authority.md),
  [0048](0048-sui-package-workspace.md)

> ADR 0088 keeps the one-time-witness initializer and the ticket transfer to
> the publisher, but generated packages stay upgradeable: the publisher keeps
> the `UpgradeCap`, so step 6 and the SDK's immutable-call check are optional
> publishing choices rather than requirements.

## Sources

| Ref | Full commit | Repository |
| --- | --- | --- |
| `blast-v1@5c23808` | `5c2380830a759cfd7d2f4d3f1ee0826bf788c20a` | interest-protocol/blast.fun |
| `mysten-ts@1056b78` | `1056b789cb3d69250ff41d11dfabb383587e6b0c` | MystenLabs/ts-sdks |

## Context

Blast launch intake accepts only a `LaunchTicket<Meme>` created from the
generated Meme package's one-time witness. The core constructor and tests exist,
but the Sui workspace has no external package that exercises the intended
initializer boundary. Premise P6 in ADR 0002 therefore remains unconverted.

Each generated package must also fix its metadata, supply mode, and sell-burn
selection before publication. These values cannot be transaction arguments to
a Sui module initializer.

Blast V1 fetched a compiled module, patched its identifiers and BCS constants,
and returned the modified bytecode
(`blast-v1@5c23808:src/lib/move-template/coin.ts:75-107`). Its launch form then
published that module and passed the returned upgrade capability to
`package::make_immutable`
(`blast-v1@5c23808:src/app/(root)/launch/_hooks/use-launch-coin.ts:83-97`).
V2 needs the same client-side generation model, but the compiled initializer
must delegate currency creation and ticket custody to Blast.

## Decision

Add one buildable package at `sui/meme_template/`. Its module:

- defines the package's one-time witness;
- selects either an address or X creator identity from one fixed 32-byte payload
  and a boolean discriminator;
- calls `blast_fun::launch_ticket::new` with package-local metadata, supply mode,
  and sell-burn literals; and
- transfers the returned `LaunchTicket<Meme>` to the publishing sender.

The creator identity and publisher are separate. Address mode can name an
address other than the publisher. X mode stores the 32-byte X identity hash.
The publisher receives the ticket in either mode so it can create the launch.

Compile that source package once with the pinned Sui toolchain. The SDK embeds
the resulting one-module bytecode as the production template. For each launch,
the SDK:

1. initializes Mysten's Move bytecode template WASM;
2. verifies and patches the module and witness identifiers;
3. verifies and patches the exact BCS constant-pool slots for symbol, name,
   description, icon URL, the 32-byte creator payload, creator kind, burn mode,
   and sell-burn basis points;
4. replaces the template's sole non-system dependency address with Blast's
   original package ID;
5. publishes the module with dependencies `0x1`, `0x2`, and the selected active
   Blast package object; and
6. consumes the returned upgrade capability with `0x2::package::make_immutable`.

Mysten's library deserializes a compiled module to a patchable representation
and serializes it back to bytecode
(`mysten-ts@1056b78:packages/move-bytecode-template/src/lib.rs:30-37`,
`mysten-ts@1056b78:packages/move-bytecode-template/src/lib.rs:202-213`). Its
identifier updater validates replacements and rewrites the affected table
indexes (`mysten-ts@1056b78:packages/move-bytecode-template/src/lib.rs:52-123`).

The checked-in Move source is compiler input and review evidence. Launches do
not copy or edit that source and do not invoke a compiler. The package ID gives
the Meme type its consensus identity; patched names make the resulting type path
recognizable to users and indexers.

The source template depends inward on the local `sui/launchpad/` package for
workspace builds. Its compiled bytecode contains one Blast dependency slot.
Production generation replaces that slot with Blast's original package ID and
uses the active package version in the publish dependency list. It does not
publish another launchpad copy.

**Premise T1:** Sui dependency linkage requires the original package ID inside
module bytecode and the selected active package object in the publish dependency
list. Falsify T1 by publishing the template against an upgraded Blast testnet
deployment whose original and active IDs differ; the transaction must pass the
verifier and the initializer must execute the active `launch_ticket::new`.

## Alternatives considered

**Create the currency directly in the generated package.** Rejected because it
would duplicate supply and capability handling outside Blast and weaken ticket
provenance.

**Add a public setup function after publication.** Rejected because it would
permit repeated calls and would not consume the package's one-time witness at
the initializer boundary.

**Compile edited Move source for every launch.** Rejected because it would add a
compiler service or toolchain to the launch request path. A reviewed bytecode
template has fewer moving parts and matches the established V1 browser flow.

**Keep the example module and witness identifiers.** Viable for consensus
identity because every package ID is unique, but rejected for product clarity.
Patching both identifiers yields recognizable type paths without adding state
or authority.

**Compile separate address and X templates.** Rejected because the identity
payload has the same 32-byte width in both modes. One boolean discriminator
keeps one reviewed artifact and avoids choosing between bytecode blobs in the
SDK. The small initializer branch runs only during package publication.

## Consequences

- The generated package contains no mint, metadata-cap, or treasury-cap logic.
- Blast remains the sole owner of currency creation, supply finalization, and
  pre-launch custody.
- The initializer's direct transfer is deliberate because an initializer cannot
  return an owned value to its publisher.
- Creator attribution can name the publisher, another Sui address, or an X
  identity without changing ticket custody.
- Generated packages cannot be upgraded after publication.
- The SDK is responsible for bytecode-template initialization, strict slot
  validation, dependency replacement, transaction construction, and tests.
- Building the template with the pinned Sui toolchain converts P6 into compile
  evidence.

## Verification

From `sui/meme_template/`, run:

```bash
sui move build
sui move lint --warnings-are-errors
bash scripts/check_source_boundaries.sh
```

The source must contain one OTW, both creator constructors, one
`launch_ticket::new` call, and one transfer of its returned ticket to
`ctx.sender()`.

From the SDK repository, run:

```bash
npm run typecheck
npm test
```

SDK tests deserialize the generated module, confirm all eight patched constants
and both creator constructors, resolve `launch_ticket::new` to Blast's original
address, distinguish that address from the active publish dependency, confirm
all three dependencies, and require the immutable-package call. A release smoke
test must run the T1 falsification case before enabling an upgraded Blast
deployment.
