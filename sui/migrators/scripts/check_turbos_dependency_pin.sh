#!/usr/bin/env bash
set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$PACKAGE_DIR/Move.toml"
LOCKFILE="$PACKAGE_DIR/Move.lock"
INTERFACE_MANIFEST="$PACKAGE_DIR/interfaces/turbos/Move.toml"
EXPECTED_SUI_REV="06734f6ff0af45d8632a14a4dc4b100197f6b1a2"
EXPECTED_ORIGINAL_ID="0x91bfbc386a41afcfd9b2533058d7e915a1d3829089cc268ff4333d54d6339ca1"
EXPECTED_LATEST_ID="0xa5a0c25c79e428eba04fb98b3fb2a34db45ab26d4c8faf0d7e39d66a63891e64"

fail() {
    echo "Turbos dependency pin check failed: $1" >&2
    exit 1
}

require_pattern() {
    local source="$1"
    local pattern="$2"
    local description="$3"

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
    local turbos_section sui_package sui_section

    turbos_section="$(lock_section "$environment" TurbosCLMM)"
    [[ "$turbos_section" == *'source = { local = "interfaces/turbos" }'* ]] || \
        fail "$environment TurbosCLMM must use the normalized local interface"

    sui_package="$(dependency_target "$turbos_section" Sui)"
    [[ -n "$sui_package" ]] || fail "$environment TurbosCLMM must bind Sui"

    sui_section="$(lock_section "$environment" "$sui_package")"
    [[ "$sui_section" == *"rev = \"$EXPECTED_SUI_REV\""* ]] || \
        fail "$environment TurbosCLMM does not bind the required Sui revision"
}

require_pattern "$MANIFEST" 'TurbosCLMM = { local = "interfaces/turbos" }' \
    'normalized Turbos dependency'
require_pattern "$INTERFACE_MANIFEST" "published-at = \"$EXPECTED_LATEST_ID\"" \
    'Turbos latest package ID'
require_pattern "$INTERFACE_MANIFEST" "turbos_clmm = \"$EXPECTED_ORIGINAL_ID\"" \
    'Turbos original package ID'
require_pattern "$INTERFACE_MANIFEST" "rev = \"$EXPECTED_SUI_REV\"" \
    'exact Turbos Sui pin'
if rg -q -F 'rev = "testnet"' "$INTERFACE_MANIFEST"; then
    fail "normalized Turbos interface must not use mutable testnet Sui"
fi

assert_environment mainnet
assert_environment testnet

echo "Turbos dependency pin passed"
