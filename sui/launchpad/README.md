# Blast launchpad

This package owns the Blast launch lifecycle, custody, configuration, fees,
creator authority, and venue-neutral migration handoff. It imports no venue
package; adapters compose with it through a programmable transaction block.

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
