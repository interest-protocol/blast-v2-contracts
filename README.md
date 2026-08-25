# Blast V2 contracts

This repository is the smart-contract vertical for Blast V2. It owns two
implementations of one protocol specification:

- `sui/` — Sui Move contracts, tests, and Sui deployment tooling.
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
├── sui/                      independent Sui Move toolchain
└── evm/                      independent Solidity/Foundry toolchain
```

## Current status

The workspace, its engineering contract, and the Sui design record are established.
The implemented Sui Move slices cover the current audit-sized boundaries from
accepted ADRs 0013 through 0039: one-time
`CreatorCap<Meme>` claims for address and X identities, coin-type-isolated
creator authority that survives migration, a creator-authority boundary with no
metadata-cap pass-through, and the backend-attested X branch.
The generated-coin bootstrap now includes a composable `LaunchTicket<Meme>`:
Blast consumes the coin package's OTW, mints exactly one billion whole coins at
the protocol-fixed nine-decimal precision,
irreversibly selects `Fixed` or `BurnOnly`, and stores the complete balance plus
native metadata capability until launch intake. No mint capability survives the
initializer.
The cold shared `LaunchConfig` now admits original quote types with per-quote
virtual reserves and migration targets, stores zero-safe 5% Quote-fee and 10% Meme-allocation
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
drop-only admin sign-in witnesses, one small shared runtime configuration for
the dedicated X signer and live protocol fee share,
delayed recipient-accepted root transfer,
minimal X signer rotation/revocation,
exact BCS encoding, an Ed25519 vector, and adversarial Move tests. A pure
package-only constant-product quote module now fixes buy/sell rounding, independently
selected quote/meme fee ordering, the sell burn ramp, threshold reporting, and the no-clamp sell-back
invariant without committing launch storage or deployment parameters. The
embedded dual-asset fee ledger now fixes creator/protocol accounting, odd-unit
rounding under a live global share, maximum-width conservation, and
capability-gated composable claims.
The fixed/burnable generated-supply policy, launch-ticket boundary, launch
policy, deferred sell-burn custody, and pure graduation balance partitions are
accepted and implemented. Normalized launch intake and lifecycle storage remain
the next implementation boundary.

Package-capability custody is implemented, but public release still requires
version gates on every mutable shared protocol object so old package bytecode
cannot bypass an upgrade. Routine admins have code authority under the current
irreversibly restrictable policy. A later governance design retires that path
through those version gates after it installs replacement authorization; no
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

The current Sui implementation includes the audit-sized launch ticket, dual-asset
fee ledger, consolidated live runtime configuration, bounded cold launch
configuration, and package-only graduation balance partitioning. Graduation
uses ceiling rounding for protocol Meme and Quote obligations, floor rounding
for destination-pool Meme principal, positive atomic pool and curve guards, and
separate conservation identities without introducing venue expenditure. The
workspace SDK derives explanatory release and valuation previews off chain. The
next audit-sized slice is launch-state construction and immutable intake of
those named balances. Auction and Stable remain optional
follow-ups rather than making the V2 core carry all three modes on day one. See
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
cd sui
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
`1.77.2-51d177ad7d65` from `mainnet-v1.77.2`; `sui/Move.lock` pins the
framework revision. Do not infer a Blast version pin from a reference repository.

## References

The design review used `interest-protocol/su-lending` as a current Sui
engineering reference and `interest-protocol/memez-gg` as the historical Blast
behavior reference. The reviewed commits and the rules adopted, adapted, or
rejected are recorded in [reference-review.md](docs/reference-review.md).
