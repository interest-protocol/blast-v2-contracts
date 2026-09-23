#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

source_file='sources/meme.move'
production="$(sed '/^\/\/ === Test-Only Functions ===/,$d' "$source_file")"
# Whitespace-free source, so argument checks do not depend on formatting.
compact="$(tr -d '[:space:]' <"$source_file")"

if [[ "$(rg -cF 'public struct MEME has drop {}' "$source_file")" != 1 ]] \
  || [[ "$(rg -c '^fun init\(otw: MEME, ctx: &mut TxContext\) \{' "$source_file")" != 1 ]] \
  || rg -n '^(public|entry|public\(package\)) fun ' <<<"$production" \
  || [[ "$(rg -c 'launch_ticket::new\(' "$source_file")" != 1 ]] \
  || [[ "$(rg -oF 'launch_ticket::new(otw,' <<<"$compact" | wc -l)" != 1 ]] \
  || [[ "$(rg -cF 'transfer::public_transfer(ticket, ctx.sender());' "$source_file")" != 1 ]] \
  || [[ "$(rg -c 'creator_authority::new_address\(address::from_bytes\(CREATOR_RECIPIENT_BYTES\)\)' "$source_file")" != 1 ]] \
  || [[ "$(rg -c 'creator_authority::new_account\(CREATOR_RECIPIENT_BYTES\)' "$source_file")" != 1 ]] \
  || rg -n '\b(UpgradeCap|CoinRegistry|LaunchConfig|PackageVersion|make_immutable|new_currency)\b' "$source_file"; then
  echo 'The template must expose only its one-time-witness initializer, which builds the ticket through Blast and delivers it to the publisher.' >&2
  exit 1
fi

for constant in SYMBOL NAME DESCRIPTION ICON_URL DECIMALS BURNABLE SELL_BURN_BPS; do
  if [[ "$(rg -c "^const ${constant}:" "$source_file")" != 1 ]] \
    || [[ "$(rg -o "[(,]${constant}(\\.to_string\\(\\))?," <<<"$compact" | wc -l)" != 1 ]]; then
    echo "The template must declare and pass one ${constant} replacement slot." >&2
    exit 1
  fi
done

if [[ "$(rg -c '^const CREATOR_RECIPIENT_BYTES: vector<u8> = x"[0-9a-f]{64}";$' "$source_file")" != 1 ]] \
  || [[ "$(rg -c '^const CREATOR_IS_ACCOUNT: bool = (true|false);$' "$source_file")" != 1 ]] \
  || [[ "$(rg -c 'if \(CREATOR_IS_ACCOUNT\)' "$source_file")" != 1 ]]; then
  echo 'The template must declare its 32-byte creator recipient and recipient-kind replacement slots.' >&2
  exit 1
fi

if rg -n '\b(TreasuryCap|MetadataCap|mint|make_supply_[a-z_]*|finalize)\b' "$source_file"; then
  echo 'Currency creation, supply finalization, and metadata authority must remain inside Blast.' >&2
  exit 1
fi

echo 'meme_template source boundaries: OK'
