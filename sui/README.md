# Blast V2 on Sui

This directory owns the Sui Move implementation. Shared protocol behavior lives
in `../docs/`; Sui-specific rules live in `../AGENTS.md`.

The initial package stays single and dependency-light:

```text
sui/
├── Move.toml
├── sources/
│   └── lib/              shared diagnostics and indexing infrastructure
├── tests/
└── scripts/
```

Add a separate Move package only for a real dependency/security boundary such as
a venue adapter or test coins. External Git dependencies must use immutable full
commit SHAs. `Published.toml`, normalized deployment summaries, Publisher
custody, and upgrade-cap disposition are release records and should be committed
when they exist.

## Implemented first slice

The core package now contains:

- `blast.move` — the canonical package OTW and private initialization path that
  claims and delivers the framework `Publisher` to the publishing sender;
- `constants.move` — package-wide protocol values exposed as zero-cost package
  macros, with related attestation-layout values derived rather than repeated;
- `acl.move` — singleton `ProtocolAuthority`, delayed `SuperAdminCap` transfer,
  bounded protocol-wide `AdminCap` grant/revoke delegation, holder-driven cap
  destruction, and drop-only `AdminWitness` sign-in only;
- `package_admin.move` — shared custody of the package's validated `Publisher`
  and `UpgradeCap`, with live-admin exact-digest authorization, irreversible
  policy restriction, and receipt-bound commit;
- `runtime_config.move` — one small shared live-settings object containing the
  dedicated X backend signer and global protocol fee share, with witness-gated
  signer rotation/revocation, Ed25519 verification, and bounded 0–10,000 bps
  fee-share updates;
- `creator_authority.move` — validated public address/X identity values,
  package-only conversion into linear coin-typed creator authority, one unified
  consuming claim, a composable `CreatorCap<Meme>` return, no unrelated
  metadata-cap pass-through, canonical BCS X attestation bytes, and
  replay-complete events;
- `launch_ticket.move` — one public constructor that accepts a creator identity,
  consumes the generated coin OTW, mints the normalized one-billion-coin supply,
  consumes mint authority into `Fixed` or `BurnOnly`, and returns a transferable
  ticket holding the complete Meme balance, native metadata cap, one creator
  authority, and the launcher-selected burnable flag;
- `curve.move` — package-only constant-product buy/sell quotes, independently
  selected quote/meme fee ordering, sell-side burn ramp, checked reserve
  arithmetic, threshold reporting, and an explicit no-clamp sell-back invariant;
- `fees.move` — embedded four-balance creator/protocol fee accounting for both
  meme and quote assets, live configurable remainder-safe splitting, and composable claims
  authorized by `CreatorCap<Meme>` or `AdminWitness`;
- `launch_config.move` — bounded original-type quote admission and targets,
  the complete graduation triple (zero-safe Quote fee and Meme allocation plus
  the nonzero destination-pool Meme liquidity provision), a bounded external
  migrator-witness whitelist, `AdminWitness`-gated `allow_*`/`disallow_*`
  mutations, quote upserts, and one package-only immutable launch snapshot
  that rejects an unconfigured provision;
- `errors.move` — the append-only package error registry exposed as zero-cost
  package macros; owning modules perform their assertions inline;
- `events_wrapper.move` — the stable package-wide `Event<T>` indexing envelope
  and its single package emitter;
- `events.move` — public payload schemas, package-only emitters routed through
  the wrapper, and test-only collection/field inspection;
- `creator_authority_tests.move` — interface and integration tests for the ACL,
  shared runtime configuration, and address/X creator-claim seam, including the
  independent Ed25519 fixture and adversarial lifecycle cases.
- `runtime_config_tests.move` — combined initialization, live protocol-share
  boundaries, and replay-complete runtime configuration events.
- every scenario-backed suite follows one focused hot-potato fixture
  convention: each setup family gets its own ability-free fixture type named
  for its purpose (`ClaimFixture`, `UpgradeFixture`, …) that stores the
  scenario plus only the objects that family actually uses, with a uniquely
  named `start` variant owning all scenario choreography. Receiver-style
  `next_tx!` macros — `use fun`-aliased onto each fixture type when a module
  defines several — advance the sender and pass the single named fixture
  handle to each transaction closure, and a fixture `ctx!` macro is the only
  transaction-context access a test body may use. Consuming flows use `Option`
  fields behind narrowly named `take_*`/`replace_*`/`retake_*` helpers. Test
  bodies do not destructure fixtures, touch the scenario field, or drive
  `test_scenario` directly, and one consuming `end` per fixture type routes
  through the native test-only `std::unit_test::destroy` black hole.
- `curve_tests.move` — exact shared vectors, rounding and threshold boundaries,
  maximum-width arithmetic, guard precedence, round-trip dust, and a fixed-seed
  reachable-state sell-back property suite.
