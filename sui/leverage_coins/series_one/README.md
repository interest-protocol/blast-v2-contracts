# Blast leverage Series1: `blast_leverage_series_one`

This package owns the Series1 accounting, policy, lifecycle, operational
version, role administration, package-capability custody, and Vault issuance
accepted in
[ADR 0064](../../../docs/decisions/0064-aftermath-backed-leverage-coins.md)
and refined by
[ADR 0070](../../../docs/decisions/0070-series-one-versioning-and-role-administration.md),
[ADR 0071](../../../docs/decisions/0071-series-one-vault-issuance.md), and
[ADR 0072](../../../docs/decisions/0072-series-one-package-capability-custody.md).
It has no venue or oracle dependency in the current slice.

## This package is not publishable

The current slice contains pure accounting, reusable bounded values, immutable
policy values, valuation gates, the closed Series1 lifecycle, one shared
operational-version object, one shared role registry, and authorized issuance
of an inert shared `Vault<phantom AdapterRoot>` with its Coin Registry share
currency. It also permanently wraps the package Publisher and UpgradeCap behind
an exact role and digest boundary. It has no asset-balance custody, Vault
activation, adapter handoff, or venue operation.

Each issued Vault stores exactly one immutable `TierPolicy` and one
`bounded_value::BoundedValue` for the live per-call atomic-USDC notional cap.
Issuance chooses no production economic value: the authorized issuer supplies
values that the package validates structurally.

## Modules

- `policy.move` owns `PositionSide`, the immutable `RebalancePolicy`,
  `ValuationPolicy`, and composed `TierPolicy`, their structural validation,
  rebalance eligibility, improvement, and execution-tolerance predicates,
  valuation gates, the NAV cap gate, and the mint-contribution and
  redemption-gross sanity guards.
- `lifecycle.move` owns the non-copyable lifecycle and the operation permission
  matrix. A new lifecycle is `Uninitialized`. This slice permits only monotone
  degradation from a test-constructed operating state, through strict
  `enter_*` transitions for explicit action and idempotent `degrade_to_*`
  transitions for the objective health path; activation, resume, and
  settlement need their future complete proofs.
- `lib/accounting_math.move` owns package-private share, reserve, leverage, and
  exposure arithmetic. Raw shareholder-NAV formulas remain module-private.
- `lib/bounded_value.move` owns immutable inclusive bounds around one mutable
  package-controlled value.
- `lib/constants.move` owns Series1 units, structural ceilings, share decimals,
  and role bits.
- `lib/errors.move` owns the append-only Series1 error registry.
- `package_version.move` owns the singleton old-bytecode cutover. Every future
  shared-state mutator must call its package-only current-version assertion.
- `acl.move` owns the singleton super administrator, bounded multi-role admin
  registry, delayed root-custody transfer, and ephemeral role witnesses.
- `series_one.move` owns the package-only one-time witness used to claim the
  canonical Publisher. This marker does not issue a Vault currency.
- `package_admin.move` permanently owns the Publisher and UpgradeCap, exact
  digest authorization, irreversible policy restriction, native receipt
  commit, and operational-version activation.
- `vault.move` issues the dynamic share currency and owns the inert shared
  Vault, its discoverable child `TreasuryCap` and `MetadataCap`, immutable
  policy, initial witness selections, zero reserve, and protected adapter `Bag`.
- `lib/events.move` and `lib/events_wrapper.move` own replay-complete version,
  authority, package-administration, and Vault-issuance facts behind the stable
  package event envelope.

See [the accounting specification](docs/accounting.md) for units, rounding,
reserve treatment, and required integration checks.

## Authority boundary

The super administrator grants and revokes routine `AdminCap` objects and their
role bits. One cap may hold any nonzero subset of the five roles:

| Value | Role | Future use |
| ---: | --- | --- |
| 1 | `VAULT_ISSUER` | Issues a Vault and its share currency. |
| 2 | `RISK_ADMIN` | Rotate a Vault's risk-module witness. |
| 4 | `ADAPTER_ADMIN` | Rotate a Vault's adapter witness. |
| 8 | `SHUTDOWN_ADMIN` | Start shutdown. |
| 16 | `PACKAGE_ADMIN` | Authorize upgrades, restrict policy, and activate the next package version. |

`sign_in` copies the complete authoritative role bitmap into
`AdminWitness(roles)`; it takes no caller-selected role. Each consumer checks
the one role bit its transition requires. The root does not bypass role checks.
Root-custody transfer requires recipient acceptance after seven days. Package
authorization itself is immediate; future governance can enforce a delay by
holding the only role-bearing cap without changing core state.

## Policy boundary

One Vault stores one `TierPolicy`. There is no tier vector, tier index, or tier
switching. Its rebalance thresholds satisfy:

```text
public_lower < module_lower < target
             < module_upper < public_upper < hard_cap
```

The exact eligibility rules are:

- healthy: `module_lower <= leverage < module_upper`;
- risk module: `leverage < module_lower || leverage >= module_upper`;
- public: `leverage < public_lower || leverage > public_upper`;
- hard emergency: `leverage >= hard_cap`.

