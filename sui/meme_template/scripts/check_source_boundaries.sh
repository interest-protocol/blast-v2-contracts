#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

source_file='sources/meme.move'

if [[ "$(rg -c '^public struct MEME\(\) has drop;$' "$source_file")" != 1 ]] \
  || [[ "$(rg -c '^fun init\(otw: MEME, ctx: &mut TxContext\) \{$' "$source_file")" != 1 ]] \
  || [[ "$(rg -c 'creator_authority::new_address\(address::from_bytes\(CREATOR_IDENTITY_BYTES\)\)' "$source_file")" != 1 ]] \
  || [[ "$(rg -c 'creator_authority::new_x\(CREATOR_IDENTITY_BYTES\)' "$source_file")" != 1 ]] \
  || [[ "$(rg -c 'launch_ticket::new\(' "$source_file")" != 1 ]] \
  || [[ "$(rg -c 'transfer::public_transfer\(ticket, ctx.sender\(\)\);' "$source_file")" != 1 ]]; then
  echo 'The template must select one creator identity and transfer one Blast ticket to the publisher.' >&2
  exit 1
fi

for constant in SYMBOL NAME DESCRIPTION ICON_URL BURNABLE SELL_BURN_BPS; do
  if [[ "$(rg -c "^const ${constant}:" "$source_file")" != 1 ]] \
    || [[ "$(rg -c "        ${constant}(\\.to_string\\(\\))?," "$source_file")" != 1 ]]; then
    echo "The template must declare and pass one ${constant} replacement slot." >&2
    exit 1
  fi
done

if [[ "$(rg -c '^const CREATOR_IDENTITY_BYTES: vector<u8> = x"[0-9a-f]{64}";$' "$source_file")" != 1 ]] \
  || [[ "$(rg -c '^const CREATOR_IS_X: bool = (true|false);$' "$source_file")" != 1 ]] \
  || [[ "$(rg -c 'if \(CREATOR_IS_X\)' "$source_file")" != 1 ]]; then
  echo 'The template must declare its 32-byte creator identity and identity-kind replacement slots.' >&2
  exit 1
fi

if rg -n '\b(TreasuryCap|MetadataCap|coin_registry|mint|make_supply_[a-z_]*|finalize)\b|^(public|entry|public entry) fun ' \
  "$source_file"; then
  echo 'Currency creation, supply authority, and public setup functions must remain inside Blast.' >&2
  exit 1
fi
