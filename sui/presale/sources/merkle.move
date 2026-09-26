// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Positional Blake2b-256 whitelist proofs with distinct leaf and internal-node domains.
module blast_presale::merkle;

// === Package Functions ===

/// A whitelist leaf: position `index` allows `account` to commit up to `max_quote`, zero for no
/// limit.
public(package) fun leaf(index: u64, account: address, max_quote: u64): vector<u8> {
    let mut bytes = b"\x00blast-presale-whitelist-v1";
    bytes.append(bcs::to_bytes(&index));
    bytes.append(bcs::to_bytes(&account));
    bytes.append(bcs::to_bytes(&max_quote));
    hash::blake2b256(&bytes)
}

/// Rejects wrong-depth proofs and malformed siblings before hashing; the caller bounds the index.
public(package) fun verify(
    root: vector<u8>,
    mut digest: vector<u8>,
    mut index: u64,
    leaves: u64,
    proof: &vector<vector<u8>>,
): bool {
    let mut width = leaves;
    let mut depth = 0;
    while (width > 1) {
        width = width.div_ceil(2);
        depth = depth + 1;
    };
    if (
        proof.length() != depth
            || !proof.all!(|sibling| sibling.length() == constants::digest_length!())
    ) return false;
    proof.do_ref!(|sibling| {
        digest = if (index % 2 == 0) node(digest, *sibling) else node(*sibling, digest);
        index = index / 2;
    });
    digest == root
}

// === Private Functions ===

fun node(left: vector<u8>, right: vector<u8>): vector<u8> {
    let mut bytes = vector[1u8];
    bytes.append(left);
    bytes.append(right);
    hash::blake2b256(&bytes)
}

// === Test-Only Functions ===

#[test_only]
public fun node_for_testing(left: vector<u8>, right: vector<u8>): vector<u8> {
    node(left, right)
}

// === Imports ===

use blast_presale::constants;

use std::bcs;

use sui::hash;
