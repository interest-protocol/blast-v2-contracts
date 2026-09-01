#!/usr/bin/env bash
set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$PACKAGE_DIR/Move.toml"
LOCKFILE="$PACKAGE_DIR/Move.lock"
FULLSAIL_MANIFEST="$PACKAGE_DIR/interfaces/fullsail/Move.toml"
INTEGER_MANIFEST="$PACKAGE_DIR/interfaces/fullsail_integer_mate/Move.toml"
EXPECTED_SUI_REV="06734f6ff0af45d8632a14a4dc4b100197f6b1a2"
EXPECTED_FULLSAIL_ORIGINAL="0xe74104c66dd9f16b3096db2cc00300e556aa92edc871be4bc052b5dfb80db239"
EXPECTED_FULLSAIL_CURRENT="0x497a144ba3d93ae44d9fd23d4ff4761c329d87a505136d2269c743b2297fa881"
EXPECTED_INTEGER_ID="0x6b904ae739b2baad330aae14991abcd3b7354d3dc3db72507ed8dabeeb7a36de"

fail() {
    echo "Full Sail dependency pin check failed: $1" >&2
    exit 1
}

require_pattern() {
    local source="$1"
    local pattern="$2"
    local description="$3"

    [[ -f "$source" ]] || fail "missing $source"
    rg -q -F "$pattern" "$source" || fail "missing $description"
}

lock_section() {
    local environment="$1"
    local package="$2"
    local header="[pinned.${environment}.${package}]"

    awk -v header="$header" '
        $0 == header { active = 1; next }
        active && /^\[/ { exit }
        active { print }
    ' "$LOCKFILE"
}

dependency_target() {
    local section="$1"
    local dependency="$2"

    printf '%s\n' "$section" |
        rg -o "$dependency = \"[^\"]+\"" |
        cut -d '"' -f 2 || true
}

assert_environment() {
    local environment="$1"
    local fullsail_section fullsail_sui_package fullsail_sui_section
    local integer_section integer_sui_package integer_sui_section

    fullsail_section="$(lock_section "$environment" FullSailCLMM)"
    [[ "$fullsail_section" == *'source = { local = "interfaces/fullsail" }'* ]] || \
        fail "$environment FullSailCLMM must use the normalized local interface"
    [[ "$fullsail_section" == *'FullSailIntegerMate = "FullSailIntegerMate"'* ]] || \
        fail "$environment FullSailCLMM must bind FullSailIntegerMate"

    fullsail_sui_package="$(dependency_target "$fullsail_section" Sui)"
    [[ -n "$fullsail_sui_package" ]] || fail "$environment FullSailCLMM must bind Sui"
    fullsail_sui_section="$(lock_section "$environment" "$fullsail_sui_package")"
    [[ "$fullsail_sui_section" == *"rev = \"$EXPECTED_SUI_REV\""* ]] || \
        fail "$environment FullSailCLMM does not bind the required Sui revision"

    integer_section="$(lock_section "$environment" FullSailIntegerMate)"
    [[ "$integer_section" == *'source = { local = "interfaces/fullsail_integer_mate" }'* ]] || \
        fail "$environment FullSailIntegerMate must use its normalized local interface"

    integer_sui_package="$(dependency_target "$integer_section" Sui)"
    [[ -n "$integer_sui_package" ]] || \
        fail "$environment FullSailIntegerMate must bind Sui"
    integer_sui_section="$(lock_section "$environment" "$integer_sui_package")"
    [[ "$integer_sui_section" == *"rev = \"$EXPECTED_SUI_REV\""* ]] || \
        fail "$environment FullSailIntegerMate does not bind the required Sui revision"
}

require_pattern "$MANIFEST" 'FullSailCLMM = { local = "interfaces/fullsail" }' \
    'normalized Full Sail dependency'
require_pattern "$MANIFEST" \
    'FullSailIntegerMate = { local = "interfaces/fullsail_integer_mate" }' \
    'normalized Full Sail IntegerMate dependency'
require_pattern "$FULLSAIL_MANIFEST" "published-at = \"$EXPECTED_FULLSAIL_CURRENT\"" \
    'Full Sail current package ID'
require_pattern "$FULLSAIL_MANIFEST" "clmm_pool = \"$EXPECTED_FULLSAIL_ORIGINAL\"" \
    'Full Sail original package ID'
require_pattern "$FULLSAIL_MANIFEST" 'FullSailIntegerMate = { local = "../fullsail_integer_mate" }' \
    'Full Sail local IntegerMate dependency'
require_pattern "$FULLSAIL_MANIFEST" "rev = \"$EXPECTED_SUI_REV\"" \
    'exact Full Sail Sui pin'
require_pattern "$INTEGER_MANIFEST" "published-at = \"$EXPECTED_INTEGER_ID\"" \
    'Full Sail IntegerMate package ID'
require_pattern "$INTEGER_MANIFEST" "fullsail_integer_mate = \"$EXPECTED_INTEGER_ID\"" \
    'Full Sail IntegerMate original package ID'
require_pattern "$INTEGER_MANIFEST" "rev = \"$EXPECTED_SUI_REV\"" \
    'exact Full Sail IntegerMate Sui pin'

assert_environment mainnet
assert_environment testnet

echo "Full Sail dependency pin passed"
