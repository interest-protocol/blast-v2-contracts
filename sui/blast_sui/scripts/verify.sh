#!/usr/bin/env bash
# Runs the pinned-toolchain release gate for the Blast SUI package.
set -euo pipefail

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

case "${1:-all}" in
  build)
    sui move build --path "$package_dir" --build-env testnet
    sui move build --path "$package_dir" --build-env mainnet
    ;;
  lint)
    sui move lint --path "$package_dir" --warnings-are-errors
    ;;
  test)
    shift || true
    sui move test --path "$package_dir" --lint --warnings-are-errors "$@"
    ;;
  all)
    sui move build --path "$package_dir" --build-env testnet
    sui move build --path "$package_dir" --build-env mainnet
    sui move lint --path "$package_dir" --warnings-are-errors
    sui move test --path "$package_dir" --lint --warnings-are-errors
    ;;
  *)
    printf 'usage: %s [build|lint|test [filter]|all]\n' "$0" >&2
    exit 2
    ;;
esac
