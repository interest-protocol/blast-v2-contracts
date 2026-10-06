# 0108: A standalone coin template beside the launch ticket template

- Status: proposed
- Date: 2026-10-06
- Amends: [0051](0051-generated-meme-package-template.md), whose package
  `meme_template` becomes `launch_ticket_template`

## Context

The one generated-package template, `meme_template`, makes a coin that can only
launch: its initializer hands the supply and both capabilities to
`launch_ticket::new` and delivers the returned `LaunchTicket`. Its name says
what it makes (a Meme) rather than what it is for (a launch ticket), which left
no clear name for a template that makes a coin without launching it.

Blast also needs that second template. A creator who wants a plain Sui coin,
not a bonding-curve launch, chooses its metadata, its supply and how it may
change, and who holds the supply and each capability. None of that may pass
through Blast: the coin is the creator's, and no Blast package should be its
dependency or hold its authority.

A Sui initializer takes no arguments and cannot return owned values, so each of
those choices must be a constant in the compiled module, as ADR 0051 already
does for the launch ticket.

## Decision

**Rename.** `sui/meme_template` becomes `sui/launch_ticket_template`, package
and named address `launch_ticket_template`. Its module `meme` and witness `MEME`
are unchanged, so its compiled bytecode is byte-identical and the SDK's embedded
template stays valid.

**New package.** `sui/coin_template` (`coin_template`) depends only on the Sui
framework. Its module `my_coin` defines the one-time witness `MY_COIN`, which
the SDK renames per coin, and exposes no public functions. Its initializer
passes eleven constants to one private function that:

1. creates the currency with `coin_registry::new_currency_with_otw` from
   `SYMBOL`, `NAME`, `DESCRIPTION`, `ICON_URL`, and `DECIMALS`;
2. mints `INITIAL_SUPPLY` atomic units to `SUPPLY_RECIPIENT`, or nothing when
   it is zero;
3. settles the `TreasuryCap` by `SUPPLY_MODE`: `0` (mintable) transfers it to
   `TREASURY_CAP_RECIPIENT`; `1` (fixed) and `2` (burn-only) consume it into
   the `Currency` and require a nonzero initial supply; any other value aborts
   with `EInvalidSupplyMode`;
4. settles the `MetadataCap` by `METADATA_MUTABLE`: `true` transfers it to
   `METADATA_CAP_RECIPIENT`; `false` deletes it, freezing the metadata.

The `Currency` goes to the Coin Registry address, and anyone may share it with
`coin_registry::finalize_registration` in a later transaction, as for the
launch ticket. The publisher keeps the `UpgradeCap`; making the package
immutable is the SDK's publishing choice.

The SDK patches each constant by its type and default value, so every slot has
a distinct default and no other constant in the module shares a pool type with
one. The mode values are literals in the private function, not named
constants, because a named constant equal to `SUPPLY_MODE`'s default would
share its pool entry and be patched with it. The source-boundary script checks
these rules.

## Alternatives considered

**Deliver everything to the publisher.** Rejected: the creator chooses each
recipient, and objects an initializer transfers cannot be redirected later in
the publishing transaction.

**Two booleans, mintable and burnable, for the supply mode.** Rejected: the
module has room for one boolean slot beside `METADATA_MUTABLE`'s, and "mintable
but not burnable" has no meaning, since the `TreasuryCap` holder can always
burn.

**A capped mintable supply.** Rejected for now: Sui has no native cap on a
`TreasuryCap`, and enforcing one would need a Blast-owned wrapper and a Blast
dependency, which this template exists to avoid.

**A regulated (deny-list) coin.** Rejected for now: Blast venues reject
regulated coins, and the `DenyCapV2` recipient and pause flag would add two
slots without a product requirement.

**Reuse `launch_ticket::new` and unwrap the ticket.** Rejected: it would make a
plain coin depend on Blast and fix its supply at one billion tokens.

## Consequences

- A coin from `coin_template` can never launch on Blast: only
  `launch_ticket_template` creates a `LaunchTicket`.
- Blast holds no authority over a standalone coin and is not in its dependency
  graph.
- The SDK needs a second embedded template and patcher, and its ABI check and
  fixtures follow the renamed package path.
- Indexers cannot find standalone coins by a Blast event; they read the
  publishing transaction or the registered `Currency`.

## Verification

From `sui/coin_template/`:

```bash
sui move build
sui move lint --warnings-are-errors
sui move test --lint
bash scripts/check_source_boundaries.sh
```

Tests cover the template defaults through `init`, each supply mode, zero
supply, both metadata choices, and the invalid-mode and empty-supply aborts.
From `sui/launch_ticket_template/`, the same build, lint, and boundary script
pass, and `build/launch_ticket_template/bytecode_modules/meme.mv` matches the
`meme_template` build byte for byte.
