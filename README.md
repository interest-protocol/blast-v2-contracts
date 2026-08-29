# Blast V2 contracts

This repository is the smart-contract vertical for Blast V2. It owns two
implementations of one protocol specification:

- `sui/` — Sui Move package workspace and deployment tooling.
- `evm/` — Solidity contracts, Foundry tests, and EVM deployment tooling.

The implementations share product behavior and invariants. They do not share
storage layouts, chain-specific abstractions, or source code.

```text
contracts/
├── CONTEXT.md                canonical protocol language
├── AGENTS.md                 contributor and agent rules
├── docs/
│   ├── architecture.md       package boundaries and lifecycle
│   ├── engineering-principles.md
│   ├── protocol-scope.md     V2 product scope and old-contract disposition
│   ├── reference-review.md   source review and decisions
│   ├── testing.md            required verification matrix
│   ├── decisions/            architecture decision records
│   └── vectors/              chain-neutral differential test vectors
├── sui/                      Sui Move package workspace
│   ├── launchpad/            Blast launchpad core package
│   ├── migrators/            venue adapter packages
│   ├── templates/            generated per-launch package templates
│   └── vesting/              framework-only vesting package
└── evm/                      independent Solidity/Foundry toolchain
```

## Current status

The workspace, its engineering contract, and the Sui design record are established.
The independently deployed vesting package is also implemented. Its `linear`
module supports optional cliffs and explicit release cadence. Its `checkpoints`
module supports up to 256 exact irregular cumulative unlocks through a linear
`TableVec` builder and binary-search claims. Both use fully funded,
fixed-beneficiary schedules, permissionless claims, and fair capability-gated
cancellation that can return only unvested value.
The implemented Sui Move slices cover the current audit-sized boundaries from
accepted ADRs 0013 through 0046: one-time
`CreatorCap<Meme>` claims for address and X identities, coin-type-isolated
creator authority that survives migration, a creator-authority boundary with no
metadata-cap pass-through, and the backend-attested X branch.
The generated-coin bootstrap now includes a composable `LaunchTicket<Meme>`:
Blast consumes the coin package's OTW, mints exactly one billion whole coins at
the protocol-fixed nine-decimal precision,
irreversibly selects `Fixed` or `BurnOnly`, and stores the complete balance,
native metadata capability, and bounded deployer-selected sell-burn rate until
launch intake. Coin Registry is the only supply-mode authority. No mint
capability survives the initializer.
The cold shared `LaunchConfig` now admits original quote types with per-quote
virtual reserves and migration targets, stores the independently bounded Quote
and Meme trade-fee pair, stores zero-safe 5% Quote-fee and 10% Meme-allocation
ceilings plus the nonzero 1–9,999 bps destination-pool Meme liquidity
provision whose zero value is only an unconfigured sentinel, and bounds the
external migrator witness types available to new
launches. Launch intake will select one allowlisted witness without requiring a
quote `Currency` object or importing a DEX package, so later admin updates cannot
rewrite existing launches. DEX pool-opening costs are deliberately unsupported.
It includes dedicated package-constant and macro-error registries, a wrapped-event
module, a package-only OTW bootstrap that claims the framework `Publisher`, one
shared package-administration object that validates and permanently wraps both
that Publisher and the Blast `UpgradeCap`, exact-digest upgrade authorization
and irreversible policy restriction through a live `AdminWitness`, inline
invariant assertions, a concern-limited singleton admin registry,
drop-only admin sign-in witnesses, one dedicated shared package-version
cutover, and one small shared runtime configuration for the dedicated X signer
and live protocol fee share,
delayed recipient-accepted root transfer,
minimal X signer rotation/revocation,
exact BCS encoding, an Ed25519 vector, and adversarial Move tests. A pure
package-only constant-product quote module now fixes buy/sell rounding, independent
quote/meme fee ordering, the sell burn ramp, threshold reporting, and the no-clamp sell-back
invariant without committing launch storage or deployment parameters. The
embedded dual-asset fee ledger now fixes creator/protocol accounting, odd-unit
rounding under a live global share, maximum-width conservation, and
capability-gated composable claims.
The fixed/burnable generated-supply policy, launch-ticket boundary, launch
policy, deferred sell-burn custody, pure graduation balance partitions, and
normalized launch intake are accepted and implemented. Each launch is key-only
top-level shared state published through its consuming `share` function. It owns
the immutable economic snapshot, explicit schema/lifecycle state, reserves,
fee ledger, pending disposal, and one-time creator/metadata custody. Public
`buy` and `sell` enforce exact slippage and accounting; the terminal buy caps
the accepted Quote at the exact target, returns the excess, and closes trading.
Atomic `migrate` is permissionless and verifies the selected witness type. It
reads the authoritative native supply mode, sends Fixed terminal disposal to
`0x0` or natively burns BurnOnly disposal, then returns only the reserved Meme
plus net Quote in a non-droppable typed payload. The selected external adapter
must supply its sealed witness to redeem it.

