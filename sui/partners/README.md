# Blast partners

`blast_partners` holds Blast's partner codes, shared by every Blast product. A
product pays a partner its share of the fee Blast charges on a trade by calling
`pay` with that fee, and records the payment in its own trade event.

Everything Blast changes about a partner (its share and which cap is live) takes
effect seven days after it is scheduled. The package is published and made
immutable in one transaction (`scripts/publish_immutable.sh`), so nobody can
shorten that delay. The partner's own recipient changes apply at once.

Read [ADR 0095](../../docs/decisions/0095-partner-codes.md) and the
[guide](../../docs/partner-codes.md) before changing this package.
`scripts/verify.sh` runs the package gate.
