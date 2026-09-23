# 0087: Vault issuance activated in one transaction

- Status: accepted
- Date: 2026-09-18
- Amends: [0073](0073-series-one-adapter-owned-vaults.md), [0074](0074-aftermath-vault-activation-and-health.md)
- Reviewed with the founder and an independent model pass on 2026-09-18.

## Context

ADR 0071 split issuance from activation "instead of making issuance depend
on the unfinished venue adapter": `vault::issue` published a zero-supply,
uninitialized `Vault` in one transaction and `operations::initialize` bound
the venue account in a later one. The adapter and the issuer are now the same
package, so that reason has expired, while the split kept three costs:

- `Vault` carried `venue_account`, `venue_custody` and `seed_facts` as
  `Option` only because the type was built before those values existed.
  Published code never held a `None` past activation, yet every custody call
  had to borrow past one, and two error codes existed to name states no
  activated Vault can be in.
- A successful `issue` followed by a failing `initialize` left a shared
  uninitialized Vault that could be re-activated by anyone: `initialize`
  required no admin role, only a risk-module witness, so a stranger could seed
  another issuer's Vault and name themselves its seed funder.
- The `BlastBoost<Product>` Coin Registry slot was burned by `issue` even when
  activation never followed.

## Decision

### D1. `issue` returns an issuance, not a Vault

`vault::issue` returns `VaultIssuance<Product>`: a value with no abilities
holding the core `Issuance` (the issuer's terms) and the currency's
`TreasuryCap` and `MetadataCap`. It cannot be stored, shared or
transferred, so the transaction that issues must also activate; a failed
activation aborts the whole transaction and the currency registration with it.

### D2. `initialize` consumes the issuance and returns the Vault

`operations::initialize(issuance, …): Vault<Product>` opens the venue
account, seeds it, opens the position, and then builds the Vault. The Vault
is `key`-only, so the same transaction must pass it to `vault::share`.
Because the issuance can only exist inside the issuer's transaction,
activation is gated by the issuer role without a second check. Five
`BLAST_ACTIVATION_BOUNDARY` markers remain: A1 venue account sealed, A2 Vault
activated (core state, locked seed shares, object built), A3 account shared,
A4 market re-shared, A5 event emitted.

### D2a. The core has no uninitialized state

`Lifecycle` is `Active | Unwinding | Settled`. The core's
`state::Issuance` carries the issuer's terms (policy, order cap, NAV cap)
while the adapter opens the seed position, sizing the orders through
`seed_terms` and bounding them through its own `assert_execution` and
`assert_order_notional_allowed`; `Issuance::activate` builds the `State`
around the seeded observation. Issuance is the first section of `state.move`,
not a module above it: the module that owns every later phase owns the first,
and observation valuation stays private to it. No `State` value ever exists
before its position does, so every "not before activation" guard,
`assert_can_activate`, and the dual-branch `set_fees` are gone.

### D3. A Vault exists only from activation on

`Vault` holds the core `State`, `venue_account: VenueAccount` and the count
of locked seed shares, nothing else. `VenueAccount` seals the binding, the
accepted checkpoint and the venue's `AuthorityCap<ACCOUNT, ADMIN>` together;
`venue_account::new` is the one place the cap is proved to name the bound
account, and because both are immutable from then on nothing re-checks the
pairing later. `VenueCustody` is removed; custody functions are
`VenueAccount` methods. The share caps stay dynamic object fields of the
Vault (0071). The seed funder, its `SeedFacts` and the diagnostic
`unresolved_checkpoint_digest` are gone: none of them controlled an
invariant, and the drift a digest used to record is now an event.

### D3b. The collateral is a type parameter

`Vault<Product, Collateral>` names its collateral coin at the type level, as
every venue object it touches already does (`Account<Collateral>`,
`ClearingHouse<Collateral>`). The stored `TypeName` and its runtime
comparison are gone: a Vault, an account and a market of different
collateral no longer typecheck in one call, so there is nothing left for an
assertion to catch.

### D3a. The Aftermath interfaces are vendored

The five direct Aftermath dependencies and their three transitive packages
are copied verbatim from `AftermathFinance/move-interfaces` at the pinned
revision into `interfaces/aftermath/`, keeping each package's manifest,
published address and `abort 404` bodies, exactly as `interfaces/pyth` is
kept. One marked difference: `authority::for` reads the field instead of
aborting, and a `#[test_only]` constructor exists, so tests mint a real venue
cap and build every Vault through the production `activate`. No test-only
assembly of a Vault exists. `check_mainnet_abi.mjs` keeps gating the vendored
modules against mainnet bytecode.

### D4. Events

`VaultIssued` no longer carries a Vault id (none exists when it fires) or the
always-zero maintenance reserve; the `Product` type argument identifies the
currency for good and `VaultInitialized` follows in the same transaction with
the Vault id. Both events stay.

### D4b. Every venue order leaves an `OrderFilled` event (2026-09-20)

The accounting events replay supply, reserve, admin cash and checkpoints but
not what each order cost against the oracle, which is the one figure that
sets the per-order notional cap and decides whether market orders stay
sufficient. `events::OrderFilled<Product>` is emitted once per venue market
order, seed orders included, after the fill passed the cap and slippage
checks: the bound account object id (seed orders fire before a Vault id
exists; `VaultInitialized.binding` maps the account to the Vault), side,
reduce-only and emergency flags, requested and filled whole-lot base, the raw
IFixed quote the session moved, and the sealed reference and executed prices
at nine decimals. Up to sixteen per operation. The existing events are
unchanged.

### D4a. The risk-module witness is removed

The adapter carried a second authority class, a `RiskModule` type parameter
on `issue` and `initialize` and a rotatable `TypeName` on the Vault, whose
only power was `set_max_order_notional`. Its second purpose, gating who may
activate a shared uninitialized Vault, has no object to gate since D1. The
risk-admin role, which already sets fees and the NAV cap, now sets the order
cap too; `rotate_risk_module`, `RiskModuleWitnessRotated`, the witness field
and its three error codes are gone, and `VaultIssued` no longer names a
witness type. A separately rotatable keeper key can return as a role if it
is ever needed.

### D5. Remove obsolete checks

Delete the errors for removed risk-module authority and states made
unreachable by atomic issuance. Renumber each registry sequentially from zero
under the greenfield policy in `AGENTS.md`; tests name errors through the
registry's constants.

## Consequences

- No uninitialized Vault can be shared, so the core's pre-activation guards
  are unreachable from this adapter and the "uninitialized vault cannot shut
  down" case cannot arise.
- The issuer's activation PTB is `issue → initialize → share` and takes a
  mutable lock on Coin Registry alongside the venue's shared objects.
- Tests build an activated Vault through the production `activate` with a
  cap minted by the vendored interface's test constructor; the custody guards
  are under local test for the first time.
- The 0074 atomicity-gate validator and its A1–A7 fixtures bound the Vault as
  an input argument of the initializer. They were re-bound on 2026-09-20 to
  this layout: the dev-inspect proof builds the `issue → initialize → share`
  PTB from signatures, and the rollback proof tracks the Vault as an object
  the transaction creates and shares, over the five boundaries A1–A5. Both
  self-tests run on synthetic vectors; neither is chain evidence until the
  testnet rehearsal records real effects, which will also fix the created
  objects Coin Registry and the dynamic object fields add.
- The source-boundary gate no longer pins activation statement order, which
  the 0074 phase proofs bind themselves; it checks what neither the compiler
  nor the Move tests can: dependency direction, one linear module hierarchy
  per package, the three-module public surface, `operations` as the sole
  driver, and the `#[test_only]` seams.
