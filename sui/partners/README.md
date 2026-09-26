# Blast partners

`blast_partners` holds Blast's partner codes, shared by every Blast product. A
company holds one `PartnerCap` for all its deals; each deal is a `Partner` with
its own share of Blast's fee and its own recipient. A product pays a partner its
share of the fee Blast charges on a trade by calling `pay`, which emits
`PartnerPaid`; the product records the trade in its own event.

Everything Blast changes about a partner (its share and which cap manages it)
takes effect seven days after it is scheduled, through `blast_fun_timelock` from
[blast-util-contracts](https://github.com/interest-protocol/blast-util-contracts).
Both packages are immutable, so nobody can shorten that delay: the timelock is
published at `0x1749b76a3ae065dedfe847578b07826fa83d1e18ff485d9e4f9647f3698e104d`, and this package is published with
`scripts/publish_immutable.sh`. The cap holder's recipient changes apply
at once.

Read [ADR 0095](../../docs/decisions/0095-partner-codes.md) and the
[guide](../../docs/partner-codes.md) before changing this package.
`scripts/verify.sh` runs the package gate.
