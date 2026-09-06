#!/usr/bin/env bash
# Runs the complete pinned-toolchain gate for blast_admin.
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
  boundaries)
    bash "$package_dir/scripts/test_check_source_boundaries.sh"
    bash "$package_dir/scripts/check_source_boundaries.sh"
    ;;
  all)
    bash "$package_dir/scripts/test_check_source_boundaries.sh"
    bash "$package_dir/scripts/check_source_boundaries.sh"
    sui move build --path "$package_dir" --build-env testnet
    sui move build --path "$package_dir" --build-env mainnet
    sui move lint --path "$package_dir" --warnings-are-errors
    sui move test --path "$package_dir" --lint --warnings-are-errors
    ;;
  *)
    printf 'usage: %s [build|lint|test [filter]|boundaries|all]\n' "$0" >&2
    exit 2
    ;;
esac
