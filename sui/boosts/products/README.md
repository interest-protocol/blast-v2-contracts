# Blast Boost products

`blast_boosts_products` is the Blast-owned home of every Series1 Boost
product tag. It holds no state and no authority. Its one module declares the
package one-time witness and one empty struct with no abilities per product named
`<TICKER>_<SIDE>_<LEVERAGE>`, so a holder's coin reads as
`…::blast_boost::BlastBoost<…::blast_boosts_products::NVDA_BULL_2X>` on
every explorer and wallet. `BULL` tracks the perp long, `BEAR` the inverse.

A bull and a bear 2X tag are declared for every Aftermath perpetual market
live on 2026-09-18. A declared tag is not a live product: issuing its currency
requires the Series1 issuer role in the adapter that custodies it. Adding a
tag, for a new market or a new leverage, is a compatible upgrade of this
package; the UpgradeCap must stay held and should be restricted to
`sui::package::only_additive_upgrades` at deployment. See
[ADR 0085](../../../docs/decisions/0085-explorer-visible-type-naming.md) for
the naming rule and the adapter README for issuance.
