#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

source_file='sources/my_coin.move'
production="$(sed '/^\/\/ === Test-Only Functions ===/,$d' "$source_file")"
# Whitespace-free source, so argument checks do not depend on formatting.
compact="$(tr -d '[:space:]' <<<"$production")"

if [[ "$(rg -cF 'public struct MY_COIN has drop {}' "$source_file")" != 1 ]] \
  || [[ "$(rg -c '^fun init\(otw: MY_COIN, ctx: &mut TxContext\) \{' "$source_file")" != 1 ]] \
  || rg -n '^(public|entry|public\(package\)) fun ' <<<"$production" \
  || rg -n '\b(blast_fun|UpgradeCap|make_immutable|make_regulated|new_currency\b|share_object|freeze_object)\b' <<<"$production" \
  || [[ "$(rg -oF 'coin_registry::new_currency_with_otw(otw,' <<<"$compact" | wc -l)" != 1 ]]; then
  echo 'The template must expose only its one-time-witness initializer, which creates one unregulated Sui currency with no Blast dependency.' >&2
  exit 1
fi

# Every slot is loaded once, in init, so the SDK can patch it by its unique constant-pool value.
for constant in SYMBOL NAME DESCRIPTION ICON_URL DECIMALS INITIAL_SUPPLY SUPPLY_RECIPIENT \
  SUPPLY_MODE TREASURY_CAP_RECIPIENT METADATA_MUTABLE METADATA_CAP_RECIPIENT; do
  if [[ "$(rg -c "^const ${constant}:" "$source_file")" != 1 ]] \
    || [[ "$(rg -o "[(,]${constant}(\\.to_string\\(\\))?," <<<"$compact" | wc -l)" != 1 ]]; then
    echo "The template must declare and pass one ${constant} replacement slot." >&2
    exit 1
  fi
done

if [[ "$(rg -c '^const (SUPPLY_RECIPIENT|TREASURY_CAP_RECIPIENT|METADATA_CAP_RECIPIENT): address = @0x[0-9a-f]+;$' "$source_file")" != 3 ]] \
  || [[ "$(rg -o '^const (SUPPLY_RECIPIENT|TREASURY_CAP_RECIPIENT|METADATA_CAP_RECIPIENT): address = (@0x[0-9a-f]+);$' -r '$2' "$source_file" | sort -u | wc -l)" != 3 ]]; then
  echo 'The three recipient slots must hold distinct default addresses.' >&2
  exit 1
fi

if [[ "$(rg -c '^const SUPPLY_MODE: u8 = [0-2];$' "$source_file")" != 1 ]] \
  || [[ "$(rg -o '^const (DECIMALS|SUPPLY_MODE): u8 = ([0-9]+);$' -r '$2' "$source_file" | sort -u | wc -l)" != 2 ]]; then
  echo 'SUPPLY_MODE must default to a valid mode distinct from DECIMALS.' >&2
  exit 1
fi

if [[ "$(rg -c '^const [A-Z_]+: u8 = ' "$source_file")" != 2 ]] \
  || [[ "$(rg -c '^const [A-Z_]+: bool = ' "$source_file")" != 1 ]] \
  || [[ "$(rg -c '^const [A-Z_]+: u64 = ' "$source_file")" != 1 ]]; then
  echo 'No other u8, bool, or u64 constant may share a pool type with a replacement slot.' >&2
  exit 1
fi

echo 'coin_template source boundaries: OK'
