# Publishing immutable Series1

Series1 is a permanent policy package. It must never leave an `UpgradeCap`
owned by an address, governance object, or another package. Publish it and
consume the returned capability in the same programmable transaction block:

```bash
bash scripts/publish_immutable.sh testnet --preview
bash scripts/publish_immutable.sh testnet --execute > series-one-publication.json
```

The preview is mandatory review evidence but is not publication evidence. The
executed JSON and its transaction digest are the publication record. Before an
adapter is published or a Vault is issued, review the committed source and
verify from that digest that:

1. the transaction contains one `Publish` command for this Series1 package;
2. the returned `UpgradeCap` is the argument to
   `0x2::package::make_immutable` in that same transaction;
3. the effects created the package and did not leave an `UpgradeCap` object;
4. the deployed package bytecode matches the reviewed source; and
5. the package ID, transaction digest, chain identifier, source commit, and
   source tree are recorded in the release evidence.

Publication creates no administration state. Administrators authenticate against
the singleton Blast ACL: its `SuperAdminCap` holder grants each
`blast_boosts_core` role to the `AdminCap` that needs it, and every Series1
adapter accepts only these four role types.

Do not publish Series1 with `sui client publish`. Do not split publication and
`make_immutable` across transactions. A failed or ambiguous verification
blocks adapter publication and Vault issuance. Series2 is published as a new
immutable package; it does not upgrade Series1.
