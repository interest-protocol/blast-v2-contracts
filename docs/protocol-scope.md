# Protocol scope

This document translates historical Blast/Memez behavior into a deliberately
smaller V2 scope. It is not an economics specification; exact constants and
formulas require ADRs and shared test vectors.

## V2 baseline

| Capability | V2 direction |
| --- | --- |
| Asset launch | Keep one canonical, permissionless creation path with bounded metadata and parameters. |
| Pump curve | Implement first as the default launch mechanism; specify virtual liquidity, terminal threshold, and rounding formally. |
| Launch access | Permissionless. No protected/private mode, launch allowlist, platform signature, or launch nonce. |
| Trading protection | Require deadline, min-output/max-input slippage bounds, and explicit zero/dust behavior. |
| Fees | Keep creation, trade, and migration fees behind hard ceilings; accrue before distribution and emit complete accounting. |
| Referrals | Optional and bounded; a referrer cannot increase the user's total fee beyond the quoted amount. |
| Stakeholder allocation | Keep only through a bounded allocation plus vesting model with conservation tests. |
| Migration | Keep a one-time typed/authorized handoff to an approved adapter with a recoverable, explicitly governed pending state. |
| Metadata | Allow only the minimum approved mutable fields, with authority checks and old/new event data. |
| Emergency control | Add scoped pause/circuit breakers and bounded configuration changes; preserve approved user exits. |
| Indexing | Make lifecycle, reserves, fees, configuration, allocations, and migration replayable from events. |

## Decisions taken since this table was written

| Decision | Outcome | Record |
| --- | --- | --- |
| D1 curve count | **One** curve: constant product with virtual quote liquidity | [decisions/0004-bonding-curve.md](decisions/0004-bonding-curve.md) |
| D2 other modes | Auction and Stable are **out** of the initial Sui core | this document, below |
| D3 coin creation | Coin Registry is the creation primitive | [decisions/0002-coin-creation-and-currency-authority.md](decisions/0002-coin-creation-and-currency-authority.md) |
| D4 burn | Coin owner selects `Fixed` or `BurnOnly`; burnable launches escrow progress-dependent sell allocations and destroy them once at migration, while fixed launches require zero burn | [decisions/0023-generated-coin-supply-and-metadata-custody.md](decisions/0023-generated-coin-supply-and-metadata-custody.md), [decisions/0026-deferred-sell-burn.md](decisions/0026-deferred-sell-burn.md) |
| D5 venues | Cetus, Bluefin and Turbos fully specified; release order gated by evidence quality | [decisions/0010-migration-and-venue-adapters.md](decisions/0010-migration-and-venue-adapters.md) |
| D6 referrals | No referral state and no referrer argument in curve trades; off-chain attribution with bounded epoch settlement | [decisions/0009-referrals-and-revshare.md](decisions/0009-referrals-and-revshare.md) |
| D7 launch access | **Permissionless only**: the historical protected/private launch path is removed | [decisions/0013-creator-fee-authority-and-x-claims.md](decisions/0013-creator-fee-authority-and-x-claims.md) |
| D8 creator claim | Every address or X creator explicitly claims one `CreatorCap`; only X supplies an attestation bound to the original meme type, while SuiNS is resolved in periphery to the address recorded at launch | [decisions/0016-unified-creator-cap-claim-and-suins-periphery.md](decisions/0016-unified-creator-cap-claim-and-suins-periphery.md), [decisions/0017-coin-type-domain-for-x-creator-claims.md](decisions/0017-coin-type-domain-for-x-creator-claims.md) |
| Generated coin supply | Current unregulated Coin Registry OTW path only; nonzero initial supply capped at one billion whole coins; coin owner chooses irreversible `Fixed` or `BurnOnly`; native metadata authority is returned separately at creator claim | [decisions/0023-generated-coin-supply-and-metadata-custody.md](decisions/0023-generated-coin-supply-and-metadata-custody.md) |
| Quote asset | Bounded administrative whitelist keyed by original type, with one nonzero migration target per quote snapshotted by future launches; no quote `Currency` input at snapshot | [decisions/0025-quote-whitelist-and-migration-targets.md](decisions/0025-quote-whitelist-and-migration-targets.md) |
| Graduation economics and migrator admission | Future-launch defaults start at zero, cap Quote migration revenue at 5% and reserved Meme allocation at 10%, and allow at most 16 external migrator witness types; each launch selects one witness | [decisions/0027-graduation-economics-and-migration-witnesses.md](decisions/0027-graduation-economics-and-migration-witnesses.md) |
| Trade-fee ledger | Independent meme/quote rates capped at 10% per asset; fees accrue into an embedded four-balance ledger using the current global protocol share, with ceiling rounding assigned to protocol | [decisions/0022-dual-asset-fee-ledger-and-claims.md](decisions/0022-dual-asset-fee-ledger-and-claims.md) |

