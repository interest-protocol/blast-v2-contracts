// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Positional Blake2b-256 proofs: leaf binding, node domains, proof depth, and the SDK vector.
module blast_fun_migrators::merkle_tests;

// === Tests ===

#[test]
fun single_leaf_verifies_only_its_exact_beneficiary_and_amounts() {
    let vault = object::id_from_address(@0xD);
    let alice_leaf = merkle::leaf(vault, 0, 0, @0xA, 10, 20);
    assert_eq!(alice_leaf.length(), 32);
    assert!(merkle::verify(alice_leaf, alice_leaf, 0, 1, &vector[]));
    assert!(!merkle::verify(alice_leaf, merkle::leaf(vault, 0, 0, @0xB, 10, 20), 0, 1, &vector[]));
    assert!(!merkle::verify(alice_leaf, merkle::leaf(vault, 1, 0, @0xA, 10, 20), 0, 1, &vector[]));
}

#[test]
fun two_leaves_use_positional_proofs() {
    let vault = object::id_from_address(@0xD);
    let alice_leaf = merkle::leaf(vault, 0, 0, @0xA, 10, 20);
    let bob_leaf = merkle::leaf(vault, 0, 1, @0xB, 30, 40);
    let root = merkle::node_for_testing(alice_leaf, bob_leaf);
    assert!(merkle::verify(root, alice_leaf, 0, 2, &vector[bob_leaf]));
    assert!(merkle::verify(root, bob_leaf, 1, 2, &vector[alice_leaf]));
    assert!(!merkle::verify(root, bob_leaf, 0, 2, &vector[alice_leaf]));
}

#[test]
fun sdk_three_holder_vector_matches_move_hashes_and_odd_leaf_proof() {
    let vault = object::id_from_address(@0xD);
    let alice_leaf = merkle::leaf(vault, 0, 0, @0xA, 10, 20);
    assert_eq!(alice_leaf, x"18ba1db53bc0da39eb6f1f00df49fa5be0932e85ca8f8257f4d278edea7f1aa8");
    let root = x"93f46ab27a1d3a5def3379afd0a3b02cc149d6fa03b7105b2697deba8c12cb2d";
    assert!(
        merkle::verify(
            root,
            alice_leaf,
            0,
            3,
            &vector[
                x"f0290d0717f5ac2c221a66e27d80e3c76a9ea2774a7dc7399cc5d108633526f1",
                x"4fd4325f78a40a6972b998c35cf40ec26237d6ff9e5dc2934fb882b9aa18e08a",
            ],
        ),
    );
    // The odd third leaf is promoted: it is its own sibling at the first level.
    let carol_leaf = merkle::leaf(vault, 0, 2, @0xC, 50, 60);
    assert!(
        merkle::verify(
            root,
            carol_leaf,
            2,
            3,
            &vector[
                carol_leaf,
                x"ca047224c2edac2b2dcd7f28d0a6d6c7175a2f10beef5f440b0597d0e1c7a7f5",
            ],
        ),
    );
}

#[test]
fun proofs_of_the_wrong_depth_or_sibling_length_are_rejected() {
    let alice_leaf = merkle::leaf(object::id_from_address(@0xD), 0, 0, @0xA, 1, 0);
    assert!(!merkle::verify(alice_leaf, alice_leaf, 0, 2, &vector[]));
    assert!(!merkle::verify(alice_leaf, alice_leaf, 0, 2, &vector[vector[1u8]]));
    assert!(!merkle::verify(alice_leaf, alice_leaf, 0, 1, &vector[alice_leaf]));
}

#[test]
fun every_leaf_field_is_bound_to_the_commitment() {
    let vault = object::id_from_address(@0xD);
    let root = merkle::leaf(vault, 0, 0, @0xA, 10, 20);
    let altered = vector[
        merkle::leaf(object::id_from_address(@0xE), 0, 0, @0xA, 10, 20),
        merkle::leaf(vault, 1, 0, @0xA, 10, 20),
        merkle::leaf(vault, 0, 1, @0xA, 10, 20),
        merkle::leaf(vault, 0, 0, @0xB, 10, 20),
        merkle::leaf(vault, 0, 0, @0xA, 11, 20),
        merkle::leaf(vault, 0, 0, @0xA, 10, 21),
    ];
    altered.do!(|altered_leaf| assert!(!merkle::verify(root, altered_leaf, 0, 1, &vector[])));
}

// === Imports ===

use blast_fun_migrators::merkle;

use std::unit_test::assert_eq;
