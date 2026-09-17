# Blast launchpad

This package owns the Blast launch lifecycle, custody, configuration, fees,
creator authority, and venue-neutral migration handoff. It imports no venue
package; adapters compose with it through a programmable transaction block.

Administration is not implemented here. `blast_admin` owns the reusable ACL,
operational-generation, and package-custody primitives; this package owns the
`BLAST_FUN_DOMAIN` marker, its governance constants, and the one package-admin
role it exports to Migrators and Distributor. Those two packages share this
domain's administrator membership while keeping their own generation and
`PackageAdmin`.

A governed upgrade is one transaction: authorize the digest, run the native
Upgrade command, then call `package_admin::commit_upgrade_and_advance`, which
commits the receipt to the same sealed cap and advances the operational
generation. There is no separate activation step.

Use these sources instead of a duplicated module inventory:

- [architecture](../../docs/architecture.md) for package and SDK boundaries;
- [decision index](../../docs/decisions/README.md) for accepted protocol rules;
- [test vectors](../../docs/vectors/README.md) and
  [release gates](../../docs/testing.md) for verification;
- [`../meme_template/`](../meme_template/) for generated-coin publication.

Move source and tests are authoritative for the current ABI, storage, events,
errors, and behavior; `sources/lib/errors.move` is the sole error registry.
`Move.toml` and `Move.lock` are authoritative for the
toolchain environments and dependency graph.