- `fees_tests.move` — dual-asset conservation, odd-unit protocol rounding,
  maximum-width arithmetic, empty claims, single-asset modes, live split changes
  and percentage boundaries, transferred creator authority,
  and composable payout routing.
- `launch_ticket_tests.move` — OTW provenance, address/X creator validation,
  exact billion-coin balance custody, fixed/burnable selections, decimal bounds,
  replay-complete creation events, and caller-selected ticket delivery.
- `launch_config_tests.move` and `launch_config_capacity_tests.move` — safe
  initialization, administrative lifecycles, immutable future-launch snapshots,
  independent graduation boundaries, route-cost replay facts, collection bounds,
  guard precedence, and exact package-error coverage.
- `blast_tests.move` — package initialization proves the retained `Publisher`
  identifies both the defining `blast` module and the wider `blast_fun` package.
- `package_admin_tests.move` — Publisher/module and UpgradeCap/package
  provenance, shared custody facts, active-admin authorization and policy
  restriction, irreversible admin retirement, native ticket/receipt completion,
  and receipt-to-cap binding.

Internal quote, fee-ledger, launch-ticket, and configuration seams are
package-only where the future `launch` module must own
the call. This avoids publishing an incomplete `Launch` object layout before its
economics and lifecycle ADRs are accepted.

The cross-language backend fixture is
[`../docs/vectors/x-creator-claim.json`](../docs/vectors/x-creator-claim.json).

## Package administration custody

The publish transaction delivers two independent framework objects: a retained
`Publisher` from `blast::init` and the raw package `UpgradeCap`. The deployment
flow must pass both untouched capabilities to `package_admin::wrap`. It accepts
only the Publisher claimed by Blast's canonical module and the cap for Blast's
original package, then shares one non-storable `PackageAdmin` with no capability
release path.

An upgrade PTB calls `acl::sign_in`, passes the resulting `AdminWitness` and
exact package digest to `package_admin::authorize_upgrade`, runs the native Sui
upgrade command, and passes its receipt to `package_admin::commit_upgrade`. Commit
does not repeat the witness because the non-droppable receipt is already bound
to the `PackageAdmin`'s cap. See
[ADR 0032](../docs/decisions/0032-admin-authorized-upgrade-cap-custody.md).

Every active admin has code-upgrade power under the current policy and may
permanently narrow that policy to additive or dependency-only. There is no
pre-planted governance cutover: a future governance design installs replacement
authorization and retires the routine-admin path through the mandatory
shared-object version gate
([ADR 0034](../docs/decisions/0034-remove-premature-governance-cutover.md)).
Do not publish publicly until all mutable shared objects enforce the approved
package/version gates.

## Planned package set

Proposed in [../docs/decisions/0001-sui-package-and-module-layout.md](../docs/decisions/0001-sui-package-and-module-layout.md).
Only the `blast_fun` core package exists today.

| Package | Role | Why separate |
| --- | --- | --- |
| `blast_fun` | all core protocol logic; **imports no venue package** | the trusted core must build with the framework alone |
| `blast_fun_cetus` / `_bluefin` / `_turbos` | migration adapters | each carries a distinct external failure surface and its own dependency exemption |
| `blast_fun_revshare` | epoch settlement and claims | separately governed, holds funds, must not reach curve state |
| `blast_fun_template` | generated per-launch coin package | published once per launch by the creator |

Core defines the neutral route and handoff types; adapters depend inward on core.
Core and adapter are composed **in the programmable transaction block**, never by
core importing an adapter.

SuiNS follows the same dependency rule. The future `blast_fun_suins` periphery
will resolve a valid current target while constructing the launch and pass only
that concrete address into core. Core stores no name and imports no SuiNS module;
the resolved address later claims through the ordinary address branch.

## Launch bootstrap

Two transactions, following
[ADR 0035](../docs/decisions/0035-initializer-finalized-meme-supply.md) and
[ADR 0036](../docs/decisions/0036-fixed-nine-decimal-generated-memes.md):

1. **publish** the generated coin package — its OTW `init` creates an
   unregulated nine-decimal currency, mints exactly one billion whole coins,
   authority into owner-selected `Fixed` or `BurnOnly`, and returns the complete
   balance plus native `MetadataCap<Meme>` inside a Blast launch ticket;
2. **finalize registration and launch** — a permissionless Coin Registry command
   promotes the already finalized currency, and the same PTB may redeem the
   ticket without borrowing that newly shared currency. The future launch module
   determines the remaining launch inputs.

The implementation is pinned to Sui CLI `1.77.2-51d177ad7d65` from the
`mainnet-v1.77.2` release. CI and release records must use this exact build until
an explicit toolchain-upgrade change updates the pin and lockfile. Use:

```bash
sui move build
sui move lint --warnings-are-errors
sui move test --lint
./scripts/check_source_boundaries.sh
```

Do not add JSON-RPC to new scripts or SDK code. Prefer gRPC for normal
reads/writes/simulation and GraphQL for custom indexed or historical queries.
