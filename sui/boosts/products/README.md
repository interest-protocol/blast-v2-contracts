# Blast Boost products

`blast_boosts_products` is the Blast-owned home of every Series1 Boost
product tag. It holds no state and no authority. Its one module declares the
package one-time witness and, as products are approved, one empty `drop`
struct per product named after the ticker, so a holder's coin reads as
`…::blast_boost::BlastBoost<…::blast_boosts_products::TSLA_3X>` on
every explorer and wallet.

No product is declared yet. Adding one is a compatible upgrade of this package;
issuing its currency still requires the Series1 issuer role in the adapter that
custodies the product. See
[ADR 0085](../../../docs/decisions/0085-explorer-visible-type-naming.md) for
the naming rule and the adapter README for issuance.
