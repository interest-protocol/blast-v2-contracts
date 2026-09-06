#!/usr/bin/env bash
# Mechanical boundary gate for the Blast SUI package.
set -euo pipefail

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf '%s\n' "$1" >&2; exit 1; }

# 1. The manifest declares exactly two dependencies: the immutable shared
#    administration package and the pinned SuiSystem framework.
pinned_rev="06734f6ff0af45d8632a14a4dc4b100197f6b1a2"
deps="$(sed -n '/^\[dependencies\]/,/^\[/p' "$package_dir/Move.toml" | grep -E '^[A-Za-z]' || true)"
[ "$(wc -l <<<"$deps")" -eq 2 ] || fail "Move.toml must declare exactly two dependencies."
grep -q '^SuiSystem = ' <<<"$deps" || fail "Move.toml must depend on SuiSystem."
grep -Fq 'blast_admin = { local = "../admin" }' <<<"$deps" \
  || fail "Move.toml must depend on the immutable shared administration package."
grep -q "rev = \"$pinned_rev\"" "$package_dir/Move.toml" || fail "SuiSystem must stay pinned to $pinned_rev."

# 2. This package must not reference the launchpad package.
if grep -rn "blast_fun" "$package_dir/sources" "$package_dir/tests"; then
  fail "blast_sui must not reference blast_fun."
fi

# 3. Administration is implemented only by blast_admin.
if [ -e "$package_dir/sources/acl.move" ]; then
  fail "blast_sui must not define a local ACL implementation."
fi
if rg -n '^public struct (Authority|ProtocolAuthority|SuperAdminCap|AdminCap|AdminWitness)\b' \
  "$package_dir/sources"; then
  fail "Administration types must come from blast_admin, never from a local copy."
fi
if [ "$(rg -c 'acl::new\(' "$package_dir/sources" | wc -l)" -ne 1 ]; then
  fail "Exactly one module may create this package's administration domain."
fi
rg -q 'public struct BLAST_SUI_DOMAIN has drop \{\}' \
  "$package_dir/sources/blast_sui_domain.move" \
  || fail "blast_sui must own one typed domain one-time witness."
rg -q '^const PACKAGE_ADMIN_ROLE: u64 = 1;$' \
  "$package_dir/sources/blast_sui_domain.move" \
  || fail "blast_sui must export exactly one package-admin role bit."

# 4. Its generation container and custody hold the shared typed values, and no
#    separate activation or capability escape survives.
rg -q 'generation: OperationalVersion<BLAST>,' "$package_dir/sources/package_version.move" \
  || fail "The generation value must be the shared typed value."
rg -q '^const NEXT_PACKAGE_VERSION: u64 = 2;$' "$package_dir/sources/package_version.move" \
  || fail "blast_sui must compile its cutover target constant."
if rg -n '\.checked_add\(|fun activate\(' "$package_dir/sources/package_version.move"; then
  fail "Generation arithmetic and separate activation belong to blast_admin."
fi
rg -q 'custody: UpgradeCustody<BLAST>,' "$package_dir/sources/package_admin.move" \
  || fail "Package custody must hold the shared typed value."
rg -q 'public fun commit_upgrade_and_advance\(' "$package_dir/sources/package_admin.move" \
  || fail "blast_sui must expose one atomic commit-and-advance finalizer."
if rg -n '^public fun commit_upgrade\(|^public fun activate' \
  "$package_dir/sources/package_admin.move"; then
  fail "A separate receipt commit or activation entry point is forbidden."
fi
# Production only: a test-only helper that mints a fresh foreign Publisher does
# not release the sealed one.
package_admin_production="$(sed '/^\/\/ === Test-Only Types ===/,$d' \
  "$package_dir/sources/package_admin.move")"
if rg -U -n '^public fun [^(]+\([^)]*\): (&)?(Publisher|UpgradeCap)' \
  <<<"$package_admin_production"; then
  fail "No custody path may release the sealed Publisher or UpgradeCap."
fi
if rg -n 'transfer::(public_)?transfer\(' <<<"$package_admin_production"; then
  fail "The framework UpgradeCap must never leave sealed custody."
fi
custody_role_assertions="$(rg -c \
  'admin_witness\.assert_role\(blast_sui_domain::package_admin_role\(\)\);' \
  "$package_dir/sources/package_admin.move" || true)"
[ "${custody_role_assertions:-0}" -eq 4 ] \
  || fail "Every governed custody transition must assert the exported role."

# 5. Sharing still requires all three package-specific child capabilities.
share_body="$(sed -n '/^public fun share(self: PackageAdmin) {/,/^}/p' \
  "$package_dir/sources/package_admin.move")"
for required in 'MetadataCap<FUN_SUI>' 'MetadataCap<BLAST_SUI>' \
  'DisplayCap<BlastSuiDepositReceipt>'; do
  grep -Fq "$required" <<<"$share_body" \
    || fail "share must require the $required child capability."
done
[ "$(grep -c 'missing_package_capability' <<<"$share_body")" -eq 3 ] \
  || fail "share must reject on each of the three missing child capabilities."

# 3. Every event goes through the events_wrapper envelope.
if grep -rn "sui::event::emit" "$package_dir/sources" | grep -v "sources/lib/events_wrapper.move"; then
  fail "Only events_wrapper may call sui::event::emit."
fi

# 4. Functions with a natural first receiver use Move 2024 method syntax.
if rg -n 'dynamic_object_field::(add|borrow|borrow_mut|exists_with_type)\(' \
  "$package_dir/sources"; then
  fail "Dynamic-object-field operations must use semantic UID receiver aliases."
fi

if rg -n 'package::test_upgrade\(|test_scenario::return_to_sender\(|\.has_blast_coin\(' \
  "$package_dir/tests"; then
  fail "Test helpers with a natural first receiver must use Move 2024 dot syntax."
fi

if rg -n 'let[[:space:]]+[[:alnum:]_]+:[[:space:]]+&(mut[[:space:]]+)?Capability' \
  "$package_dir/sources"; then
  fail "Local reference types must be inferred from explicit generic arguments."
fi

printf 'Source boundaries hold.\n'