Package-capability custody and the global package cutover for all mutable core
shared objects are implemented. Native receipt commit and operational activation
are separate: activation accepts only the exact next compiled package version,
while additive and dependency-only upgrades leave the operational version
unchanged. Routine admins have code authority under the current
irreversibly restrictable policy. A later governance design retires that path
through the version gate after it installs replacement authorization; no
pre-planted cutover flag exists (ADR 0034).

The decision records cover the Sui package — package layout, Coin
Registry creation and the three-transaction bootstrap, final fixed/burnable supply,
the constant-product curve, bounded quote admission and virtual/terminal snapshots,
fees and launch paths, capability ACL and pause, creator identity, referral
settlement, migration routes and the Cetus/Bluefin/Turbos adapters, the event
schema, growth-feature dispositions, and the accepted one-time creator-cap claim
model. They are indexed, with every open premise,
in [decisions/README.md](docs/decisions/README.md).

Shared differential vectors for both chains live in [docs/vectors/](docs/vectors/).

The current Sui implementation includes the launch ticket, dual-asset fee
ledger, consolidated runtime configuration, bounded cold launch configuration,
one validated basis-points unit, package-only graduation partitions, and
versioned `Launch<Meme, Quote>` custody.
Launch creation consumes one ticket, snapshots all cold and deployer policy,
partitions every initial Meme unit, preserves the one-time creator claim, and
shares the key-only launch through the explicit publication function. The
launch then owns coin-moving trading, capability-gated fee claims, and the
single-use migration lifecycle.
The workspace SDK derives explanatory release and valuation previews off chain.
ADR 0054 records the accepted isolated V3 migrator design and its recommended
SUI lane: 8,000 SUI virtual Quote and migration target, zero terminal fees, and
20% Meme pool provision. This is operational launch configuration, not an
on-chain USD oracle or immutable global default; Memez, Raydium, Pump, and Hop
comparisons are context only.
The next audit-sized slice is SDK transaction construction and live-state
previews for this ABI. Pause policy, Auction, and Stable remain optional
follow-ups rather than making the V2 core carry them on day one. See
[protocol scope](docs/protocol-scope.md) and [architecture](docs/architecture.md).

## Working here

Read [AGENTS.md](AGENTS.md) before changing code. In particular:

- external repositories are evidence, not templates;
- every state change must validate before mutation and emit replay-complete
  events;
- arithmetic must state its units, bounds, and rounding beneficiary;
- dependencies and release toolchains must be immutable and reproducible;
- placeholder production paths are not accepted.

Each chain owns its build commands:

```bash
cd sui/launchpad
sui move build
sui move lint --warnings-are-errors
sui move test --lint
```

```bash
cd evm
forge fmt --check
forge build
forge test
```

The Sui implementation is pinned to Sui CLI
`1.77.2-51d177ad7d65` from `mainnet-v1.77.2`; `sui/launchpad/Move.lock` pins the
framework revision. Do not infer a Blast version pin from a reference repository.

## References

The design review used `interest-protocol/su-lending` as a current Sui
engineering reference and `interest-protocol/memez-gg` as the historical Blast
behavior reference. The reviewed commits and the rules adopted, adapted, or
rejected are recorded in [reference-review.md](docs/reference-review.md).