The full index, including every open premise, is in
[decisions/README.md](decisions/README.md). ADRs 0013–0028 are accepted; economic
constants not fixed by those accepted records and the remaining proposed records still
await approval.

## Deferred capabilities

Auction and Stable launches remain product candidates. They should reuse the
common lifecycle and accounting rules, but they are not part of the first core
implementation. They enter only with approved economics, property tests, and a
clear user need.

Existing-coin launches are also deferred, with named re-entry conditions rather
than an open question: an existing coin is admissible only if its supply authority,
metadata authority, and burn capability each meet the same invariants the generated
currency satisfies. See
[decisions/0006-fees-and-launch-paths.md](decisions/0006-fees-and-launch-paths.md).

Venue adapters are incremental, but incremental now means **release order**, not
design coverage: Cetus, Bluefin, and Turbos are each fully specified, and a venue
whose dependency cannot be pinned to an immutable commit is blocked from release
rather than left unspecified.

## Historical ideas retained

- Three-stage trading-to-migration lifecycle, simplified into explicit states.
- Virtual-liquidity Pump pricing.
- Referrer and stakeholder accounting where product-approved.
- A single-use migration handoff instead of allowing an adapter to seize core
  state.
- Separate vesting rather than mixing time-based claims into curve math.

## Historical debt not carried forward

- Move `2024.beta` manifests.
- Git dependencies pinned to mutable branches.
- Blanket lint allowances for self-transfer, sharing, or unused code.
- Helper APIs that transfer newly created objects to the sender instead of
  returning them for transaction composition.
- Burning or disposing assets through unexplained zero-address transfers.
- Production functions implemented as unconditional aborts.
- Unbounded configuration, collections, or referral/allocation growth.
- Admin mutations without replay-complete events.
- Bare expected-failure tests that pass for the wrong abort.
- Generated coverage traces committed as source evidence.
- Signer-gated protected/private launches, launch allowlists, and per-user launch
  nonce state.

## Decisions required before source implementation

Each decision belongs in `docs/decisions/` before it creates a public ABI or
storage commitment. ADRs 0013–0028 settle the creator-cap claim, protocol
authority, X-signature, pure curve, trade-fee-ledger, and generated-coin supply
semantics plus cold launch and graduation policy below; the remaining portions
and records are still proposed.

| # | Decision | Record |
| --- | --- | --- |
| 1 | Curve formula, scales, virtual reserves, terminal threshold, dust policy | [0004](decisions/0004-bonding-curve.md) |
| 2 | Launch creation-fee policy remains open; trade-fee accounting and graduation ceilings are settled; DEX pool-opening fees are unsupported | [0006](decisions/0006-fees-and-launch-paths.md), [0022](decisions/0022-dual-asset-fee-ledger-and-claims.md), [0027](decisions/0027-graduation-economics-and-migration-witnesses.md) |
| 3 | Creation authority and X-claim signer rotation policy | [0002](decisions/0002-coin-creation-and-currency-authority.md), [0013](decisions/0013-creator-fee-authority-and-x-claims.md), [0015](decisions/0015-protocol-authority-and-x-signer-state.md), [0017](decisions/0017-coin-type-domain-for-x-creator-claims.md) |
| 4 | Pause matrix and which exits remain available in each state | [0007](decisions/0007-acl-pause-and-versioning.md) |
| 5 | Migration targets, timeout/recovery behaviour, settlement ownership | [0010](decisions/0010-migration-and-venue-adapters.md) |
| 6 | Contribution allocation limits and claim ownership remain open; the protocol Meme graduation allocation is settled | [0006](decisions/0006-fees-and-launch-paths.md), [0027](decisions/0027-graduation-economics-and-migration-witnesses.md) |
| 7 | Sui upgrade posture, administrators, version gating | [0007](decisions/0007-acl-pause-and-versioning.md) |
| 8 | X creator-claim signature domain and replay protection | [0013](decisions/0013-creator-fee-authority-and-x-claims.md), [0017](decisions/0017-coin-type-domain-for-x-creator-claims.md) |
| 9 | Initial quote-asset admission rule — accepted | [0025](decisions/0025-quote-whitelist-and-migration-targets.md) |
| 10 | Graduation revenue, reserved supply, and migration-witness policy — accepted | [0027](decisions/0027-graduation-economics-and-migration-witnesses.md) |
| 10 | Package and module boundaries, and explorer Display policy | [0001](decisions/0001-sui-package-and-module-layout.md) |
| 11 | Event schema and replay completeness | [0011](decisions/0011-event-schema-and-replay.md) |
| 12 | Growth-feature scope | [0012](decisions/0012-flywheel-features.md) |

EVM-side items — token compatibility policy, proxy or immutable posture, and the
chain-specific mapping of item 8 — remain open. The Sui records above state which of
their invariants the EVM implementation must reproduce, and the shared vectors in
[vectors/](vectors/) are chain-neutral so both implementations consume the same
cases.