Exact public bounds stay risk-module-only. The hard cap is at most the
structural `max_leverage_bps` ceiling of 1,000,000 bps (100x), which bounds
every threshold below it and so bounds the leveraged divergence allowances. A
zero public lower threshold is valid and disables the lower public trigger by
design. Strict execution tolerance is below 10,000 bps. Emergency tolerance is
at least strict tolerance and also below 10,000 bps. Minimum leverage
improvement is positive.

Every stored policy value has a gate. `is_improvement_sufficient` measures a
rebalance as the decrease in absolute distance from `target_bps` and is the
only anti-grief rule on the permissionless trigger.
`is_execution_within_strict_tolerance` and
`is_execution_within_emergency_tolerance` bound an executed value against its
reference through `u128` cross-multiplication. `is_within_nav_cap` bounds
post-operation shareholder NAV. Each predicate has an aborting `assert_` twin.

`TierPolicy` construction also fences two values that are unrecoverable once
the immutable policy is deployed: `min_exposure_lots` is at most
`max_min_exposure_lots` (1,000,000 lots), and `nav_cap * hard_cap_bps /
10_000` must fit in `u64` so a target notional can be computed at every
admitted leverage. Both fences reject a transposed lot multiple and NAV cap.

`ValuationPolicy` requires `max_price_ahead_ms <= max_price_age_ms`, which
rejects a transposed freshness pair that would reject every aged update and
admit future-dated ones.

`ValuationPolicy` preserves the settled freshness, confidence, and
mark-divergence checks. It does not authenticate Pyth, bind a source, read a
clock, or execute a venue operation.

## Error registry

Codes are append-only. Each macro in `sources/lib/errors.move` inlines its code
into the invariant-owning module.

