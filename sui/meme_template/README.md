# Generated Meme package template

This compiler-input package creates one Blast `LaunchTicket<MEME>` at
publication. The SDK patches reviewed constants in the compiled module; it does
not fork this source for each launch.

The publication boundary is defined by
[ADR 0051](../../docs/decisions/0051-generated-meme-package-template.md) and the
coin lifecycle by the related accepted ADRs in the
[decision index](../../docs/decisions/README.md). The SDK artifact and its
verification checks own the embedded bytecode hash. This package's source,
manifest, and lockfile own the local implementation and dependency facts.
