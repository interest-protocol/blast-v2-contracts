# Sui OTW launch bootstrap and capability handoff

- Date: 2026-08-23
- Status: primary-source research; protocol conclusion superseded by ADRs 0035 and 0036
- Sui pin: `06734f6ff0af45d8632a14a4dc4b100197f6b1a2`

> The framework facts below remain valid, but
> [ADR 0035](../decisions/0035-initializer-finalized-meme-supply.md) and
> [ADR 0036](../decisions/0036-fixed-nine-decimal-generated-memes.md) replace the
> former Blast conclusion: the initializer now creates a nine-decimal currency,
> mints the fixed billion-coin inventory, and consumes the treasury cap before
> finalization.

## Question

For a newly generated Blast coin, where must `TreasuryCap<Meme>` and
`MetadataCap<Meme>` be created, what supply should the treasury capability have
when it reaches Blast, and how many transactions are required before Blast can
irreversibly select `Fixed` or `BurnOnly`?

## Framework facts

### The generated package must use the OTW constructor

`coin_registry::new_currency_with_otw` consumes the defining module's one-time
witness, constructs an unregulated `Currency<Meme>` whose supply state is
`Unknown`, and returns a new `TreasuryCap<Meme>`. The returned treasury
capability has an empty `Supply`, so `TreasuryCap.total_supply()` is zero until
someone explicitly mints.

Sources:

- `sui@06734f6:crates/sui-framework/packages/sui-framework/sources/registries/coin_registry.move:204-237`
- `sui@06734f6:crates/sui-framework/packages/sui-framework/sources/coin.move:78-109`
- [Pinned OTW constructor](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/crates/sui-framework/packages/sui-framework/sources/registries/coin_registry.move#L204-L237)

### Finalizing metadata does not require minting

`CurrencyInitializer.finalize` claims and returns the unique
`MetadataCap<Meme>`. On the OTW path it transfers the still-unshared
`Currency<Meme>` to the Coin Registry address. It does not consume or mutate the
returned `TreasuryCap<Meme>`.

Mysten Labs' standard unregulated OTW example follows exactly this shape: call
`new_currency_with_otw`, call `finalize`, and transfer the untouched treasury
capability and returned metadata capability to the publisher. It does not mint
inside `init`.

Sources:

- `sui@06734f6:crates/sui-framework/packages/sui-framework/sources/registries/coin_registry.move:319-330`
- [Pinned official OTW example](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/examples/move/coin/sources/my_coin_new.move)

### An empty initializer cannot become Fixed or BurnOnly

The initializer-only `make_supply_fixed` and `make_supply_burn_only` functions
both require `TreasuryCap.total_supply() > 0` and abort with `EEmptySupply` when
the cap is empty. Therefore a publish transaction that hands Blast an empty
treasury capability cannot also select its final Coin Registry supply state.

After registration, the corresponding methods on `&mut Currency<Meme>` consume
the treasury capability into `Fixed` or `BurnOnly`. Blast must mint the approved
initial supply before making that irreversible transition.

Source:

- [Pinned supply transitions](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/crates/sui-framework/packages/sui-framework/sources/registries/coin_registry.move#L280-L317)

### OTW registration has a separate promotion call

The framework describes the OTW path as a two-step registration operation:

1. package `init` constructs the currency and transfers it to the Coin Registry;
2. anyone calls `finalize_registration<Meme>` with the registry and the
   transferred `Receiving<Currency<Meme>>`, which recreates it at its canonical
   derived address and shares it.

`finalize_registration` returns no `Currency` value or reference. A later call
that needs `&mut Currency<Meme>` must use the now-shared currency as a transaction
input. Existing objects used by a transaction are resolved as inputs before
execution, so the newly shared currency is not available as another input in
the transaction that first creates it.

Sources:

- `sui@06734f6:crates/sui-framework/packages/sui-framework/sources/registries/coin_registry.move:204-208,348-389`
- [Pinned registration implementation](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/crates/sui-framework/packages/sui-framework/sources/registries/coin_registry.move#L348-L389)
- [Sui object-input transaction model](https://docs.sui.io/paper/sui.pdf)

## Correct fully finalized launch flow

If Blast requires the Coin Registry to report `Fixed` or `BurnOnly` as soon as
the launch opens, the flow is three onchain transactions:

### Transaction 1: publish generated coin package

The generated module's `init` uses its OTW to create the current unregulated
currency, calls `finalize`, and leaves the treasury capability at total supply
zero. The empty `TreasuryCap<Meme>`, `MetadataCap<Meme>`, and creation facts such
as decimals should be wrapped in a Blast-owned `LaunchTicket<Meme>` and delivered
to the publisher.

For the strongest provenance boundary, the public Blast ticket constructor
should itself consume the OTW and call `new_currency_with_otw`; accepting
arbitrary already-created capabilities would not independently prove that the
currency came through the generated OTW path.

### Transaction 2: promote the currency

Call the permissionless `coin_registry::finalize_registration<Meme>`. This can
be submitted by a relayer because it grants no authority to the caller.

### Transaction 3: open the Blast launch

Pass the shared `&mut Currency<Meme>` and consume `LaunchTicket<Meme>`. Before
mutation, launch intake should verify at least:

- the treasury capability still has total supply zero;
- the currency's recorded treasury-cap ID matches the ticket's capability;
- the currency's recorded metadata-cap ID matches the ticket's capability;
- the currency is unregulated and still has `Unknown` supply state;
- the requested nonzero supply is at most one billion whole coins after decimal
  normalization; and
- the owner-selected burn mode and every burn parameter agree.

Only after all checks should Blast mint the complete supply once. It then
consumes `TreasuryCap<Meme>` through `Currency.make_supply_fixed` for a
non-burnable launch or `Currency.make_supply_burn_only` for a burnable launch.
The minted inventory enters `Launch`, while `MetadataCap<Meme>` remains inside
launch custody until the one-time creator claim returns it separately alongside
`CreatorCap<Meme>`.

This is three chain transactions but can remain two user approvals: the user
publishes, a relayer performs permissionless registration, and the user signs
the launch transaction.

## Different two-transaction architecture

Promotion and launch creation can share transaction 2 only if launch creation
does not borrow the newly shared `Currency<Meme>`. Blast could mint with and
retain `TreasuryCap<Meme>` inside launch state, record the owner's burnable flag,
burn through the retained treasury capability during bonding when allowed, and
consume the capability into `Fixed` or `BurnOnly` at migration.

That is a coherent but materially different design:

- Coin Registry reports `Unknown`, not `Fixed` or `BurnOnly`, throughout
  bonding;
- Blast core retains mint authority during bonding, even if it exposes no mint
  function;
- the upgrade authority becomes part of the effective fixed-supply trust model;
  and
- final supply state depends on a later transition.

It must not be described as equivalent to finalizing supply at launch.

## Conclusion for Blast

The capability correction is valid: the generated OTW package should not mint
the launch supply or consume `TreasuryCap<Meme>`. It should hand an empty treasury
capability and the unique metadata capability into Blast-defined custody.

Blast chooses three chain transactions/two user approvals so `Fixed` or
`BurnOnly` becomes final at launch. An event-driven Blast worker performs the
permissionless registration transaction between the user's publish and launch
approvals. Blast does not retain mint authority during bonding.
