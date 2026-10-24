# 0130 · Protected permissionless shutdown of a size-locked Boost

Status: accepted. Scope: unpublished Boosts core and Aftermath adapter (ADR 0115).

## Decision

A holder must not need administrator action solely because every accessible
ordinary redemption is smaller than the issuance policy's minimum order.
Anyone may explicitly begin an irreversible shutdown when the bound, accepted,
order-free position proves that condition. Health synchronization does not
change lifecycle. This follows the second remedy proposed for audit L-11;
it refines its trigger and adds payout protection the audit did not specify.

Let `B` be absolute whole-lot base, `S` the native treasury's total supply,
`L` its immutable locked seed count, `q` the current authenticated venue lot,
and `m` the issuance minimum lots. Require positive `B`, `q`, `m`, and
`0 < L < S`. Compute `keep = floor(B * L / S)`. The exact lock is
`keep > 0 && B - keep < q * m`, before order rounding. Equality already
permits an ordinary exit. A zero proportional keep already permits a full
ordinary close. Flat and seed-only vaults cannot use this trigger. Testing
only `B <= q*m` both misses some locks and admits ordinary-exitable positions.

The adapter checks the operational version, active lifecycle and live bound
account/registry/market/oracle identities. Raw account facts must match the
accepted checkpoint, contain no pending orders and have whole-lot base on the
configured side. Market-wide pause/freeze, margin policy and cumulative funding
may change, as in ADR 0115; the trigger adopts these live settings. Account
collateral, base, quote, lot, orders, funding snapshots and position margin
remain exact. In particular, an already-settled funding change is not accepted
until its reserve effect has been booked. No live price, positive equity,
mark-divergence or opening margin condition gates entry. This is a read-only venue inspection: it places
no trade, accepts no caller size or economic parameter, and pays no reward.
Unexplained account drift must first be reconciled. For attributable funding
already settled into the account, call `sync_health` before this trigger while
the venue permits it. The planner deliberately does not prepend synchronization:
it calls venue funding methods that abort on paused markets, whereas this
read-only trigger can seal protected mode on a closed market. Raw capture still
needs the bound venue objects.

The existing bounded, price-limited, close-only unwind and exact final cash
recovery then apply. The settlement mode is sealed when shutdown begins and
cannot be switched to administrator-approved distribution afterward.

## Protected allocation

At finalization, let `C` be actual recovered cash, `R` the full recorded reserve,
and `E = S - L`. Compute:

```text
protected_reserve = min(C, R)
share_cash = C - protected_reserve
holder_pool = floor(share_cash * E / S)
protected_seed = share_cash - holder_pool
```

Retain the **full recorded reserve**, rather than the last open position's
notional-limited reserve allowance: the position is now flat, where the existing
accounting policy retains the full reserve. This deliberately does not release
reserve excess to a permissionless shutdown caller. Losses and closing costs
may exhaust shareholder cash before the reserve; protection is an allocation
of actual recovery, not a guarantee of original capital. Recorded funding
settlements continue to affect `R` under the existing accounting rules.

Physically segregate both protected allocations in the vault's private
`protected_cash` balance. The user explicitly chose to leave this money locked
in the vault with no withdrawal path, even after all circulating shares are burned. Neither
holder claims nor administrator fee withdrawals can spend it. There is no
recovery beneficiary or new administrator escape path.
This is the contract's enforced custody policy, not a claim that upgrade
authority has been destroyed: the existing adapter upgrade governance remains
a trust assumption, and an authorized future code change could change policy.

Only the holder pool funds existing fee-free terminal claims. The final holder
receives its rounding remainder, never protected cash. A zero pool permits a
zero-output burn when the holder's minimum output is zero. Earned admin cash
stays separate. Administrator-approved shutdown retains its existing allocation
and seed-only handling; this decision changes the new permissionless exit only.

Without segregation, a user could mint, redeem nearly everything, leave one
circulating share, and collect all seed and reserve cash through terminal claims.
The exact trigger alone does not prevent that attack. Conservatively rounding
the holder pool down also prevents a one-share claim from extracting seed dust.

## Events and limits

`ProtectedShutdownBegun` records the accepted checkpoint, native supply and locked
count. One `ShutdownFinalized` event records total recovery, protected reserve
and protected seed (both explicitly zero for admin shutdown). Subtract their
sum from recovered cash to replay the holder pool; subsequent claims retain
their existing event meaning. Finalization emits only after custody and the
checkpoint are fully updated.

This is an irreversible economic exit, not guaranteed execution. Market freeze,
missing prices for a live close, unavailable liquidity, nonpositive settlement
prices, venue restrictions and unresolved drift can still block progress.
Market losses, funding and priority trading fees may reduce recovery. A holder
can intentionally leave a small circulating balance and make a genuine size
lock reachable; anyone may then end the vault, but cannot confiscate its
protected assets. New vault issuance is required to restart trading.

For a closed market, direct settlement may settle outstanding funding without
attributing that delta to the reserve book. Actual recovered cash remains exact,
but protection uses the last recorded reserve, so the holder/reserve split can
differ from a live-market synchronized close. If account funding was already
settled just before the market paused, entry rejects until it can be reconciled;
venue funding calls may then be unavailable. Legacy admin shutdown remains a
separate fallback with its old distribution. These are not guaranteed-progress
or funding-attribution claims.

The source and storage layouts are pre-publication changes, not a compatible
upgrade to any published layout. Venue interface fixtures and local tests do
not prove live Aftermath execution. Deployment must still satisfy the existing
venue execution and package capability/cutover gates. Model review is not the
original auditor's acceptance.
