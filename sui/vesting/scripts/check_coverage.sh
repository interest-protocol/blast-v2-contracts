#!/usr/bin/env bash
set -euo pipefail

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

sui move test --path "$package_dir" --coverage
coverage_summary="$(sui move coverage --path "$package_dir" summary)"
printf '%s\n' "$coverage_summary"

if ! grep -Fq '% Move Coverage: 100.00' <<<"$coverage_summary"; then
  printf 'Expected 100.00%% Move coverage.\n' >&2
  exit 1
fi
