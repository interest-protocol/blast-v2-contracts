# Blast SUI LST: source review and proposed design

- Date: 2026-08-29
- Status: research input; the protocol decision is
  [ADR 0053](../decisions/0053-single-validator-funsui-and-blastsui.md)
- Blast framework pin: `MystenLabs/sui@06734f6ff0af45d8632a14a4dc4b100197f6b1a2`
- SpringSui source reviewed: `suilend/liquid-staking@49f757384e69065ab082dc2fcf653f4b285a1940`

## Accepted design summary

ADR 0053 accepted the funded senior/junior form of the two-coin design from
the "Coherent form" section below, not the single conventional LST recommended
by the original proposal. The accepted refinements that this note's analysis
did not anticipate are:

- `funSUI` and `blastSUI` keep **separate custody ledgers and native
  positions** in one vault, both bound to the same immutable pool ID; the
  validator address is derived from the Sui system state. Fun custody backs
  only `funSUI` plus a 0.1-SUI rounding reserve
  that `create` splits from the owner seed as protocol capital with no
  `funSUI` minted for it; blast custody backs only `blastSUI`.
- The vault **caches one pool exchange-rate entry** (epoch, `sui_amount`,
  `pool_token_amount`). A refresh performs one current-epoch table lookup:
  present replaces the cache, absent (safe mode) keeps the conservative cached
  rate. The vault never scans backward. When the current entry is missing, an
  activated fun `StakedSui` is withdrawn to liquid SUI instead of converting
  at a rate newer than the cache. Every `blastSUI` receipt claim requires a
  current rate; fun mints and both redemptions stay open.
- A refresh **sweeps only fun yield** (fun assets above the `funSUI` supply
  plus a fixed rounding reserve) into blast custody before blast pricing. Fun
  principal never moves, and nothing moves from blast to fun.
- The seed `blastSUI` is **locked at `@0x0`** by `create`, which returns
  nothing. Supply is therefore permanently positive: every user redemption is
  partial and pays the current fee, no final-share drain or restart deposit
  exists, fun custody always has a yield owner and keeps staking, and no
  orphaned yield exists for a later first depositor. The seed backing is
  permanent protocol capital that nobody can redeem.
- The redemption fee is a vault field bounded at 100 bps. One package-local
  `SuperAdminCap` authorizes fee changes and upgrades. There are no routine
  roles, and the package does not depend on `blast_fun`.
- A blast deposit delegates immediately but mints no shares. The depositor
  receives a returned key-only, wallet-displayed receipt and claims fair-value
  `blastSUI` only after native activation. The return remains composable;
  `deposit_receipt::keep` places it in the sender's account when desired. The
  receipt can always cancel directly into SUI without the vault or
  package-version object.
- A permissionless donation path adds positive SUI only to blast custody and
  mints nothing. It can fund rewards from other mechanisms, raises assets per
  existing share, and remains available as a liquid deposit after validator
  unwind. Locked bootstrap shares retain their pro-rata part of each donation.
  Large predictable donation cliffs remain timing-sensitive: a parked activated
  receipt can claim before the injection and become an existing holder. Reward
  sources should donate atomically or use an approved streamed design.
- Native conversion and delegation require a current exchange-rate entry for
  the immutable pool, and every returned `StakedSui` is checked against that
  pool. This prevents a validator that reuses its address with a fresh pool from
  mixing pool objects or bricking the vault; stale old-pool mode keeps exits and
  liquid donations live.

### Native rounding bound behind the reserve

At the Blast pin, three floors can leave a custody ledger's conservative
valuation below the SUI it eventually receives:

