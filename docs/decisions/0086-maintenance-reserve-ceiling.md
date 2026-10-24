# 0086: Maintenance reserve ceiling

- Status: accepted
- Date: 2026-09-17
- Amends: [0064](0064-aftermath-backed-leverage-coins.md)
- Reviewed with the founder and an independent model pass on 2026-09-17.

## Context

ADR 0064 defines the maintenance reserve `R` as collateral inside the venue
account that share pricing excludes, `N = E - R`. It defines the inflows and
the outflows: fee slices credit it, funding costs consume it, and shutdown
reclassifies whatever remains into cash for holders.

Two things had drifted from that text. First, the core credited donations and
positive funding to the reserve (after repaying the uncovered deficit), while
0064 said both add shareholder NAV. Second, the core carried an admin path,
`release_reserve`, that relabelled any amount of reserve into NAV during
`Active` with no design record, no bound beyond the reserve balance, and no
delay. Its only stated purpose was the case where the reserve had grown far
beyond what funding could plausibly consume.

That case is real and it is a transfer, not idle money. A mint is priced on
`N`, yet the new shares carry a pro-rata claim on `R` at shutdown. Every unit
of reserve is therefore a gift from existing holders to the next minter, funded
by fees the existing holders already paid. The larger the reserve relative to
the position, the larger the gift. A manual admin release fixes the symptom in
a lump, on a schedule anyone can watch and trade around.

## Decision

### D1. The reserve has a ceiling fixed at issuance

`VaultPolicy` gains `max_reserve_bps`, positive and at most 10,000. The
maintenance reserve may hold at most

```text
cap(notional) = floor(notional * max_reserve_bps / 10_000)
```

where `notional` is the position valued in collateral atoms from the same
observation the operation prices against. Notional, not NAV, is the base
because funding is charged on notional; a reserve is "N days of funding," and
that scales with notional. NAV falls faster than notional when price moves
against the position, so a NAV-relative ceiling would release most when the
reserve is needed most.

### D2. Every reserve credit is clamped; nothing is rejected

Wherever the core writes the reserve with an observation in hand, it stores
`min(reserve, cap(after.notional))`:

- `complete_mint`: the fee slice is added, then clamped.
- `complete_redemption`: the fee slice is added, the admin share removed, then
  clamped. The required final venue equity is the physical value,
  `nav_kept + reserve_retained`, before the clamp: no collateral moves.
- `complete_donation`: the donation is added, then clamped. A donation is never
  rejected; the part above the ceiling counts as shareholder NAV from that
  checkpoint on.

`settle_funding` has no observation and does not clamp. A funding credit may
leave the reserve above the ceiling until the next priced operation.

Collateral above the ceiling is never moved. It stays in venue equity and
stops being labelled reserve, so shareholder NAV rises by exactly the excess.

### D3. Priced operations value shares against the admitted reserve

A release that is pending when a mint or redemption arrives belongs to the
holders at that checkpoint, not to the caller. `prepare_mint`, `complete_mint`
and `complete_redemption` therefore price against

```text
reserve_priced = min(stored_reserve, cap(before.notional))
```

and only then add the operation's own fee slice and clamp against
`cap(after.notional)`. Pricing against the raw stored reserve would let a
minter buy shares at the pre-release NAV and immediately own a slice of the
release; the redeemer would symmetrically forfeit theirs.

### D4. The seed reserve is bounded at activation

Notional is zero before the opening position exists, so
`prepare_initialization` and `initialize` require
`seed_reserve <= cap(target_notional)` and `seed_reserve <= cap(notional)`
respectively. Without this the first priced operation would release most of
the seed reserve to whoever held shares at that moment.

### D5. A flat position keeps its reserve

`cap(0)` is zero. A flat active position has no funding exposure to size a
ceiling against and is transient, so the clamp does not apply while notional
is zero; the reserve is kept for the position that reopens.

### D6. Admin reserve release is removed

`release_reserve`, its adapter entry and completion, the `ReserveReleased`
event and error code 95 are deleted. Shutdown's terminal reclassification
(0064 I24) is the only bulk return of reserve to holders. The ceiling makes
the manual lever unnecessary and removes the one admin action in the core that
moved value between parties without a bound or a design record.

### D7. Donations and positive funding feed the reserve up to the ceiling

This records what the code does and supersedes the two 0064 sentences that say
otherwise. A donation credits the reserve; a positive funding settlement first
repays the uncovered deficit to NAV, then credits the reserve. Donations clamp
with their observation. Funding has no observation and may leave a recorded
excess; subsequent priced operations admit it only up to their live ceiling.

## Consequences

- Holders can read the ceiling before depositing and know the reserve, and the
  newcomer subsidy it implies, is bounded relative to the position.
- The release is gradual and mechanical: one operation at a time, sized by the
  ceiling, with no moment to time a trade around.
- A vault at its NAV cap may refuse mints after a release raises NAV, exactly
  as it does after favourable PnL; `set_nav_cap` remains the remedy.
- Under [ADR 0128](0128-reserve-aware-rebalance-increases.md), increases size
  and validate against the reserve admitted by the resulting notional. A
  growing ceiling can lower NAV, so the opening reserve is not a safe basis
  for an increase. Maintenance leaves the recorded reserve unchanged.
  Reductions retain their separate opening-reserve basis; the L-10 liveness
  concern is not resolved by the increase fix.
- Tests pin the inclusive seed bound, the redemption release with unchanged
  physical equity, a mint priced after a pending release (951,428 shares on
  a 999,000 contribution against NAV 1,050,000, not 999,000), an accepted
  over-ceiling donation, and the flat-position exception.
