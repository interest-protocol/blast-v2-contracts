# Blast leverage coins

This directory groups the independently published leverage protocol packages.
It is not itself a Move package.

```text
leverage_coins/
├── series_one/           blast_leverage_series_one
└── aftermath_adapter/    blast_leverage_aftermath (future)
```

Series1 contains its accounting and bounded-value libraries, immutable policy,
lifecycle, operational-version gate, and role administration. Each venue
adapter depends inward on the Series package it executes. A future `series_two`
will be a sibling package with its own currency type and policy family.
