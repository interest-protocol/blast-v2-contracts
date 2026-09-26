# Blast partners

`blast_partners` holds Blast's partner codes, shared by every Blast product. A
company holds one `PartnerCap` for all its deals; each deal is a `Partner` with
its own share of Blast's fee and its own recipient. A product pays a partner its
share of the fee Blast charges on a trade by calling `pay`, which emits
`PartnerPaid`; the product records the trade in its own event.

Everything Blast changes about a partner (its share and which cap manages it)
takes effect seven days after it is scheduled, through `blast_fun_timelock` from
[blast-util-contracts](https://github.com/interest-protocol/blast-util-contracts).
Each package is published and made immutable in its own transaction, so nobody
can shorten that delay: the timelock first, from the util repository, then this
one with `scripts/publish_immutable.sh`. The cap holder's recipient changes apply
at once.

Read [ADR 0095](../../docs/decisions/0095-partner-codes.md) and the
[guide](../../docs/partner-codes.md) before changing this package.
`scripts/verify.sh` runs the package gate.
