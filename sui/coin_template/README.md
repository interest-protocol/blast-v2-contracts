# Coin template

This compiler-input package creates one standalone Sui coin when it is
published. It has no Blast dependency and gives Blast no authority over the
coin, and the coin cannot launch on Blast: a launch needs the `LaunchTicket`
that only the [launch ticket template](https://github.com/interest-protocol/blast-v2-move/blob/main/sui/launch_ticket_template/README.md)
creates.

Like that template, the SDK does not compile this source per coin. It patches
the compiled module's constants and renames its `my_coin` module and `MY_COIN`
one-time witness after the coin, so the coin type is
`<package>::<module>::<WITNESS>` and the Coin Registry proves it is unique.

The package exposes no public functions. Its initializer creates the currency
from these constants, then delivers the supply and the capabilities:

| Constant | Meaning |
| --- | --- |
| `SYMBOL`, `NAME`, `DESCRIPTION`, `ICON_URL` | coin metadata; the symbol must be ASCII printable |
| `DECIMALS` | decimal places |
| `INITIAL_SUPPLY` | atomic units minted at publication; `0` mints nothing |
| `SUPPLY_RECIPIENT` | receives the initial supply as one `Coin` |
| `SUPPLY_MODE` | `0` mintable: the `TreasuryCap` goes to `TREASURY_CAP_RECIPIENT`; `1` fixed; `2` burn-only, so any holder may burn through the `Currency`; `1` and `2` destroy the `TreasuryCap` and need a nonzero initial supply |
| `TREASURY_CAP_RECIPIENT` | receives the `TreasuryCap` in mintable mode; unused otherwise |
| `METADATA_MUTABLE` | `true`: the `MetadataCap` goes to `METADATA_CAP_RECIPIENT`; `false`: it is deleted and the metadata is frozen |
| `METADATA_CAP_RECIPIENT` | receives the `MetadataCap` when the metadata is mutable; unused otherwise |

The SDK finds each constant by its type and default value, so the defaults are
distinct and `scripts/check_source_boundaries.sh` keeps them so. The native
`Currency` is delivered to the Coin Registry address; anyone may complete its
registration with `coin_registry::finalize_registration` in a later
transaction. The publisher keeps the `UpgradeCap`.

The design is recorded in
[ADR 0108](../../docs/decisions/0108-standalone-coin-template.md). This
package's source, manifest, and lockfile own the implementation and dependency
facts.
