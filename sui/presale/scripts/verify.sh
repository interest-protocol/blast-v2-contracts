#!/usr/bin/env bash
# Runs the complete pinned-toolchain gate for blast_presale.
set -euo pipefail

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

case "${1:-all}" in
  build)
    sui move build --path "$package_dir" --build-env mainnet
    ;;
  lint)
    sui move lint --path "$package_dir" --build-env mainnet --warnings-are-errors
    ;;
  boundaries)
    bash "$package_dir/scripts/check_source_boundaries.sh"
    python3 "$package_dir/scripts/test_publish.py"
    ;;
  test)
    shift || true
    sui move test --path "$package_dir" --build-env mainnet --lint --warnings-are-errors "$@"
    ;;
  all)
    bash "$package_dir/scripts/check_source_boundaries.sh"
    python3 "$package_dir/scripts/test_publish.py"
    sui move build --path "$package_dir" --build-env mainnet
    sui move lint --path "$package_dir" --build-env mainnet --warnings-are-errors
    sui move test --path "$package_dir" --build-env mainnet --lint --warnings-are-errors
    ;;
  *)
    printf 'usage: %s [build|lint|boundaries|test [filter]|all]\n' "$0" >&2
    exit 2
    ;;
esac
