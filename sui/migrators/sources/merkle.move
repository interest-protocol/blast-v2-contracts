// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Positional Blake2b-256 proofs with distinct leaf and internal-node domains.
module blast_fun_migrators::merkle;

// === Package Functions ===

/// The unique vault ID and monotonically increasing round separate claims.
public(package) fun leaf(
    vault: ID,
    round: u64,
    index: u64,
    beneficiary: address,
    meme: u64,
    quote: u64,
): vector<u8> {
    let mut bytes = b"\x00blast-holder-rewards-v1";
    bytes.append(bcs::to_bytes(&vault));
    bytes.append(bcs::to_bytes(&round));
    bytes.append(bcs::to_bytes(&index));
    bytes.append(bcs::to_bytes(&beneficiary));
    bytes.append(bcs::to_bytes(&meme));
    bytes.append(bcs::to_bytes(&quote));
    hash::blake2b256(&bytes)
}

/// Rejects malformed, wrong-depth and out-of-range proofs before hashing.
public(package) fun verify(
    root: vector<u8>,
    mut digest: vector<u8>,
    mut index: u64,
    leaves: u64,
    proof: &vector<vector<u8>>,
): bool {
    if (
        leaves == 0 || leaves > constants::max_reward_leaves!() || index >= leaves
            || root.length() != constants::digest_length!()
            || digest.length() != constants::digest_length!()
    ) return false;
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
public fun node_for_testing(left: vector<u8>, right: vector<u8>): vector<u8> { node(left, right) }

// === Imports ===

use blast_fun_migrators::constants;

use std::bcs;

use sui::hash;
