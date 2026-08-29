# Vesting packages

This directory contains independently deployed Move packages for approved
vesting designs. Each design gets its own child directory, manifest, lockfile,
tests, authority model, accounting invariants, and release record.

The approved first design lives in [`linear/`](linear/). It implements one
fully funded stepped-linear schedule with an optional cliff and fair,
capability-gated cancellation. See
[ADR 0052](../../docs/decisions/0052-stepped-linear-vesting.md).
