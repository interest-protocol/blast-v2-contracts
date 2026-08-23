#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

failures=0

if rg -n \
  '(^use std::(vector|option|internal)(::[^;]+)?;|^use std::\{[^;]*(vector|option|internal)|^use sui::(object|transfer|tx_context)(::[^;]+)?;|^use sui::\{[^;]*(object|transfer|tx_context))' \
  sources tests; then
  echo 'Move 2024 implicit prelude modules and types must not be imported explicitly.' >&2
  failures=$((failures + 1))
fi

duplicate_import_roots="$({
  for file in sources/*.move tests/*.move; do
    awk '
      /^use / {
        root = $2;
        sub(/::.*/, "", root);
        count[root] += 1;
      }
      END {
        for (root in count) {
          if (count[root] > 1) print FILENAME ":" root;
        }
      }
    ' "$file"
  done
} | sort)"

if [[ -n "$duplicate_import_roots" ]]; then
  printf '%s\n' "$duplicate_import_roots"
  echo 'Imports from one root address must use one nested declaration per module.' >&2
  failures=$((failures + 1))
fi

if rg -n '^use blast_fun::errors|^use std::unit_test::assert_eq|^use sui::event::emit' \
  sources tests; then
  echo 'Error/assertion macros and one-off event emission must remain fully qualified.' >&2
  failures=$((failures + 1))
fi

if rg -n \
  '\b(acl::(add_admin|revoke_admin|destroy_admin_cap|begin_super_admin_transfer|cancel_super_admin_transfer|accept_super_admin_transfer|destroy_retired_super_admin_cap|sign_in|destroy_protocol_authority_for_testing|destroy_super_admin_cap_for_testing)|x_claim_config::(set_signer|revoke_signer|destroy_for_testing)|creator_authority::(claim_creator_cap|destroy_for_testing|destroy_cap_for_testing))(<[^>]+>)?\(' \
  sources tests; then
  echo 'Blast-owned receiver functions must use Move 2024 dot syntax.' >&2
  failures=$((failures + 1))
fi

if rg -n '^[[:space:]]+assert_super_admin\(' sources/acl.move \
  || rg -n '\bsui::tx_context::TxContext\b' sources tests; then
  echo 'Natural framework and private receivers must use implicit types and dot syntax.' >&2
  failures=$((failures + 1))
fi

if rg -n \
  'XClaimConfig|ed25519|x_claim_signer|verify_x_claim|CreatorCap|issue_creator_cap' \
  sources/acl.move; then
  echo 'acl.move must own only protocol-admin membership and root rotation.' >&2
  failures=$((failures + 1))
fi

if ! rg -q '^public struct AdminWitness\(\) has drop;' sources/acl.move \
  || ! rg -q '^public fun sign_in\(' sources/acl.move; then
  echo 'acl.move must expose sign_in through an unforgeable drop-only AdminWitness.' >&2
  failures=$((failures + 1))
fi

if ! rg -q '^public fun destroy_admin_cap\(' sources/acl.move \
  || rg -n 'destroy_admin_cap_for_testing' sources tests; then
  echo 'AdminCap holders must use the production self-destruction path.' >&2
  failures=$((failures + 1))
fi

if rg -n '\b(AdminCap|ProtocolAuthority)\b' sources/x_claim_config.move \
  || [[ "$(rg -c '^[[:space:]]+_: &AdminWitness,' sources/x_claim_config.move)" != 2 ]]; then
  echo 'X signer admin functions must depend only on a borrowed AdminWitness.' >&2
  failures=$((failures + 1))
fi

if [[ ! -f sources/x_claim_config.move ]] \
  || ! rg -q '^public struct XClaimConfig has key' sources/x_claim_config.move; then
  echo 'x_claim_config.move must own the shared X signer configuration.' >&2
  failures=$((failures + 1))
fi

if ! rg -q '^public struct CreatorCap<phantom Meme> has key, store' \
  sources/creator_authority.move; then
  echo 'creator_authority.move must own CreatorCap<Meme> construction.' >&2
  failures=$((failures + 1))
fi

if rg -n '\bcreator_cap_claimed:[[:space:]]*bool|\bissue_creator_cap\b|\btransfer::' \
  sources/creator_authority.move \
  || ! rg -U -q \
    '(?s)public\(package\) fun claim_creator_cap<Meme>\(\s*authority: CreatorAuthority<Meme>,.*\): CreatorCap<Meme> \{' \
    sources/creator_authority.move; then
  echo 'Creator-cap claims must consume CreatorAuthority and return CreatorCap without a flag or transfer.' >&2
  failures=$((failures + 1))
fi

if rg -n 'schema_version|action_tag|nonce' sources/creator_authority.move; then
  echo 'The one-time X creator claim must not duplicate its fixed type and consumed marker.' >&2
  failures=$((failures + 1))
fi

if rg -l '^public struct XClaimConfig has key' sources \
  | rg -v '^sources/x_claim_config\.move$'; then
  echo 'XClaimConfig is declared outside its owning module.' >&2
  failures=$((failures + 1))
fi

if rg -l '^public struct CreatorCap<phantom Meme> has key, store' sources \
  | rg -v '^sources/creator_authority\.move$'; then
  echo 'CreatorCap<Meme> is declared outside its owning module.' >&2
  failures=$((failures + 1))
fi

if ((failures != 0)); then
  exit 1
fi

echo 'Source module boundaries and Move style: OK'
