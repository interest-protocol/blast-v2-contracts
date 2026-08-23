# Reference review

Reviewed on 2026-08-21. References are pinned here so future changes in their
default branches do not silently rewrite the rationale for Blast V2.

| Repository | Reviewed commit | Tracked files | Use |
| --- | --- | ---: | --- |
| [interest-protocol/su-lending](https://github.com/interest-protocol/su-lending/tree/a3552af11a531717378b6337a174f9340d1099dc) | `a3552af11a531717378b6337a174f9340d1099dc` | 290 | Primary Sui Move house-style, engineering, and audit reference |
| [interest-protocol/memez-gg](https://github.com/interest-protocol/memez-gg/tree/00596fdac4dd11f427c7bc594e566ce36160db93) | `00596fdac4dd11f427c7bc594e566ce36160db93` | 135 | Historical Blast behavior and integration reference |

Focused authority review on 2026-08-22 additionally checked the Memez lockfile's
pinned [Interest access-control package](https://github.com/interest-protocol/interest-mvr/tree/91e2f4f83626c1cb924bac246932574501c21bf8/access-control/contracts)
at `91e2f4f83626c1cb924bac246932574501c21bf8` and OpenZeppelin Contracts
v5.7.0 at [`cab19933c33c2ad1d4c7a84864a3601dddfd16f3`](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/cab19933c33c2ad1d4c7a84864a3601dddfd16f3).
The detailed comparison is in
[research/admin-and-signer-authority-patterns.md](research/admin-and-signer-authority-patterns.md).

Every tracked blob was inventoried and content-read at the commits above. The
review then treated authored guidance, contracts, tests, SDK/deployment scripts,
manifests, lockfiles, deployment JSON, vendored code, images, and generated
coverage artifacts according to their evidentiary value. Generated `.trace` and
`.mvcov` files were inspected as build artifacts, not contract design guidance.

## What su-lending contributed

The detailed `packages/su` house-style inventory and Blast alignment checklist
is in [research/su-package-house-style.md](research/su-package-house-style.md).

Adopted:

- guard-before-mutation discipline and explicit abort precedence;
- pure math with named rounding direction, wide intermediates, bounds, and
  adversarial tests;
- composable Sui functions that return owned values instead of self-transferring;
- package-wide numeric error macros, caller-local assertions, stable error maps,
  a generic event envelope with test-only unwrapping, narrow visibility, bounded
  persistent collections, and hard lint gates;
- event streams capable of replaying final accounting state;
- explicit upgrade/version posture and recognition that old Sui package versions
  remain callable;
- immutable dependency revisions and isolation of external dependencies in
  adapters;
- builder, edge, expected-abort, randomized, deployment, and smoke-test habits;
- gRPC/Core API SDK design with normalized, versioned deployment records.

Adapted rather than copied:

- Lending-specific debt/collateral rounding became a general beneficiary-based
  rounding policy for curves, fees, allocation, and migration.
- The multi-package layout became a boundary rule, not a template. Blast begins
  with one core package/project per chain.
- Event replay covers Blast lifecycle, reserves, fees, configuration,
  allocations, and migrations rather than lending positions/oracle snapshots.
- Sui capability conventions are mapped to explicit EVM roles without pretending
  their authority models are identical.

Not copied:

- package/module names, code, addresses, error values, deployment IDs, market
  parameters, Pyth configuration, or lending architecture;
- its exact Sui/toolchain/dependency revisions;
- repository-local skills as Blast skills. Blast rules are written here only
  after checking them against Blast's scope and current primary documentation.

One important lesson from the review was methodological: an early TODO claim
about narrowing casts was later corrected by an executable cast-safety check.
Blast therefore requires toolchain-backed tests for language/runtime claims
instead of inheriting prose as truth.

## What memez-gg contributed

Retained as product evidence:

- Pump, Auction, and Stable launch concepts;
- virtual-liquidity curve behavior and a trading-to-migration lifecycle;
- creation, swap, migration, referral, and stakeholder fee/allocation concepts;
- vesting and typed one-time migration handoffs;
- historical Bluefin/XPump integration requirements.

Rejected as implementation precedent:

- beta Move edition and mutable branch dependencies;
- broad lint suppressions and helper self-transfers;
- zero-address disposal without explicit economic semantics;
- placeholder production migrator functions;
- incomplete config/admin event coverage;
- bare expected failures and weaker property/random testing;
- generated coverage data committed alongside source;
- mirroring every historical package before a V2 boundary requires it.

The historical images were also reviewed: they show the intended Pump rising
curve, Auction descending curve toward a floor, and Stable flat price. They are
useful product diagrams, not executable economic specifications.

Protected launches using a platform signer and per-user nonces were reviewed as
historical evidence and explicitly rejected for V2 product scope. Canonical V2
launches are permissionless; the historical signature design remains relevant
only as a negative security example for the separate X creator-claim mechanism.

## Primary documentation checked

The reference rules were cross-checked against current primary material rather
than copied blindly:

- [Move 2024 migration guide](https://move-book.com/guides/2024-migration-guide/)
- [Move code quality checklist](https://move-book.com/guides/code-quality-checklist/)
- [Move upgradeability practices](https://move-book.com/guides/upgradeability-practices/)
- [Move linting](https://move-book.com/testing/linting/)
- [Mysten TypeScript SDK JSON-RPC migration](https://sdk.mystenlabs.com/sui/migrations/sui-2.0/json-rpc-migration)

These links are living documentation. Release work must use the documentation
matching the pinned toolchain, not assume this review remains current forever.

## Sources pinned for the Blast Fun Sui proposal

Reviewed 2026-08-22 for the decision records under [decisions/](decisions/). Every
external ABI claim in those records cites one of these commits as
`repo@commit:path:line`; the short ref column is what appears inline.

| Short ref | Repository | Pinned commit | Files read |
| --- | --- | --- | --- |
| `sui@06734f6` | [MystenLabs/sui](https://github.com/MystenLabs/sui) | `06734f6ff0af45d8632a14a4dc4b100197f6b1a2` | `crates/sui-framework/packages/move-stdlib/sources/type_name.move`, `crates/sui-framework/packages/sui-framework/sources/object.move` |
| `sui@ae60d06` | [MystenLabs/sui](https://github.com/MystenLabs/sui) | `ae60d065ed27576d25ac1c94145e5ffe3ddcf89e` | `crates/sui-framework/packages/sui-framework/sources/registries/coin_registry.move`, `.../registries/display_registry.move`, `.../derived_object.move`, `.../coin.move`, `crates/sui-framework/packages/sui-framework/tests/registries/coin_registry_tests.move` |
| `cetus@ddfbdeb` | [CetusProtocol/cetus-contracts](https://github.com/CetusProtocol/cetus-contracts) | `ddfbdeba174319998b012de876ab7ec23c3ab0bc` | `packages/cetus_clmm/sources/pool_creator.move`, `.../factory.move`, `.../math/tick_math.move`, `.../position.move`, `packages/cetus_clmm/Move.toml` |
| `bluefin@91ce930` | [fireflyprotocol/bluefin-spot-contract-interface](https://github.com/fireflyprotocol/bluefin-spot-contract-interface) | `91ce930575b2aa3decab9b7e129b8002deba80c1` | `sources/pool.move`, `sources/config.move`, `Move.toml`, `README.md` |
| `turbos@cff6932` | [turbos-finance/turbos-sui-move-interface](https://github.com/turbos-finance/turbos-sui-move-interface) | `cff693265bfc41c7de2233afe31c9d7428adc9e1` | `clmm/sources/pool_factory.move`, `clmm/sources/pool.move`, `clmm/sources/lib/math_tick.move`, `clmm/Move.toml` |
| `suins@692a12c` | [MystenLabs/suins-contracts](https://github.com/MystenLabs/suins-contracts) | `692a12c02260fd4abecf1630d33db819e4bcadef` | `packages/suins/sources/registry.move`, `packages/suins/sources/name_record.move` |
| `memez@00596fd` | [interest-protocol/memez-gg](https://github.com/interest-protocol/memez-gg) | `00596fdac4dd11f427c7bc594e566ce36160db93` | `fun/sources/errors.move`, `fun/sources/events.move`, `fun/sources/lib/events_wrapper.move`, `fun/sources/structs/constant_product.move`, `.../burner.move`, `.../verifier.move`, `.../fees.move`, `fun/sources/memez_fun.move`, `periphery/templates/*`, `migrators/xpump/*` |

Current documentation additionally consulted on 2026-08-22: the Sui Currency
Standard, the fungible-token creation guide, and the programmable-transaction-block
concept page on `docs.sui.io`.

### Evidence status at the time of this review

**No Sui CLI was installed and no Move code was compiled.** Every claim in the
decision records is either cited against a commit above or written as a named
premise with a falsification test. The open premises are indexed in
[decisions/README.md](decisions/README.md). Per
[engineering-principles.md](engineering-principles.md), prose is not evidence: each
premise must be converted by an executable test against the pinned toolchain before
the ADR depending on it can be accepted.

Three of those commits sit on default branches that continue to move. The pins above
record what was read, not a claim about the current head. The venue dependency
manifests additionally use mutable revisions; that is recorded per venue in
[decisions/0010-migration-and-venue-adapters.md](decisions/0010-migration-and-venue-adapters.md).
