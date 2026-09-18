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
holding the core `State` (uninitialized), the selected risk-module witness and
the currency's `TreasuryCap` and `MetadataCap`. It cannot be stored, shared or
transferred, so the transaction that issues must also activate; a failed
activation aborts the whole transaction and the currency registration with it.

### D2. `initialize` consumes the issuance and returns the Vault

`operations::initialize(issuance, …): Vault<Product>` runs the activation
body unchanged (venue account, seed deposit, seed position, core activation,
locked seed shares) and then builds the Vault. The `BLAST_ACTIVATION_BOUNDARY`
markers keep their order; A5 now marks "Vault constructed" instead of "venue
account installed". The Vault is `key`-only, so the same transaction must pass
it to `vault::share`. Because the issuance can only exist inside the issuer's
transaction, activation is gated by the issuer role without a second check.

### D3. A Vault exists only from activation on

`Vault` holds `venue_account: VenueAccount` and `seed_facts: SeedFacts` as
plain fields. `VenueAccount` seals the binding, the accepted checkpoint and
the venue's `AuthorityCap<ACCOUNT, ADMIN>` together; `venue_account::new` is
the one place the cap is proved to name the bound account, and because both
are immutable from then on nothing re-checks the pairing later. `VenueCustody`
is removed; custody functions are `VenueAccount` methods. The share caps stay
dynamic object fields of the Vault (0071). `unresolved_checkpoint_digest`
stays `Option`: it is "none while healthy", a real state.

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

### D5. Retired codes

Adapter codes 19 (`venue_account_already_installed`), 31
(`share_supply_not_zero`, true by construction: the issuance mints nothing
before its locked seed shares) and 39 (`venue_account_not_installed`) are
retired and never reused.

## Consequences

- No uninitialized Vault can be shared, so the core's pre-activation guards
  are unreachable from this adapter and the "uninitialized vault cannot shut
  down" case cannot arise.
- The issuer's activation PTB is `issue → initialize → share` and takes a
  mutable lock on Coin Registry alongside the venue's shared objects.
- Tests build an activated Vault through the production `activate` with a
  cap minted by the vendored interface's test constructor; the custody guards
  are under local test for the first time.
- The 0074 atomicity-gate validator and its A1–A7 fixtures bind the Vault as
  an input argument of the initializer; they must be re-bound to a created
  object consumed by `share`, together with the earlier renames they already
  miss. Until then the gate is not evidence for this layout.
