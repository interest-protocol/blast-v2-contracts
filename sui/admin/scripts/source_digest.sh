#!/usr/bin/env bash
# Prints the source digest a publication record must carry for this immutable package:
# sha256 over Move.toml and every sources/*.move, each preceded by its path.
set -euo pipefail

package_dir="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  else
    shasum -a 256 | cut -d' ' -f1
  fi
}

digest="$(
  cd "$package_dir"
  {
    printf 'Move.toml\n'
    cat Move.toml
    find sources -type f -name '*.move' | LC_ALL=C sort | while IFS= read -r file; do
      printf '%s\n' "$file"
      cat "$file"
    done
  } | sha256
)"

printf 'sha256:%s\n' "$digest"
