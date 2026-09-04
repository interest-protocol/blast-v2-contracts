# Blast leverage Series1

`blast_leverage_series_one` is the venue-neutral core shared by Series1
adapters. It owns policy, lifecycle, accounting, observations, and the shared
administrator roles; adapters own currencies, venue accounts, package
capabilities, and outer `Vault<Product>` objects.

Read the accepted Series1 ADRs from the
[decision index](../../../docs/decisions/README.md) and the
[leverage implementation rules](../../../docs/leverage-implementation-lessons.md)
before changing this package. Run `scripts/verify.sh` for local gates. Source,
tests, `Move.toml`, and `Move.lock` own current behavior, errors, and dependency
facts.

Series1 exposes no public user mint or redemption. Adapter activation may mint
only the fixed seed supply and permanently deliver it to `@0x0`; user-facing
mint and redemption remain a later adapter slice after deployed activation and
health parity evidence passes.
