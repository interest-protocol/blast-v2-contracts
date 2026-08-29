#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

source_file='sources/meme.move'

if [[ "$(rg -c '^public struct MEME\(\) has drop;$' "$source_file")" != 1 ]] \
  || [[ "$(rg -c '^fun init\(otw: MEME, ctx: &mut TxContext\) \{$' "$source_file")" != 1 ]] \
  || [[ "$(rg -c 'let launcher = ctx.sender\(\);' "$source_file")" != 1 ]] \
  || [[ "$(rg -c 'creator_authority::new_address\(launcher\)' "$source_file")" != 1 ]] \
  || [[ "$(rg -c 'launch_ticket::new\(' "$source_file")" != 1 ]] \
  || [[ "$(rg -c 'transfer::public_transfer\(ticket, launcher\);' "$source_file")" != 1 ]]; then
  echo 'The template must create one Blast ticket from one OTW and transfer it to the launcher.' >&2
  exit 1
fi

if rg -n '\b(TreasuryCap|MetadataCap|coin_registry|mint|make_supply_[a-z_]*|finalize)\b|^(public|entry|public entry) fun ' \
  "$source_file"; then
  echo 'Currency creation, supply authority, and public setup functions must remain inside Blast.' >&2
  exit 1
fi
