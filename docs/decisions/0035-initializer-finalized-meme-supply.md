# 0035: Finalize generated Meme supply during initialization

- Status: accepted
- Date: 2026-08-25
- Amends: [0002](0002-coin-creation-and-currency-authority.md), [0023](0023-generated-coin-supply-and-metadata-custody.md), [0024](0024-generated-coin-launch-ticket.md)
- Amended by: [0036](0036-fixed-nine-decimal-generated-memes.md)

## Sources

| Ref | Full commit | Repository |
| --- | --- | --- |
| `sui@06734f6` | `06734f6ff0af45d8632a14a4dc4b100197f6b1a2` | MystenLabs/sui |

## Context

ADRs 0023 and 0024 left the generated `TreasuryCap<Meme>` empty inside
`LaunchTicket<Meme>`. They deferred minting and the irreversible `Fixed` or
`BurnOnly` transition until after permissionless Coin Registry registration,
which meant the future launch operation also needed the shared
`Currency<Meme>`.

That deferral is unnecessary. All inputs needed to finalize supply are already
known in the generated package's initializer:

- Blast fixes every generated Meme supply at exactly one billion whole coins;
- the initializer already receives the Meme decimals;
- the generated package commits the owner's immutable `burnable` choice; and
- `CurrencyInitializer.make_supply_fixed` and
  `CurrencyInitializer.make_supply_burn_only` exist specifically to consume a
  nonempty `TreasuryCap` before finalization.

The pinned framework requires the initializer supply to be nonzero, then stores
the cap's `Supply` in either `SupplyState::Fixed` or `SupplyState::BurnOnly`
(`sui@06734f6:crates/sui-framework/packages/sui-framework/sources/registries/coin_registry.move:280-317`).
`coin::mint_balance` increases that same cap's supply and returns an owned
`Balance<Meme>` without creating another object
(`sui@06734f6:crates/sui-framework/packages/sui-framework/sources/coin.move:315-327`).

Keeping the empty cap in a ticket therefore prolongs mint authority and forces a
future shared-object input even though neither is required by product policy.

## Decision

### Mint exactly once in `launch_ticket::new`

After validating creator identity and the decimals bound,
`launch_ticket::new` creates the OTW currency, mints exactly:

```text
1_000_000_000 * 10^meme_decimals
```

atomic units as one `Balance<Meme>`, and immediately consumes the unique
`TreasuryCap<Meme>`:

- `burnable == false` calls `initializer.make_supply_fixed(treasury_cap)`;
- `burnable == true` calls
  `initializer.make_supply_burn_only(treasury_cap)`.

Only after that irreversible transition does the constructor finalize the
initializer and receive `MetadataCap<Meme>`. No raw treasury capability leaves
the constructor or survives in Blast state.

### Decimal bound

Sui coin amounts and `Balance` values are `u64`. Exactly one billion whole coins
fits through ten decimals:

```text
1_000_000_000 * 10^10 = 10_000_000_000_000_000_000 <= u64::MAX
```

Eleven decimals would exceed `u64::MAX`. Generated Meme decimals are therefore
bounded to `0..=10` before currency construction. Error code 61 records an
invalid Meme decimals value. The bound makes the subsequent `u64` exponent and
multiplication overflow-proof.

### Ticket and event shape

`LaunchTicket<Meme>` stores:

- its `UID`;
- the complete `Balance<Meme>` inventory;
- the native `MetadataCap<Meme>`;
- one `CreatorAuthority<Meme>`; and
- the immutable `burnable` choice.

`into_parts` returns those four launch inputs. It never returns a
`TreasuryCap<Meme>`.

`LaunchTicketCreated` replaces `treasury_cap_id` with `initial_supply`. A cap id
would describe an object deliberately consumed before the event; the minted
amount is the replay-relevant fact that launch accounting must conserve.

### Launch sequencing

Registration remains permissionless, but launch intake no longer needs to mint,
select supply state, or borrow `Currency<Meme>`. A future launch transaction can
consume the ticket's balance directly. The `Currency<Meme>` shared object is
needed later only for operations native to `BurnOnly`, such as completing a
deferred burn.

This design permits registration finalization and launch opening to share one
programmable transaction after package publication, subject to the future
launch module's own inputs. It does not require that composition before the
launch module is implemented.

## Alternatives considered

**Keep an empty treasury cap until launch.** Rejected: the complete supply and
mode are already known, so this retains stronger authority and adds a shared
currency dependency without buying configurability.

**Mint in the generated package and pass arbitrary capabilities into Blast.**
Rejected: Blast would lose the strong provenance boundary created by consuming
the OTW and invoking `new_currency_with_otw` itself.

**Retain the treasury cap after minting.** Rejected: no later operation needs
mint authority. Burn-only behavior is provided by the shared `Currency<Meme>`
after the initializer consumes the cap.

**Always select `BurnOnly`.** Rejected: the existing owner choice deliberately
supports both immutable fixed supply and permanently non-inflationary burnable
supply.

## Consequences

- Every ticket contains the full fixed initial inventory rather than an empty
  mint capability.
- Coin Registry supply state is final before registration promotion and cannot
  later be changed by Blast, an adapter, or the ticket holder.
- The future launch API does not accept Meme currency merely to mint or lock
  supply.
- Burnable launches still require `Currency<Meme>` when they actually destroy
  pending balances; fixed launches never do.
- Generated Meme packages must choose at most ten decimals.
- The ticket creation event no longer exposes a consumed capability id.

## Verification

- Fixed and burnable ticket tests assert the exact normalized billion-unit
  balance and immutable mode.
- Decimals-0 and decimals-10 boundary tests prove the smallest and largest
  normalized supplies, while decimals 11 aborts with code 61 before currency
  construction.
- Structural checks require balance custody, both initializer supply
  transitions, exact minting, and the absence of `TreasuryCap<Meme>` from the
  ticket and `into_parts`.
- Event tests pin `initial_supply` and reject restoration of
  `treasury_cap_id`.
- Build, warnings-as-errors lint, full tests, and source-boundary checks remain
  release gates.