| Code | Macro | Raised from | Meaning |
| ---: | --- | --- | --- |
| 0 | `zero_amount` | `accounting_math` | A fee calculation requires a positive atomic collateral amount. |
| 1 | `invalid_fee_bps` | `accounting_math`, `policy` | A fee rate is not below 10,000 bps. |
| 2 | `invalid_nav` | `accounting_math` | A priced operation requires positive shareholder NAV. |
| 3 | `invalid_share_supply` | `accounting_math` | A priced operation requires positive share supply. |
| 4 | `invalid_share_amount` | `accounting_math` | Presented shares are not within the live supply. |
| 5 | `nonpositive_contribution` | `accounting_math` | A mint has no positive shareholder-NAV contribution. |
| 6 | `zero_shares_out` | `accounting_math` | A positive contribution rounds down to zero shares. |
| 7 | `nonpositive_gross` | `accounting_math` | Post-unwind NAV does not exceed equity kept for remaining shares. |
| 8 | `zero_net_payout` | `accounting_math` | The redemption fee consumes the complete gross claim. |
| 9 | `invalid_target_leverage_bps` | `accounting_math` | Target leverage is zero. |
| 10 | `invalid_lot_size` | `accounting_math` | Venue lot size is zero. |
| 11 | `invalid_base_exposure` | `accounting_math` | A proportional mint starts from zero base exposure. |
| 12 | `sub_lot_exposure_delta` | `accounting_math` | An exposure delta is below the required lot multiple. |
| 13 | `redemption_under_reduced` | `accounting_math` | A redemption leaves too much base exposure. |
| 14 | `redemption_over_reduced` | `accounting_math` | A redemption removes too much base exposure without reaching flat. |
| 15 | `arithmetic_overflow` | `accounting_math` | A result exceeds the supported `u64` range. |
| 16 | `maintenance_reserve_exceeds_equity` | `accounting_math` | Venue equity does not back the maintenance reserve. |
| 17 | `invalid_lifecycle_transition` | `lifecycle` | The lifecycle cannot make the requested transition. |
| 18 | `operation_not_permitted_in_lifecycle` | `lifecycle` | The lifecycle does not permit the requested operation. |
| 19 | `mint_over_exposed` | `accounting_math` | A mint exceeds its planned proportional exposure. |
| 20 | `mint_under_exposed` | `accounting_math` | A mint does not reach its minimum funded exposure. |
| 21 | `invalid_min_exposure_lots` | `accounting_math`, `policy` | Minimum exposure lots is zero, or above the structural ceiling in `policy`. |
| 22 | `invalid_rebalance_policy` | `policy` | Rebalance thresholds are not strictly ordered, or the hard cap exceeds the leverage ceiling. |
| 23 | `invalid_series_nav_cap` | `policy` | Series NAV cap is zero, or its hard-cap notional does not fit in `u64`. |
| 24 | `invalid_max_price_age` | `policy` | Valuation maximum age is zero. |
| 25 | `invalid_max_confidence_bps` | `policy` | Confidence bound is not below 10,000 bps. |
| 26 | `invalid_max_mark_divergence_bps` | `policy` | Mark-divergence bound is not below 10,000 bps. |
| 27 | `stale_valuation` | `policy` | A valuation is older than its freshness budget. |
| 28 | `future_valuation` | `policy` | A valuation is too far ahead of the reference time. |
| 29 | `invalid_valuation_price` | `policy` | A gated price, index, or execution reference is zero. |
| 30 | `confidence_exceeds_bound` | `policy` | Confidence exceeds its relative bound. |
| 31 | `mark_index_divergence_exceeds_bound` | `policy` | Venue mark diverges too far from the index. |
| 32 | `mint_contribution_exceeds_bound` | `policy` | Mint contribution exceeds its favorable-divergence bound. |
| 33 | `invalid_max_mint_contribution_divergence_bps` | `policy` | Mint-contribution divergence is not below 10,000 bps. |
| 34 | `invalid_bounded_value` | `bounded_value` | A bounded value violates its inclusive bounds. |
| 35 | `invalid_strict_tolerance_bps` | `policy` | Strict tolerance is not below 10,000 bps. |
| 36 | `invalid_emergency_tolerance_bps` | `policy` | Emergency tolerance excludes strict tolerance or reaches 10,000 bps. |
| 37 | `invalid_minimum_improvement_bps` | `policy` | Minimum leverage improvement is zero. |
| 38 | `package_version_mismatch` | `package_version` | Shared operational state rejects this bytecode generation or a nonconsecutive activation. |
| 39 | `package_version_overflow` | `package_version` | The operational version cannot advance beyond `u64`. |
| 40 | `invalid_super_admin_cap` | `acl` | The supplied root cap is not currently active. |
| 41 | `invalid_admin_cap` | `acl` | The supplied admin cap is not live in this authority. |
| 42 | `invalid_admin_recipient` | `acl` | Admin delivery targeted the zero address. |
| 43 | `admin_capacity_reached` | `acl` | The 16-cap live-admin registry is full. |
| 44 | `invalid_admin_roles` | `acl` | An initial role set is empty or contains an unknown bit. |
| 45 | `invalid_admin_role` | `acl` | An operation did not select one exact recognized role. |
| 46 | `admin_role_already_granted` | `acl` | The selected role is already assigned. |
| 47 | `admin_role_not_granted` | `acl` | The witness bitmap does not contain the required role. |
| 48 | `invalid_super_admin_recipient` | `acl` | Root transfer targeted zero or the current sender. |
| 49 | `no_pending_super_admin_transfer` | `acl` | No pending root transfer exists. |
| 50 | `not_pending_super_admin_recipient` | `acl` | The sender is not the proposed root recipient. |
| 51 | `super_admin_transfer_not_ready` | `acl` | The seven-day root-transfer delay has not elapsed. |
| 52 | `super_admin_transfer_time_overflow` | `acl` | The root-transfer ready timestamp would overflow `u64`. |
| 53 | `super_admin_cap_still_active` | `acl` | The active root cap cannot be destroyed. |
| 54 | `super_admin_transfer_unchanged` | `acl` | A proposal repeated the pending root recipient. |
| 55 | `redemption_gross_exceeds_bound` | `policy` | Redemption gross claim exceeds its favorable-divergence bound. |
| 56 | `invalid_max_redemption_gross_divergence_bps` | `policy` | Redemption-gross divergence is not below 10,000 bps. |
| 57 | `shares_out_below_minimum` | `accounting_math` | A mint produced fewer shares than the depositor's floor. |
| 58 | `insufficient_leverage_improvement` | `policy` | A rebalance does not move leverage toward target by the minimum improvement. |
| 59 | `series_nav_cap_exceeded` | `policy` | Shareholder NAV exceeds the immutable Series NAV cap. |
| 60 | `execution_outside_tolerance` | `policy` | An executed value diverges from its reference beyond the selected tolerance. |
| 61 | `invalid_freshness_window` | `policy` | Forward clock skew exceeds the staleness budget. |
| 62 | `invalid_adapter_witness_type` | `vault` | The adapter root is a primitive or vector type. |
| 63 | `invalid_risk_module_witness_type` | `vault` | The risk-module witness is a primitive or vector type. |
| 64 | `invalid_notional_cap` | `vault` | The notional-cap minimum is zero. |
| 65 | `invalid_package_publisher` | `package_admin` | The Publisher was not claimed by the canonical Series1 module. |
| 66 | `invalid_upgrade_cap` | `package_admin` | The UpgradeCap does not belong to the original Series1 package. |
| 67 | `invalid_package_digest` | `package_admin` | The authorized package digest is not exactly 32 bytes. |
| 68 | `upgrade_policy_not_more_restrictive` | `package_admin` | The requested policy is unchanged or less restrictive. |

The next new error must use code 69.

## Deferred stateful work

Vault activation and locked seed shares, risk-module and adapter-witness
rotation, direct Pyth verification, venue handoffs, Aftermath integration,
asset-balance custody, trade sizing and post-fill proofs, shutdown timers,
shutdown execution and redemption, and their stateful events are all deferred.

## Verification

Run `bash scripts/verify.sh all` from this directory with the workspace-pinned
Sui CLI.
