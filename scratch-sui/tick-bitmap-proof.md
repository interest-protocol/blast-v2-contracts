# Nearest initialized tick

For cursor `i`, upward lookup returns the least initialized index greater
than `i`. Downward lookup returns the greatest initialized index at most
`i`. Lookup returns an empty option exactly when the eligible set is empty.

## Reachability invariant

Write an index as `65,536 * group + 256 * slot + bit`, with `slot` and
`bit` in `[0, 255]`. The word key is `256 * group + slot`. At the
boundary of every successful curve operation:

- A leaf bit is set exactly when the tick table contains that index.
  Every such index is in `[0, 1,774,544]`.
- A group bit is set exactly when its leaf word is nonzero. The top-level
  bit is set exactly when its group word is nonzero. The two bitmap
  tables store only nonzero words. A missing key represents a zero word.
- The cursor is in `[0, 1,774,544]`.

The constructor creates three empty tables and a zero top-level bitmap.
The cursor search starts with the full legal interval. At each iteration
the ceiling midpoint lies strictly above the lower endpoint and at or
below the upper endpoint. Either update keeps a nonempty nested interval
and decreases its width. This proves the cursor bound without any assumption
about the monotonicity of the tick-price calculation.

Liquidity changes call `change_tick` once at each position endpoint.
Position construction bounds both endpoints, and the position fields are
private. Insertion adds the tick and sets its leaf bit. Removal deletes the
tick and clears its leaf bit. A tick whose counts remain nonzero keeps its
membership. If a call creates and then removes a tick, its final membership
and bit are both absent. Sui Prover checks the selected tick's membership
and the bitmap update contracts. For an arbitrary other index, the table
operations preserve membership, and setting or clearing one bit preserves
all other bits. The word update's return value is its new nonemptiness.
That value becomes the corresponding group bit, and the same rule links
the resulting group word to the top level. Applying this pointwise at each
of the three levels proves preservation for every key, including unused
bits in the last group.

The remaining curve operations have no path that changes bitmap membership.
Crossing mutates only a tick's fee-growth fields and sets the cursor to the
crossed index upward or one below it downward. A successful downward
crossing subtracts from a positive index. Moving inside a range invokes the
same bounded cursor search with its current cursor and a returned neighbor
or a legal endpoint. These are the only cursor assignments. Induction on
successful operations gives the invariant for every reachable bitmap state.

## Lookup

The start key is `i + 1` upward and `i` downward. The upward start can
legally be one past the last tick. Its word and group still fit the search
arithmetic. Z3 proves the byte decomposition and that lexicographic order
on the three coordinates equals numeric tick order.

The search visits the eligible portion of the current word, then eligible
whole words in the current group, then eligible whole groups. Every
eligible tick belongs to exactly one region, and any candidate in an earlier
region is closer than all candidates in later regions. The inclusive mask
keeps the start bit in the current word. The masks at the two parent levels
are strict because the current word or group has already been searched.
The bitvector checks cover every cutoff from 0 through 255.

Within a selected word the bit scan takes the preferred half whenever it
is nonempty. In the upward direction the low half is preferred, and in the
downward direction the high half is preferred. Z3 checks the support of both
halves at each of the eight production shifts. Selecting the high half
adds the split width to the result. This translation preserves order, so
after the final one-bit range the accumulated offset is the least or greatest
set bit of the input word. Z3 checks that each split selects a nonempty half and that a set bit in
that half maps to a set bit in the original word. The final nonempty
one-bit word contains bit zero. With `--compiled-module`, the verifier
checks the mask and scan instructions and the shift vector in `curve.mv`.
The pinned standard library's reverse-and-pop sequence visits those
shifts in order.

A selected parent bit points to an existing nonzero child under the
reachability invariant. Thus a group descent finds an eligible word, and
a word descent finds an initialized tick. Taking the extremal coordinate
at each level of the first occupied region gives the global nearest tick.
If all three masks are empty, the partition exhausts the eligible set and
lookup returns an empty option. The reconstruction bounds and the child
presence invariant also discharge the lookup's checked casts, additions,
and table borrows.

The source-pinned Z3 model supplies the bit arithmetic, interval and
order lemmas. The Sui Prover lookup specification checks the compiled
control flow on successful returns against a trace with an abstract
deterministic bit scan. The eight-step bitvector argument instantiates
that scan. A separate compiled no-abort check factors out the deterministic
masks and scan, then checks `next_tick` with live selected child keys. The
Z3 bitvector and ordering lemmas support the source-level argument that
these child keys exist on reachable states under the pinned `Table`
semantics. The compiled check takes child presence as a precondition. The
reachability induction composes the checked contracts and the source's
mutation sites. VM transaction semantics are outside this proof.

## Reproduce

From the repository root, run the source-pinned Z3 obligations and the
focused Sui Prover contracts. The setup and framework pin are described in
the [formal verification instructions](README.md#swap-arithmetic-proof).

```bash
python3 scripts/verify_dex_swaps.py
python3 scripts/verify_dex_swaps_move.py /path/to/sui-prover /path/to/prover-checkout /path/to/sui-checkout \
  --functions curve::new_bitmap_spec --functions curve::next_tick_spec \
  --functions curve::next_tick_return_spec \
  --functions curve::change_bitmap_spec --functions curve::set_initialized_spec \
  --functions curve::change_tick_spec --functions curve::cross_spec \
  --functions curve::cross_total_frame_spec --functions curve::move_inside_grid_spec
```