1. **Conversion.** `convert_to_fungible_staked_sui` issues
   `floor(principal * pool_tokens / sui)` tokens at the activation-epoch rate
   ([staking_pool.move L274-L319](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/crates/sui-framework/packages/sui-system/sources/staking_pool.move#L274-L319)).
   Valued back at that rate the tokens are worth at least
   `principal - ceil(rate)` MIST; the upstream regression vector converts
   `1_000_000_001` MIST at a 2:1 rate into `500_000_000` tokens worth
   `1_000_000_000`
   ([staking_pool_tests.move L384-L441](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/crates/sui-framework/packages/sui-system/tests/staking_pool_tests.move#L384-L441)).
2. **Redemption.** `redeem_fungible_staked_sui` floors the pool's total SUI
   value, then floors the principal and reward portions separately
   ([L195-L270](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/crates/sui-framework/packages/sui-system/sources/staking_pool.move#L195-L270)),
   so redeeming `v` tokens returns at least `floor(v * sui / tokens) - 3` MIST
   and never more than `floor(v * sui / tokens)`.
3. **Revaluation after a partial redemption.** Subtracting exact native output
   from a cached floor valuation can leave it one MIST above the floor of the
   remaining tokens.

The vault therefore requests ceil pool tokens for `amount + 3` MIST on every
native redemption, revalues every position from token counts at the cached
pool entry, and keeps the seeded 0.1-SUI reserve in fun custody as a
retained value target (`F + R` is never swept) so the per-epoch losses above
are absorbed from creation onward and retained fun yield restores the target.
Conversion waits unless the live rate's ceiling loss bound leaves twice the
redemption margin. At that low-water mark, remaining active fun stake unwinds.
The recovery receipt remains intact through its activation epoch and every
safe-mode epoch. It is withdrawn only in a later normal current-rate epoch, so
frequent vault activity cannot forfeit current or deferred fun yield. Future
principal stays liquid until the reserve is restored. The upstream 2:1 vector
is pinned as a passing full exit before any reward.

## Original recommendation

Build a separate, Blast-owned `blast_sui` Move package. Do not add staking
logic or a `SuiSystem` dependency to `blast_fun`. The package should issue one
non-rebasing, exchange-rate LST, tentatively called `BLAST_SUI`, and bind all
native stake to one immutable Blast validator and staking-pool ID.

Use SpringSui as the behavioral and test reference, but do not copy its generic
multi-validator registry, weight hook, mutable validator routing, unused fee
fields, or 50-validator storage. The fixed-validator requirement makes those
features unnecessary. It also lets the contract enforce the requirement rather
than trust an operator to keep a weight configuration at 100%.

Do not ship the proposed two-coin principal/yield design in the first release.
A sound version is not two free receipts for each deposit. It is a leveraged
senior/junior vault: the 1:1 quote coin is senior debt, and the yield coin must
be backed by real first-loss SUI capital. That design is feasible, but it adds
solvency ratios, subordinated exit gates, reward-timing attacks, and a second
economic system. The conventional LST is smaller, standard, and safer.

Before implementation, Blast must make one product decision that source review
cannot make: use an immediate mint with an economically justified nonzero mint
fee, or use a one-epoch deposit receipt and mint after native stake activation.
A zero-fee immediate mint lets a deposit made just before the epoch boundary
share rewards earned by older active stake. SpringSui itself warns that zero-fee
creation is exploitable
([fees.move L133-L142](https://github.com/suilend/liquid-staking/blob/49f757384e69065ab082dc2fcf653f4b285a1940/contracts/sources/fees.move#L133-L142)).

## Sources and exact pins

| Ref | Full commit | Primary source |
| --- | --- | --- |
| `blast-sui` | `06734f6ff0af45d8632a14a4dc4b100197f6b1a2` | [MystenLabs/sui commit](https://github.com/MystenLabs/sui/commit/06734f6ff0af45d8632a14a4dc4b100197f6b1a2) |
| `spring` | `49f757384e69065ab082dc2fcf653f4b285a1940` | [suilend/liquid-staking commit](https://github.com/suilend/liquid-staking/commit/49f757384e69065ab082dc2fcf653f4b285a1940) |
| `spring-sui` | `868c226359ef914f1f3b080518f27eb13d8967f5` | [SpringSui mainnet framework pin](https://github.com/suilend/liquid-staking/blob/49f757384e69065ab082dc2fcf653f4b285a1940/contracts/Move.lock#L7-L25) |

Blast's checked-in lock pins `MoveStdlib` and `Sui` to `blast-sui` for both
mainnet and testnet (`sui/launchpad/Move.lock:7-35`). It does not yet include
`SuiSystem` (`sui/launchpad/Move.lock:19-23,37-41`). Native staking is not in the
`Sui` package at `0x2`; it is in the separate `SuiSystem` package at `0x3`
([SuiSystem Move.toml L1-L12](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/crates/sui-framework/packages/sui-system/Move.toml#L1-L12)).
The new LST package must add `sui_system = { system = "sui_system" }` and lock
it to the same `blast-sui` commit. It must not inherit SpringSui's older
`spring-sui` framework pin.

The repository's Sui CLI pin is a different commit. The CLI release
`mainnet-v1.77.2` resolves to
`51d177ad7d65102fc368b582408f466d97b31548`; Move dependencies remain pinned to
`06734f6ff0af45d8632a14a4dc4b100197f6b1a2`.

## What SpringSui implements

The official open-source implementation is
[`suilend/liquid-staking`](https://github.com/suilend/liquid-staking). At the
reviewed commit, its published mainnet package is version 10, with original ID
`0xb0575765166030556a6eafd3b1b970eba8183ff748860680245b9edd41c716e7`
([Published.toml L5-L13](https://github.com/suilend/liquid-staking/blob/49f757384e69065ab082dc2fcf653f4b285a1940/contracts/Published.toml#L5-L13)).

SpringSui separates an ordinary fungible LST coin type `P` from the native Sui
staking receipts. Its shared `LiquidStakingInfo<P>` owns the `TreasuryCap<P>`,
fees, storage, and version state
([liquid_staking.move L33-L48](https://github.com/suilend/liquid-staking/blob/49f757384e69065ab082dc2fcf653f4b285a1940/contracts/sources/liquid_staking.move#L33-L48)).
Creation consumes a zero-supply treasury cap; an alternate bootstrap can accept
existing `FungibleStakedSui` and liquid SUI
([L164-L248](https://github.com/suilend/liquid-staking/blob/49f757384e69065ab082dc2fcf653f4b285a1940/contracts/sources/liquid_staking.move#L164-L248)).

User mint and redemption work as follows:

1. Every operation refreshes native stake accounting first.
2. Mint deducts a configured fee, mints `floor(net_sui * L / A)` LST units,
   and retains the SUI in the vault's liquid pool
   ([L251-L293](https://github.com/suilend/liquid-staking/blob/49f757384e69065ab082dc2fcf653f4b285a1940/contracts/sources/liquid_staking.move#L251-L293)).
3. Redemption calculates `floor(lst * A / L)`, obtains exact SUI from liquid
   and native stake, deducts the redeem fee, and burns the LST
   ([L295-L353](https://github.com/suilend/liquid-staking/blob/49f757384e69065ab082dc2fcf653f4b285a1940/contracts/sources/liquid_staking.move#L295-L353),
   [L568-L599](https://github.com/suilend/liquid-staking/blob/49f757384e69065ab082dc2fcf653f4b285a1940/contracts/sources/liquid_staking.move#L568-L599)).
4. An admin moves pooled SUI into validators and can move stake out again
   ([L379-L452](https://github.com/suilend/liquid-staking/blob/49f757384e69065ab082dc2fcf653f4b285a1940/contracts/sources/liquid_staking.move#L379-L452)).
5. Epoch refresh updates backing from native exchange rates and accrues an
   optional spread fee on positive backing growth
   ([L487-L529](https://github.com/suilend/liquid-staking/blob/49f757384e69065ab082dc2fcf653f4b285a1940/contracts/sources/liquid_staking.move#L487-L529)).

SpringSui storage supports up to 50 validators. Each validator entry can hold
one pending `StakedSui`, one active `FungibleStakedSui`, a cached exchange rate,
and derived SUI accounting
([storage.move L15-L52](https://github.com/suilend/liquid-staking/blob/49f757384e69065ab082dc2fcf653f4b285a1940/contracts/sources/storage.move#L15-L52)).
Refresh detects validators that left the active set, unstakes them, converts
activated pending stake, and removes empty entries
([L125-L193](https://github.com/suilend/liquid-staking/blob/49f757384e69065ab082dc2fcf653f4b285a1940/contracts/sources/storage.move#L125-L193)).
Its instant redemption path consumes pending stake first, then active fungible
stake, and retains any over-withdrawn rounding amount in the SUI pool
([L349-L490](https://github.com/suilend/liquid-staking/blob/49f757384e69065ab082dc2fcf653f4b285a1940/contracts/sources/storage.move#L349-L490)).

The optional weight hook gives an admin a mutable validator-to-weight map and
lets anyone execute the resulting rebalance
([weight.move L85-L100](https://github.com/suilend/liquid-staking/blob/49f757384e69065ab082dc2fcf653f4b285a1940/contracts/sources/hooks/weight.move#L85-L100),
[L125-L249](https://github.com/suilend/liquid-staking/blob/49f757384e69065ab082dc2fcf653f4b285a1940/contracts/sources/hooks/weight.move#L125-L249)).
Configuring one address at 100% is operationally possible. It is not the same as
making that validator immutable: the hook admin can replace the weight map, and
can eject the hook to recover its underlying LST admin cap
([L251-L268](https://github.com/suilend/liquid-staking/blob/49f757384e69065ab082dc2fcf653f4b285a1940/contracts/sources/hooks/weight.move#L251-L268)).

### Adopt, adapt, reject

| SpringSui element | Blast treatment | Reason |
| --- | --- | --- |
| Treasury cap held by shared LST state | Adopt | Mint and burn stay tied to backing custody. |
| Refresh before mint, redeem, and fee collection | Adopt | Stale backing must not authorize share issuance or payout. |
| `u128` share math; mint and redemption round down | Adopt | Remainders stay with the vault and protect existing holders. |
| Liquid SUI plus pending and fungible native stake | Adopt | Native rounding and the 1 SUI pending-stake split limit require a small buffer. |
| Exact-output redemption funded by native FSS redemption | Adapt | Prove the rounding bound against Blast's newer framework pin; do not copy the unexplained `100` MIST offset. |
| Mutable list of up to 50 validators | Reject | Blast has exactly one validator. |
| Weight hook, registry, and custom redemption hook | Reject | No caller requires them under the fixed-validator requirement. |
| Mutable validator priority and redirectable stake | Reject | These weaken the one-validator invariant. |
| Generic LST factory surface | Reject | Blast needs one coin type and one vault. |
| Six-field fee builder with unused fields | Reject | Add only a fee that has an approved economic purpose. |
| External deployed SpringSui package as custody authority | Reject for now | It leaves the broad admin surface and external upgrade trust in the quote asset's redemption path. |

SpringSui's reviewed source is not source-compatible evidence for every pinned
behavior. Its lock uses `spring-sui`, while Blast uses the newer `blast-sui`.
In Blast's pin, conversion rejects a zero pool-token result
([staking_pool.move L273-L319](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/crates/sui-framework/packages/sui-system/sources/staking_pool.move#L273-L319)),
and inactive-pool withdrawal avoids recording an underflow field that cannot be
cleaned up
([L372-L415](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/crates/sui-framework/packages/sui-system/sources/staking_pool.move#L372-L415)).
Those checks are absent from SpringSui's older native dependency. Blast must
build and test against its own lock.

## What native Sui provides

`StakedSui` is a self-custodial receipt containing a pool ID, activation epoch,
and principal `Balance<SUI>`. `FungibleStakedSui` is a pool-specific object
containing a pool ID and native pool-token value. It is not a `Coin<T>` and
cannot be used directly as `blast_fun`'s quote coin
([staking_pool.move L74-L107](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/crates/sui-framework/packages/sui-system/sources/staking_pool.move#L74-L107)).

The public `SuiSystemState` wrappers provide all required transitions:

- delegate a `Coin<SUI>` and receive `StakedSui`;
- withdraw `StakedSui` and receive `Balance<SUI>`;
- convert activated `StakedSui` to `FungibleStakedSui`; and
- redeem `FungibleStakedSui` directly to `Balance<SUI>`.

See
[`sui_system.move` L227-L301](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/crates/sui-framework/packages/sui-system/sources/sui_system.move#L227-L301).
The framework also exposes the pool exchange-rate table for active and inactive
pools
([L533-L543](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/crates/sui-framework/packages/sui-system/sources/sui_system.move#L533-L543)).

Important native constraints are:

- New native stake must be at least 1 SUI
  ([validator_set.move L283-L300](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/crates/sui-framework/packages/sui-system/sources/validator_set.move#L283-L300)).
- Splitting `StakedSui` requires both pieces to remain at least 1 SUI; joining
  requires the same pool ID and activation epoch
  ([staking_pool.move L544-L590](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/crates/sui-framework/packages/sui-system/sources/staking_pool.move#L544-L590)).
- `FungibleStakedSui` can split by pool-token units and can join only with the
  same pool ID
  ([L509-L542](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/crates/sui-framework/packages/sui-system/sources/staking_pool.move#L509-L542)).
- Pending stake converts only after activation and only while the pool is
  active
  ([L273-L319](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/crates/sui-framework/packages/sui-system/sources/staking_pool.move#L273-L319)).
- Native FSS redemption floors the principal and reward portions independently
  ([L195-L270](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/crates/sui-framework/packages/sui-system/sources/staking_pool.move#L195-L270)).
  An upstream regression test shows one MIST remaining after the last FSS is
  redeemed
  ([staking_pool_tests.move L384-L441](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/crates/sui-framework/packages/sui-system/tests/staking_pool_tests.move#L384-L441)).
- Native exchange-rate conversion widens multiplication to `u128` and floors
  division
  ([staking_pool.move L629-L677](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/crates/sui-framework/packages/sui-system/sources/staking_pool.move#L629-L677)).

`Balance<SUI> <-> Coin<SUI>` is ordinary framework wrapping, not a conversion
from FSS into a fungible coin type
([coin.move L122-L149](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/crates/sui-framework/packages/sui-framework/sources/coin.move#L122-L149)).
Blast therefore needs its own registered `Coin<BLAST_SUI>` around the native
receipts.

## Proposed conventional Blast LST

### Package boundary

Place the future package under a new independent boundary such as
`sui/blast_sui/`. Its only external Move dependency beyond `Sui` is the
system `SuiSystem` package at the same pinned SHA. It must not depend on
`blast_fun`, and `blast_fun` must not depend on it.

This split is not cosmetic. The LST has different custody, authority, version,
and failure semantics. It also keeps the system-state dependency and native
staking calls out of launch trading and migration.

### Coin registration and bootstrap

Define one OTW-backed, unregulated coin type with 9 decimals. Use the pinned
Coin Registry `new_currency_with_otw` path, which creates a flexible-supply
currency and a unique `TreasuryCap`
([coin_registry.move L204-L237](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/crates/sui-framework/packages/sui-framework/sources/registries/coin_registry.move#L204-L237)).
Finalize its metadata but do not make the supply fixed or burn-only: a live LST
must mint and burn
([L280-L317](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/crates/sui-framework/packages/sui-framework/sources/registries/coin_registry.move#L280-L317)).

A one-time bootstrap must consume the treasury cap into the vault, accept the
intended validator address and staking-pool ID, verify that the pool maps back
to that active address, and bind both values immutably. The package must issue
no deny capability. The production framework exposes the pool-to-address lookup
but keeps the address-to-pool helper test-only
([sui_system.move L533-L547](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/crates/sui-framework/packages/sui-system/sources/sui_system.move#L533-L547),
[L741-L751](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/crates/sui-framework/packages/sui-system/sources/sui_system.move#L741-L751)).
Metadata authority should be either fixed at bootstrap or held by a narrowly
scoped metadata capability; it must never gain mint or validator-routing power.

### Minimal consensus state

The shared vault needs only facts that authorize mint, burn, and native custody:

- the unique `TreasuryCap<BLAST_SUI>`;
- immutable validator address and staking-pool ID;
- one liquid `Balance<SUI>` for native withdrawal rounding and sub-threshold
  dust;
- an activation-ordered `vector<StakedSui>` capped at three by ADR 0056, with
  same-epoch requests joined and a full queue degrading to liquid custody;
- at most one active `FungibleStakedSui` for the immutable pool;
- the last refreshed epoch and last valid native exchange rate; and
- the package-state version needed for upgrades.

There is no validator vector, weight map, registry, price oracle, quote-price
field, keeper allowlist, or generic hook. Total backing and the LST exchange
rate are derived during transitions from those canonical holdings. Store a
cached total only if the implementation proof shows it is necessary to keep a
transition bounded; never treat it as independent authority.

### Share accounting

Let `A` be conservative SUI backing after refresh and after subtracting any
already-accrued protocol claim. Let `L` be native LST supply.

```text
first mint, only when A = 0 and L = 0:
    lst_out = sui_in

later mint:
    lst_out = floor(sui_in_net * L / A)

partial redemption:
    sui_out = floor(lst_in * A / L)

full-supply redemption:
    sui_out = all remaining backing
```

All multiplication uses `u128` with proved `u64` result bounds. Mint rounds
down for existing holders. Partial redemption rounds down for remaining
holders. The full-supply branch drains all backing so no later first depositor
can capture orphaned dust. Abort if exactly one of `A` and `L` is zero.

An SDK can preview this math from object and system-state reads. The state
transition must recompute it and enforce a caller-supplied minimum output. The
SDK is never authority.

### Delegation and redemption

Every successful deposit must delegate all stakeable SUI to the immutable
validator in the same transaction. The only permitted liquid reserve is the
amount that cannot be staked because of the 1 SUI native minimum, plus exact
withdrawal rounding residue. Anyone may call a deterministic `stake_idle`
operation when that reserve reaches the native minimum; it has no address input.

Refresh must run before any mint or redemption. It converts activated pending
stake to FSS, merges only same-pool FSS, and reads the current exchange rate.
It must never scan backward over an unbounded number of epochs. A current table
entry can replace the cache directly; safe-mode behavior needs a pinned test.

Redemption uses liquid SUI first, then pending stake, then active FSS. It must
withdraw enough native stake to fund the exact conservative `sui_out`, return
that amount, and retain any native rounding surplus. The implementation needs a
proof for its FSS ceil conversion and worst-case principal/reward double-floor.
Do not copy SpringSui's `ACTIVE_STAKE_REDEEM_OFFSET = 100` without that proof
([storage.move L15-L20](https://github.com/suilend/liquid-staking/blob/49f757384e69065ab082dc2fcf653f4b285a1940/contracts/sources/storage.move#L15-L20),
[L449-L490](https://github.com/suilend/liquid-staking/blob/49f757384e69065ab082dc2fcf653f4b285a1940/contracts/sources/storage.move#L449-L490)).

### Validator failure

Every refresh must check that the immutable validator remains active. If it is
not active:

1. disable new minting;
2. withdraw all pending `StakedSui` rather than trying to convert it;
3. redeem all active FSS from the old pool into liquid SUI; and
4. keep ordinary user redemption open.

Do not silently redirect to another validator. A replacement validator has a
new pool ID, and native FSS from different pools cannot merge. Replacement is a
separate, explicitly authorized withdraw-and-restake migration decision. The
minimal first release can instead remain in unwind-only mode and require a new
product decision before accepting deposits again.

### Fees and reward timing

Current primary-source comparison, checked 2026-08-29:

- SpringSui recommends a 0-bps mint fee, requires at least a 2-bps unstaking
  fee in its current LST builder, and recommends a performance fee no higher
  than 10% ([SpringSui creation guide](https://docs.suilend.fi/springsui/how-to-create-your-own-springsui-lst)).
- Aftermath charges 5% of earned rewards on delayed unstaking and a
  reserve-dependent 0.1% to 1% fee on atomic unstaking
  ([Aftermath fee guide](https://docs.aftermath.finance/liquid-staking/afsui/fees)).

Blast's 2-bps default redemption fee matches the current SpringSui minimum
and is materially below Aftermath's atomic range. Unlike those protocol fees,
Blast retains the amount in blast custody for remaining `blastSUI` holders;
there is no treasury claim. The 100-bps ceiling is an emergency economic bound,
not the intended default.

No spread fee is required for Blast revenue if Blast already earns the validator
commission. Avoid a second yield fee unless product economics explicitly need
one.

Mint timing still needs protection. A new deposit is pending until the next
epoch, but an immediately minted fungible LST shares the next reward earned by
older active stake. There are two coherent policies:

- **Immediate mint:** charge a nonzero mint fee that is proven to cover the
  maximum reward-timing advantage under an approved bound. State the bound,
  rounding direction, recipient, and update authority in an ADR.
- **Activation receipt:** return a linear deposit receipt and mint the LST after
  the stake activation epoch at the realized rate. This removes the fee
  assumption but adds a second transaction and receipt lifecycle.

The activation receipt is the stronger accounting design. The immediate-mint
path is closer to SpringSui and has better UX. Do not implement a zero-fee
immediate mint merely because the observed epoch yield is usually small.

### Authority and upgrades

Ordinary mint, redeem, refresh, inactive-validator unwind, and idle staking are
permissionless. None accepts a validator address. The immutable validator
binding removes the need for an operational admin capability.

Hold the package `UpgradeCap` in the approved Blast release authority, separate
from `blast_fun`. Gate mutable shared state by an explicit version. Keep
redemption and inactive-validator unwind available during operational pauses.
Because an upgrade cannot erase old public Move bytecode, keep the first public
ABI as small as possible.

Events must record completed facts after mutation: vault creation and validator
binding, mint input/output/fee and post totals, redemption input/output/fee and
post totals, epoch refresh old/new backing, native delegation, native unwind,
and inactive-validator transition. Use the package's single stable event
envelope. Do not add an application sequence solely for indexing.

## Compatibility with `blast_fun` quote coins

No change to launch trading types is required. `Launch<Meme, Quote>` already
stores `Balance<Quote>`, accepts `Coin<Quote>` on buy, returns it on sell, and
carries the same `Quote` type into migration (`sui/launchpad/sources/launch.move:39-65,174-257,386-461`).
`LaunchConfig::allow_quote<Quote>` keys admission by the quote's original type
and snapshots quote-atomic virtual and terminal reserves
(`sui/launchpad/sources/launch_config.move:63-121,300-335`).

After the LST is deployed and verified, Blast can admit
`blast_sui::BLAST_SUI` through the existing admin flow. The administrator must
choose `virtual_quote` and `migration_quote_target` in 9-decimal
`BLAST_SUI` atomic units. No LST exchange-rate read belongs in the bonding curve.
The quote balance is non-rebasing; its SUI value appreciates off chain as the
LST exchange rate changes.

Admission does not prove migration support. The selected venue adapter must be
able to open a `Meme/BLAST_SUI` pool. Core pair immutability means it cannot
unwrap `BLAST_SUI` to SUI and migrate a different `Meme/SUI` pair. Confirm venue
support and initial external LST liquidity before allowlisting the quote.

## Two-coin principal/yield alternative

### The naive form is insolvent or unfair

Suppose each 1 SUI deposit mints both one principal coin `P` and one yield coin
`Y`. If `P` is redeemable for 1 SUI, the full deposit already backs `P`; no
principal backs `Y`. `Y` can only claim rewards.

This does not define fair perpetual fungible issuance. A later depositor who
receives new `Y` units contributes no already-earned yield, so those units
dilute the claims of existing `Y` holders. If the vault instead mints `Y` at its
current asset/share rate, a deposit that contributes zero current yield reserve
receives zero `Y`. Giving it rights to future yield requires valuing future time
and yield, which is not a canonical onchain asset.

Per-holder checkpoints do not fix a freely transferable coin. Correct
time-slicing needs dated yield series, non-fungible positions, or periodic
settlement. Those mechanisms are much larger than the requested quote coin.

### Coherent form: senior principal and junior capital

A solvent two-coin vault needs real junior capital. Define:

```text
A = total conservative SUI assets
S = supply of 1:1 senior quote coin
J = supply of junior yield shares
E = max(A - S, 0)       // junior equity
```

The flows are:

```text
senior deposit x:       A += x; S += x; E unchanged
senior redemption x:   A -= x; S -= x; E unchanged
native reward r:        A += r; E += r

junior deposit y:
    j_out = floor(y * J / E)      // 1:1 only for the first capital deposit
    A += y; J += j_out

junior redemption j:
    sui_out = floor(j * E / J)
    A -= sui_out; J -= j
```

Junior holders provide the first-loss buffer and receive all validator rewards,
including rewards earned on senior assets. Their yield is boosted by leverage
`S / E`. This is a real senior/junior staking product, not two receipts for one
deposit.

### Solvency requirements

The senior promise is valid only while `A >= S`. Code cannot guarantee 1:1 if
native custody loses principal, accounting is wrong, or an upgrade is
compromised. A strict promise therefore needs all of these controls:

- funded initial junior equity, not a zero-NAV yield coin;
- a maximum senior leverage or minimum equity ratio checked on every senior
  mint and junior withdrawal;
- no junior payout that leaves senior supply undercollateralized;
- immediate halt of senior mint and all junior exits when `A < S`;
- an explicit insolvency rule for senior holders, normally pro-rata redemption
  of remaining assets after full native unwind; and
- conservative native valuation and all rounding remainders assigned to junior
  equity.

If the junior token can redeem all equity while senior supply remains, the
first-loss buffer disappears. Either retain a minimum locked junior capital or
allow the final junior exit only after `S == 0`.

### Attacks and operational risks

| Risk | Effect | Required control |
| --- | --- | --- |
| Junior reward sniping | Junior capital enters just before an epoch reward and exits just after, capturing rewards earned by older stake. | Queue junior mint until activation, impose a proved fee/lock, or fix junior supply and capital at bootstrap. |
| Stale exchange rate | Cheap junior mint or excessive junior payout. | Refresh before every transition; abort or use a proved conservative cache in safe mode. |
| Share rounding | Repeated small operations transfer dust. | Junior mint and payout round down; senior atomic mint/redeem remains exact; full-exit cases have explicit dust rules. |
| Donation manipulation | An exposed arbitrary SUI join can move junior NAV before a victim mint. | Expose no donation function; treat native validator rewards as the only unsolicited equity growth. |
| Senior leverage growth | Tiny junior capital owns yield on large senior supply but cannot absorb tail loss. | Hard leverage/equity bound and senior-mint rejection. |
| Junior run | Junior exits race to leave remaining junior holders with risk or leave seniors unbuffered. | Post-withdraw collateral check and minimum locked equity. |
| Senior run | Par exits consume backing during a fault; last holders bear any deficit. | Detect insolvency before payout, unwind native stake, and switch all seniors to one pro-rata rule. |
| Validator inactivity | New stake and pending-to-FSS conversion stop. | Same automatic unwind-only mode as the conventional LST. |
| Shared-object congestion | One vault and `SuiSystemState` are hot shared inputs during a run. | Load-test throughput and communicate that instant economic redemption is not a latency guarantee. |
| Quote-pool depeg | `P` trades below 1 SUI because of contract, validator, gas, or congestion risk. | Permissionless par redemption, deep liquidity, monitoring, and no false “risk-free” claim. |

Principal deposits do not have the conventional LST's reward-sniping problem:
they add one asset and one equal senior liability, so junior equity does not
change. Junior deposits still have the timing problem because they buy the
residual reward stream.

### Comparison

| Property | Conventional exchange-rate LST | Senior `P` plus junior `Y` |
| --- | --- | --- |
| Coin count | One | Two |
| Quote unit vs SUI | Appreciates; not fixed at 1 | Senior targets 1:1 |
| Who receives rewards | Every LST holder | Junior holders only |
| Solvency model | One pro-rata claim on all assets | Senior par claim plus junior first-loss equity |
| Reward-timing issue | Immediate LST mint needs fee or activation delay | Senior mint is neutral; junior mint needs fee, lock, delay, or fixed supply |
| Exit policy | Pro-rata share redemption | Senior priority plus gated junior exits and insolvency mode |
| Audit surface | Share math, native receipt custody, one coin | All conventional native custody risks plus leverage, priority, two supplies, and exit gates |
| DeFi familiarity | Standard non-rebasing LST | Structured product; junior token is volatile residual equity |
| Fit for Blast quote | Works now through generic `Quote`, but SUI value drifts | Senior is a better SUI-denominated unit if the added risk system is justified |

The senior coin has no native yield and adds contract and validator risk over
holding SUI. Its reason to exist must be explicit Blast utility. The junior coin
is not a normal “boosted LST”; it is leveraged residual equity and can lose value
before seniors do.

### Recommendation on tranching

Reject the two-token design for v1. The generic `Quote` integration does not
require a 1:1 SUI peg, so the simpler conventional LST already satisfies the
current contract requirement.

If a stable SUI-denominated Blast quote becomes a hard product requirement,
open a separate ADR for the funded senior/junior model. Do not mint both coins
for one deposit. Require real junior capital, an explicit leverage bound, a
junior activation delay or lock, a minimum residual equity rule, and an
insolvency waterfall before implementation.

## Verification required before code is approved

1. Pin `SuiSystem` to `06734f6ff0af45d8632a14a4dc4b100197f6b1a2`
   and test with the repository's CLI pin.
2. Differential-test native exchange-rate math and both floor operations at
   zero, one MIST, 1 SUI, maximum supported supply, and full redemption.
3. Prove the exact FSS pool-token ceil and worst-case native redemption
   shortfall. Include the upstream one-MIST residual vector.
4. Test deposits and redemptions before and after activation, multiple deposits
   in one epoch, skipped refresh epochs, safe mode, validator removal, and an
   inactive pool.
5. Prove that every native receipt in vault custody has the immutable pool ID;
   add no path that accepts or routes to another validator.
6. Test first mint, last redemption, zero-result mint, stale-price rejection,
   maximum-width multiplication, and all rounding beneficiaries.
7. Model the epoch-boundary reward-sniping strategy for the selected immediate
   mint fee or prove the activation-receipt lifecycle.
8. Replay events from deployment and reconcile LST supply, liquid SUI, pending
   stake, FSS pool tokens, backing, and every completed mint/redemption.
9. Verify the target DEX adapter and venue can create and support
   `Meme/BLAST_SUI`; do not infer this from quote allowlisting.
10. Run full Move build, lint, tests, source-boundary checks, adversarial tests,
    and an independent audit before the coin is admitted as a Blast quote.

## Decisions resolved by ADR 0053

- Coin types and symbols are `FUN_SUI` / `funSUI` and
  `BLAST_SUI` / `blastSUI`.
- Blast deposits use a key-only activation receipt, not immediate minting.
- The only protocol-configurable economic charge is the blastSUI redemption
  fee, initially 2 bps and capped at 100 bps; it remains in blast custody.
- Validator removal permanently enters unwind-only mode in this version.
- Native blast deposits require at least one SUI; idle custody follows the
  native one-SUI stake minimum.
- ADR 0053 approves the funded two-ledger senior/yield design rather than the
  original conventional single-LST recommendation in this research note.
