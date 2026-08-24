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

mapfile -t move_files < <(find sources tests -type f -name '*.move' -print | sort)

duplicate_import_roots="$({
  for file in "${move_files[@]}"; do
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

if rg -n '^[[:space:]]*(assert!|abort\b|public struct\b)' sources/lib/errors.move; then
  echo 'errors.move must contain only diagnostic constants and zero-cost numeric macros.' >&2
  failures=$((failures + 1))
fi

if rg -n '\b(Coin|Balance|UID|TxContext|transfer::|event::|object::)\b' sources/curve.move \
  || rg -n '^(public|entry) fun ' sources/curve.move \
  || [[ "$(rg -c '^public\(package\) fun quote_(buy|sell)\(' sources/curve.move)" != 2 ]]; then
  echo 'curve.move must remain a pure package-only numeric quote module.' >&2
  failures=$((failures + 1))
fi

if [[ "$(rg -c '^[[:space:]]+quote_fee_bps: u64,' sources/curve.move)" != 2 ]] \
  || [[ "$(rg -c '^[[:space:]]+meme_fee_bps: u64,' sources/curve.move)" != 2 ]] \
  || rg -n 'trade_fee_bps|fee_asset|fee_mode' sources/curve.move; then
  echo 'Each curve quote must use independent quote/meme rates; zero rates encode fee-asset choice.' >&2
  failures=$((failures + 1))
fi

fees_production="$(sed '/^\/\/ === Test-Only Functions ===/,$d' sources/fees.move)"

if rg -n '\b(UID|key|transfer::|XClaim|ed25519|recipient|launch_id)\b' \
  <<<"$fees_production" \
  || rg -n 'fee_balance_overflow|std::u64::max_value|max_balance' <<<"$fees_production" \
  || [[ "$(rg -c '^[[:space:]]+(protocol|creator)_(meme|quote): Balance<' sources/fees.move)" != 4 ]] \
  || [[ "$(rg -c '^public\(package\) fun (new|accrue|claim_creator_fees|claim_protocol_fees)' sources/fees.move)" != 4 ]]; then
  echo 'fees.move must remain an embedded supply-conserved four-balance ledger with only its approved package seam.' >&2
  failures=$((failures + 1))
fi

if rg -n '^(public|entry) fun ' <<<"$fees_production" \
  || rg -n 'set_creator_fee_split|sui::event|events::' <<<"$fees_production" \
  || [[ "$(rg -c '^[[:space:]]+self: &mut FeeLedger<Meme, Quote>,' sources/fees.move)" != 3 ]] \
  || ! rg -q '^[[:space:]]+protocol_fee_share_bps: u64,' sources/fees.move \
  || ! rg -q '^[[:space:]]+_: &CreatorCap<Meme>,' sources/fees.move \
  || ! rg -q '^[[:space:]]+_: &AdminWitness,' sources/fees.move; then
  echo 'Fee state is package-only, uses the live protocol split, and is evented by its enclosing launch operation.' >&2
  failures=$((failures + 1))
fi

if ! rg -U -q 'macro public\(package\) fun max_launch_fee_bps\(\): u64 \{\s*1_000\s*\}' \
  sources/lib/constants.move \
  || rg -n 'protocol_trade_fee_share_bps' sources; then
  echo 'The fee-rate ceiling is constant, while the protocol share must not be hard-coded.' >&2
  failures=$((failures + 1))
fi

trade_fee_config_production="$(sed '/^\/\/ === Test-Only Functions ===/,$d' sources/trade_fee_config.move)"

if [[ ! -f sources/trade_fee_config.move ]] \
  || ! rg -U -q \
    'public struct TradeFeeConfig has key \{\s*id: UID,\s*protocol_fee_share_bps: u64,\s*\}' \
    sources/trade_fee_config.move \
  || rg -n '\b(AdminCap|ProtocolAuthority)\b' <<<"$trade_fee_config_production" \
  || rg -n '\bsequence\b' <<<"$trade_fee_config_production" \
  || [[ "$(rg -c '^[[:space:]]+_: &AdminWitness,' sources/trade_fee_config.move)" != 1 ]] \
  || [[ "$(rg -c '^public fun set_protocol_fee_share\(' sources/trade_fee_config.move)" != 1 ]] \
  || [[ "$(rg -c '^public\(package\) fun protocol_fee_share_bps\(' sources/trade_fee_config.move)" != 1 ]]; then
  echo 'trade_fee_config.move must own only the live bounded global share and its AdminWitness-gated setter.' >&2
  failures=$((failures + 1))
fi

if ! rg -q 'protocol_fee_share_bps <= constants::basis_points_denominator!()' \
  sources/trade_fee_config.move \
  || ! rg -q 'protocol_fee_share_bps != self.protocol_fee_share_bps' \
  sources/trade_fee_config.move \
  || ! rg -U -q 'protocol_fee_share_bps: 0,\s*\}' \
  sources/trade_fee_config.move; then
  echo 'Trade-fee configuration must start safely at zero and reject out-of-range or unchanged updates.' >&2
  failures=$((failures + 1))
fi

trade_fee_event_payloads="$(sed -n \
  -e '/^public struct TradeFeeConfigCreated/,/^}/p' \
  -e '/^public struct ProtocolFeeShareChanged/,/^}/p' \
  sources/lib/events.move)"

if rg -n '\bsequence\b' <<<"$trade_fee_event_payloads"; then
  echo 'Trade-fee config events rely on native Sui event order and must not duplicate a sequence.' >&2
  failures=$((failures + 1))
fi

if rg -n \
  '\b(acl::(add_admin|revoke_admin|destroy_admin_cap|begin_super_admin_transfer|cancel_super_admin_transfer|accept_super_admin_transfer|destroy_retired_super_admin_cap|sign_in|destroy_protocol_authority_for_testing|destroy_super_admin_cap_for_testing)|x_claim_config::(set_signer|revoke_signer|destroy_for_testing)|trade_fee_config::(set_protocol_fee_share|protocol_fee_share_bps|destroy_for_testing)|creator_authority::(claim_creator_cap|destroy_for_testing|destroy_cap_for_testing)|fees::(accrue|claim_creator_fees|claim_protocol_fees|destroy_for_testing))(<[^>]+>)?\(' \
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

creator_authority_production="$(sed '/^\/\/ === Test-Only Functions ===/,$d' sources/creator_authority.move)"

if rg -n '\bcreator_cap_claimed:[[:space:]]*bool|\bissue_creator_cap\b|\btransfer::' \
  <<<"$creator_authority_production" \
  || ! rg -U -q \
    '(?s)public\(package\) fun claim_creator_cap<Meme>\(\s*authority: CreatorAuthority<Meme>,.*\): \(CreatorCap<Meme>, MetadataCap<Meme>\) \{' \
    sources/creator_authority.move \
  || ! rg -U -q \
    'public struct CreatorCap<phantom Meme> has key, store \{\s*id: UID,\s*\}' \
    sources/creator_authority.move \
  || ! rg -q '^[[:space:]]+metadata_cap: MetadataCap<Meme>,' \
    sources/creator_authority.move; then
  echo 'Creator claims must consume CreatorAuthority and return separate CreatorCap and MetadataCap objects without a flag, wrapper, or transfer.' >&2
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
