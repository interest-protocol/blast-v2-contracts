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
The implemented Sui Move slices cover accepted ADRs 0013 through 0022: one-time
`CreatorCap<Meme>` claims for address and X identities, coin-type-isolated
creator authority that survives migration, a creator-authority boundary with no
metadata-cap pass-through, and the backend-attested X branch.
It includes dedicated package-constant and macro-error registries, a wrapped-event
module, inline invariant assertions, a concern-limited singleton admin registry,
drop-only admin sign-in witnesses, an independent shared X signer configuration,
delayed recipient-accepted root transfer,
minimal X signer rotation/revocation,
exact BCS encoding, an Ed25519 vector, and adversarial Move tests. A pure
package-only constant-product quote module now fixes buy/sell rounding, independently
selected quote/meme fee ordering, the sell burn ramp, threshold reporting, and the no-clamp sell-back
invariant without committing launch storage or deployment parameters. The
embedded dual-asset fee ledger now fixes creator/protocol accounting, odd-unit
rounding under a live global share, maximum-width conservation, and
capability-gated composable claims.
The fixed/burnable generated-supply policy is accepted; its normalized
one-billion launch-intake assertion, the load-bearing launch ABI, quote admission
rule, and lifecycle storage records remain proposed.

The decision records cover the Sui package — package layout, Coin
Registry creation and the three-transaction bootstrap, final fixed/burnable supply,
the constant-product curve, the reopened quote-admission boundary,
fees and launch paths, capability ACL and pause, creator identity, referral
settlement, migration routes and the Cetus/Bluefin/Turbos adapters, the event
schema, growth-feature dispositions, and the accepted one-time creator-cap claim
model. They are indexed, with every open premise,
in [decisions/README.md](docs/decisions/README.md).

Shared differential vectors for both chains live in [docs/vectors/](docs/vectors/).

The current Sui implementation includes the audit-sized dual-asset fee ledger and
the shared trade-fee configuration whose live percentage every launch reads.
The next audit-sized slice is the launch-state/lifecycle module that composes the
configuration, ledger, and reviewed curve quotes. Auction and Stable remain optional
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
