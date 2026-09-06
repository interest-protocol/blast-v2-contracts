#!/usr/bin/env bash
# Mechanical boundary gate for the holder-rewards distributor.
#
# Distributor reuses the Launchpad administration domain for membership and owns
# its own operational generation, pause policy, and sealed framework custody.
set -euo pipefail

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sources="$package_dir/sources"
tests="$package_dir/tests"

fail() { printf 'Distributor source boundary failed: %s\n' "$1" >&2; exit 1; }

# --- Manifest: the inward administration edge, no venue dependency ---

grep -Fq 'blast_admin = { local = "../admin" }' "$package_dir/Move.toml" \
  || fail "the manifest must depend on the immutable shared administration package"
grep -Fq 'blast_fun = { local = "../launchpad" }' "$package_dir/Move.toml" \
  || fail "the manifest must keep its Launchpad product dependency"

# --- No local administration implementation ---

for forbidden in acl.move; do
  [[ -e "$sources/$forbidden" ]] && fail "Distributor must not define a local $forbidden"
done

if rg -n '^public struct (Authority|ProtocolAuthority|SuperAdminCap|AdminCap|AdminWitness)\b' \
  "$sources"; then
  fail "administration types must come from blast_admin, never from a local copy"
fi

if rg -n 'acl::new\(|fun (grant_admin|revoke_admin|sign_in)\(' "$sources"; then
  fail "Distributor must not create a second administration domain"
fi

# --- Its own package marker, generation container, and custody ---

for required in package_marker.move package_version.move package_admin.move; do
  [[ -f "$sources/$required" ]] || fail "Distributor must own $required"
done

rg -q 'generation: OperationalVersion<PACKAGE_MARKER>,' "$sources/package_version.move" \
  || fail "the generation value must be the shared typed value"
rg -q '^    paused: bool,$' "$sources/package_version.move" \
  || fail "the pause value must live beside the generation in one container"
rg -q '^const PACKAGE_VERSION: u64 = 1;$' "$sources/package_version.move" \
  || fail "Distributor must compile its current generation constant"
rg -q '^const NEXT_PACKAGE_VERSION: u64 = 2;$' "$sources/package_version.move" \
  || fail "Distributor must compile its cutover target constant"
if rg -n '\.checked_add\(|^public fun activate\(' "$sources/package_version.move"; then
  fail "generation arithmetic and separate activation belong to blast_admin"
fi

# --- Version check precedes pause check, always ---

rg -U -q \
  'public\(package\) fun assert_enabled\(self: &PackageVersion\) \{\s*self\.assert_current\(\);\s*assert!\(!self\.paused, EPaused\);\s*\}' \
  "$sources/package_version.move" \
  || fail "assert_enabled must check the generation before the pause"

rg -U -q \
  'public fun set_paused\(\s*self: &mut PackageVersion,\s*_: &AdminWitness<LAUNCHPAD_DOMAIN>,\s*paused: bool,\s*\) \{\s*self\.assert_current\(\);' \
  "$sources/package_version.move" \
  || fail "pause changes must take a generic Launchpad witness after the generation check"

# --- Every paused-blocked economic transition goes through assert_enabled ---
#
# Enrollment, both fee-collection paths, round publication, and funded claims.
enabled_guards="$(rg -c '^    rewards_version\.assert_enabled\(\);' \
  "$sources/distributor.move" || true)"
[[ "${enabled_guards:-0}" -eq 5 ]] \
  || fail "all five economic transitions must call assert_enabled (found ${enabled_guards:-0})"

for guarded in 'public fun new<' 'public fun collect_curve_fees<' \
  'public fun collect_lp_fees<' 'public fun publish_round<' 'public fun claim<'; do
  rg -q "$guarded" "$sources/distributor.move" \
    || fail "the paused-blocked entry point '$guarded' is missing"
done

# --- Sealed custody, atomic finalizer, no capability escape ---

rg -q 'custody: UpgradeCustody<PACKAGE_MARKER>,' "$sources/package_admin.move" \
  || fail "Distributor custody must hold the shared typed value"
rg -q 'public fun commit_upgrade_and_advance\(' "$sources/package_admin.move" \
  || fail "Distributor must expose one atomic commit-and-advance finalizer"
if rg -n '^public fun commit_upgrade\(|^public fun activate' "$sources/package_admin.move"; then
  fail "a separate receipt commit or activation entry point is forbidden"
fi
if rg -U -n '^public fun [^(]+\([^)]*\): (&)?(Publisher|UpgradeCap)' \
  "$sources/package_admin.move"; then
  fail "no custody path may release the sealed Publisher or UpgradeCap"
fi
if rg -n 'transfer::(public_)?transfer\(' "$sources/package_admin.move"; then
  fail "the framework UpgradeCap must never be address-owned"
fi
custody_role_assertions="$(rg -c \
  'admin_witness\.assert_role\(launchpad_domain::package_admin_role\(\)\);' \
  "$sources/package_admin.move" || true)"
[[ "${custody_role_assertions:-0}" -eq 5 ]] \
  || fail "every governed custody transition must assert Launchpad's exported role"

# --- The product PublisherCap stays separate from framework custody ---

rg -q '^public struct PublisherCap has key, store \{$' "$sources/distributor.move" \
  || fail "the product round-publication capability must remain transferable"
if rg -n '^[^/]*\bPublisherCap\b' "$sources/package_admin.move"; then
  fail "the product PublisherCap must never enter framework package custody"
fi

# --- Test discipline ---

if rg -n 'sui::event::emit' "$sources" | rg -v 'distributor\.move|package_version\.move'; then
  fail "only the product modules may emit distributor events"
fi

printf 'Distributor source boundaries passed\n'
