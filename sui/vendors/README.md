# Vendor contracts

One-off Move packages built for a specific partner's custom demands. Each lives in
its own directory here, is published and upgraded on its own, and depends inward
on the Blast packages it extends; no core package imports a vendor package.

A vendor package that creates `blast_presale` sales does so through the public
`blast_presale::new` and `migrate` with its own sealed witness, which the presale
`AdminCap` must allow in the shared `CreationPolicy` before the package can open a
sale ([ADR 0104](../../docs/decisions/0104-external-presale-migrators-and-vendor-packages.md)).

Keep each package self-contained: its venue interface stubs under `interfaces/`,
its own `scripts/verify.sh`, publish script, and README naming the partner terms
it fixes, its custody, and its deployment order.

| Directory | Purpose |
| --- | --- |
| [`aftermath_dao_presale`](aftermath_dao_presale/README.md) | Presale migrator into a 50/50 Aftermath pool behind a 2% DAO-fee pool |
