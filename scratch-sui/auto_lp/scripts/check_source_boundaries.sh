#!/usr/bin/env bash
# Mechanical boundary gate for the auto-LP vault.
#
# AutoLP has no administration of its own. It is published immutably, holds
# permanent creator-cap and LP-position custody with no withdrawal path, and
# accepts external package generations only as explicit inputs.
set -euo pipefail

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sources="$package_dir/sources"
vault_file="$sources/vault.move"

fail() { printf 'AutoLP source boundary failed: %s\n' "$1" >&2; exit 1; }

# --- Immutable publication is enforced structurally, never executed here ---

publication_script="$package_dir/scripts/publish_immutable.sh"
[[ -f "$publication_script" ]] \
  || fail "AutoLP must include its atomic immutable-publication script"
grep -q -- '--publish "$package_dir"' "$publication_script" \
  && grep -q -- '--assign auto_lp_upgrade_cap' "$publication_script" \
  && grep -q -- '--move-call 0x2::package::make_immutable auto_lp_upgrade_cap' \
    "$publication_script" \
  || fail "publication must atomically consume the returned UpgradeCap"
if grep -qE -- 'transfer-objects|public_transfer|transfer::' "$publication_script"; then
  fail "publication must never transfer the UpgradeCap"
fi

# --- No local administration of any kind ---

for forbidden in acl.move package_admin.move package_version.move package_marker.move; do
  [[ -e "$sources/$forbidden" ]] && fail "AutoLP must not define a local $forbidden"
done

if rg -n '^public struct (Control|Authority|ProtocolAuthority|SuperAdminCap|AdminCap|AdminWitness|OperationalVersion|UpgradeCustody)\b' \
  "$sources"; then
  fail "AutoLP must own no administration or custody type"
fi
if rg -n --glob '*.move' '^\s*(///|//)' --invert-match "$sources" \
  | rg -n 'AdminWitness|SuperAdminCap|UpgradeCap|Publisher|acl::'; then
  fail "no AutoLP operation may accept an administration capability"
fi
if rg -n '^public fun activate|VersionActivated|^const PACKAGE_VERSION' "$sources"; then
  fail "AutoLP must own no operational generation, activation, or cutover event"
fi
if rg -n '^fun init\(' "$sources"; then
  fail "AutoLP publishes no singleton and needs no initializer"
fi

# --- External generations remain explicit inputs, checked by their owners ---

rg -Fq 'version: &PackageVersion,' "$vault_file" \
  || fail "curve collection must take the Launchpad generation"
rg -Fq 'migrators_version: &MigratorsVersion,' "$vault_file" \
  || fail "external LP collection must take the Migrators generation"
factory_guards="$(rg -c '^    factory\.assert_current\(\);' "$vault_file" || true)"
[[ "${factory_guards:-0}" -eq 3 ]] \
  || fail "enrollment, own-fee collection, and compounding must each check the DEX generation"

# --- Permanent custody and fixed-executor policy ---

rg -Fq 'assert!(executor != @0x0, EInvalidExecutor);' "$vault_file" \
  || fail "enrollment must reject an unusable zero executor"
rg -Fq 'assert!(ctx.sender() == self.executor, EUnauthorizedExecutor);' "$vault_file" \
  || fail "only the fixed executor may time a deposit"
rg -Fq 'assert!(clock.timestamp_ms() <= deadline_ms, EDeadlineExpired);' "$vault_file" \
  || fail "compounding must honor the executor deadline"
rg -Fq 'assert!(meme_used <= max_meme && quote_used <= max_quote, EMaximumInput);' \
  "$vault_file" \
  || fail "compounding must honor the executor maximum input"
if rg -U -n '^public fun [^(]+\([^)]*\): (CreatorCap|Position)<' "$vault_file"; then
  fail "no path may release the sealed creator cap or LP position"
fi
if rg -n 'withdraw_all\(\)' "$vault_file" | rg -v 'into_coin\(ctx\)'; then
  fail "pending balances may leave custody only into the enrolled pool deposit"
fi

# --- Collection stays permissionless ---

for permissionless in collect_curve collect_external_lp collect_native_lp \
  collect_own_lp contribute; do
  block="$(sed -n "/^public fun $permissionless</,/^}/p" "$vault_file")"
  [[ -n "$block" ]] || fail "the permissionless entry point $permissionless is missing"
  if rg -q 'ctx\.sender\(\)|executor' <<<"$block"; then
    fail "$permissionless must remain permissionless"
  fi
done

printf 'AutoLP source boundaries passed\n'
