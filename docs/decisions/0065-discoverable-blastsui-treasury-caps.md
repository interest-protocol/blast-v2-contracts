# 0065: Discoverable blastSUI treasury-cap custody

- Status: accepted
- Date: 2026-09-01
- Amends: [0053](0053-single-validator-funsui-and-blastsui.md)

## Sources

| Short ref | Full commit |
| --- | --- |
| `sui@06734f6` | `06734f6ff0af45d8632a14a4dc4b100197f6b1a2` |

## Context

The vault must hold each unique `TreasuryCap` so only its checked mint and burn
transitions can change `funSUI` or `blastSUI` supply. Supply must also remain
discoverable through standard Sui object and coin-info infrastructure, not only
through Blast-specific vault decoding and event replay.

An ordinary struct field wraps a capability into the shared vault. The pinned
framework provides dynamic object fields specifically so a `key + store` child
remains an object in storage for external tools while Move access still passes
through the parent's `UID`
(`sui@06734f6:crates/sui-framework/packages/sui-framework/sources/dynamic_object_field.move:4-32`).
Coin Registry already records the original treasury-cap object ID when the
currency is created
(`sui@06734f6:crates/sui-framework/packages/sui-framework/sources/registries/coin_registry.move:209-232`).

## Decision

The shared `Vault` owns both treasury caps as type-keyed dynamic object fields.
`TreasuryKey<FUN_SUI>` names the `TreasuryCap<FUN_SUI>` child and
`TreasuryKey<BLAST_SUI>` names the `TreasuryCap<BLAST_SUI>` child.

Only private vault helpers add or borrow these children. Every mint, burn,
solvency check, quote, and final event snapshot reads the canonical supply from
the corresponding child cap. The caps have no release or removal path. The
vault has no duplicate supply field.

The SDK reads the shared vault and both named child objects, validates each
child’s type, identity, and parent owner, and derives live supply from the
child’s native `Supply`. It serializes the Move 2024 empty positional key as the
compiler-generated `dummy_field: false` Boolean when deriving each field ID.
Replay consumers can continue to use the final supply snapshots in completed
vault events.

## Alternatives considered

- **Inline treasury-cap fields.** Vault mutations remain safe, but the native
  cap objects are wrapped and standard external discovery cannot read them.
- **Ordinary dynamic fields.** These wrap the cap as the value of a generated
  field object, so they do not meet the object-visibility requirement.
- **Top-level or shared treasury caps.** These expose mint and burn authority
  outside the vault's invariant-preserving transitions.
- **Duplicate supply counters.** These create a second source of truth beside
  the framework `Supply` and can diverge.

## Consequences

Standard Sui infrastructure can follow each Coin Registry treasury-cap ID to a
live object and recover total supply. The vault retains exclusive mutation
control through child ownership. Vault reads now require two fixed child reads,
but no enumeration, unbounded collection, or new mutable accounting state.

The child key types and storage shape are publication commitments. A future
terminal vault lifecycle must explicitly retain, migrate, or consume both
children before the parent can be destroyed.

## Verification

- Build, lint, and test the package with the pinned Sui toolchain.
- Test mint and burn sequences through both dynamically stored caps.
- Decode and validate both child caps in SDK state-read tests.
- On each target network, verify coin-info returns both cap IDs and live supply
  after creation, mint, and burn.
