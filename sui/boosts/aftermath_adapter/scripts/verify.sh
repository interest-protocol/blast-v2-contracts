#!/usr/bin/env bash
# Runs the pinned-toolchain gate for the Aftermath leverage adapter.
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
  boundaries)
    bash "$package_dir/scripts/check_source_boundaries.sh"
    ;;
  abi)
    node "$package_dir/scripts/check_mainnet_abi.mjs" --self-test
    node "$package_dir/scripts/check_mainnet_abi.mjs"
    ;;
  proof-self-test)
    node "$package_dir/scripts/dev_inspect_activation.mjs" --self-test
    ;;
  proof)
    node "$package_dir/scripts/check_mainnet_abi.mjs"
    node "$package_dir/scripts/dev_inspect_activation.mjs"
    ;;
  local)
    bash "$package_dir/scripts/check_source_boundaries.sh"
    node --test --test-concurrency=1 "$package_dir/scripts/active_ptb.test.mjs" "$package_dir/scripts/initial_margin.test.mjs"
    node "$package_dir/scripts/check_mainnet_abi.mjs" --self-test
    node "$package_dir/scripts/dev_inspect_activation.mjs" --self-test
    sui move build --path "$package_dir" --build-env mainnet
    sui move lint --path "$package_dir" --build-env mainnet --warnings-are-errors
    sui move test --path "$package_dir" --build-env mainnet --lint --warnings-are-errors
    ;;
  all)
    bash "$package_dir/scripts/verify.sh" local
    bash "$package_dir/scripts/verify.sh" proof
    ;;
  *)
    printf 'usage: %s [build|lint|test [filter]|boundaries|abi|proof-self-test|proof|local|all]\n' "$0" >&2
    exit 2
    ;;
esac
