#!/usr/bin/env bash
# Runs the pinned-toolchain gate for Blast leverage Series1.
set -euo pipefail

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

case "${1:-all}" in
  build)
    sui move build --path "$package_dir" --build-env mainnet
    ;;
  lint)
    sui move lint --path "$package_dir" --build-env mainnet --warnings-are-errors
    ;;
  test)
    shift || true
    sui move test --path "$package_dir" --build-env mainnet --lint --warnings-are-errors "$@"
    ;;
  simulation)
    node --test --test-concurrency=1 "$package_dir/scripts/calibrate_mint_minimum.test.mjs"
    node "$package_dir/scripts/calibrate_mint_minimum.mjs"
    ;;
  boundaries)
    bash "$package_dir/scripts/check_source_boundaries.sh"
    ;;
  all)
    bash "$package_dir/scripts/verify.sh" simulation
    bash "$package_dir/scripts/check_source_boundaries.sh"
    sui move build --path "$package_dir" --build-env mainnet
    sui move lint --path "$package_dir" --build-env mainnet --warnings-are-errors
    sui move test --path "$package_dir" --build-env mainnet --lint --warnings-are-errors
    ;;
  *)
    printf 'usage: %s [build|lint|test [filter]|boundaries|simulation|all]\n' "$0" >&2
    exit 2
    ;;
esac
