# Blast leverage coins

This directory groups the independently published leverage protocol packages.
It is not itself a Move package.

```text
leverage_coins/
├── series_one/           blast_leverage_series_one
└── aftermath_adapter/    blast_leverage_aftermath
```

Series1 contains venue-neutral accounting, immutable policy, lifecycle, and one
shared administrator registry. Its `AdminCap` works across every Series1
adapter. Each adapter depends inward on Series1, owns its own versioning and
venue custody, and defines `Vault<Product>` as its leverage currency type.

The product witness distinguishes currencies inside one adapter. For example,
the same Aftermath package can issue both `Vault<Sui2x>` and `Vault<Sui5x>`.
Coin Registry permits each concrete product type once.

A future `series_two` is a separate sibling package and coin family, not an
upgrade of Series1.
