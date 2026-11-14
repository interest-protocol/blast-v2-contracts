## Shared core

### What it is

Package `blast_core` holds the money building blocks every Blast launch product shares, each
defined once: a basis-points unit and its exact apportionment, outright or vested payouts, the LP-fee split, the ledger that holds Blast's fees and pays the partner's cut,
the one treasury address, Merkle proofs, and the sealed values that carry a sale's liquidity to its
venue and prove a sale's ownership to its vault. It holds no user funds of its own. Products and
vaults embed its values and call it; integrators read its events and build PTBs that pass its
values between product and venue calls.

### Units and payouts

- `blast_core::bps::Bps` is a rate from 0 to 10,000 basis points; `blast_core::bps::new` aborts
  above 10,000. `blast_core::bps::apply_up` applies it rounding up.
- `blast_core::bps::apportion` splits an amount over rates that sum to exactly 10,000 by largest
  remainder: every part takes its floor, an optional named part takes its ceiling, and the
  leftover units go one each to the largest remaining remainders, earlier parts first. The parts
  always sum to the amount.
- Every launch package uses one basis-points denominator, `blast_core::constants::basis_points_denominator`
  (10,000), and one cap on Blast's share of LP fees, `blast_core::constants::max_lp_fee_bps`
  (3,000 per asset). The bounds core's constructors enforce are public too:
  `blast_core::constants::max_routes` (20 routes per fee split) and
  `blast_core::constants::max_vesting_duration_ms` (2^63 ms). All four are public compile-time
  macros.
- A `payout::Recipient`, built with `payout::recipient`, is a nonzero destination address and
  optional `payout::VestingTerms` (from `payout::vesting_terms`); the zero address aborts.
  `payout::pay_or_vest` pays an amount to a recipient as a coin or, when it vests, locks the amount
  in an irrevocable, shared `blast_fun_linear_vesting::Vesting` schedule that starts at the payout
  and returns its ID. A zero amount sends and locks nothing. Each product keeps its own recipient
  lists and shares. `payout::destination` and `payout::recipient_vesting_terms` (called as
  `recipient.vesting_terms()`) read a recipient; `payout::cliff_delay_ms`,
  `payout::period_duration_ms`, and `payout::periods` read its terms.

### Fee splits

`fee_split::FeeSplit` is a list of up to 20 routes summing to 10,000. Each route has a positive
share and a `fee_split::Destination`: an address, the vault's owner, auto-LP, holder rewards, or
burn. No address and no special kind appears twice. `fee_split::apportion` divides one collection
across the routes in order.

### Protocol fees, partners, and the treasury

`protocol_fees::Ledger` holds Blast's Meme, Quote, and SUI fees for one launch, presale, or vault.
Only the module that owns it can create it, under its package witness, and every payment event
names that witness type, so a payment's origin is attributable.
`protocol_fees::new` borrows the origin object's UID and records its ID. Here `origin` identifies
the launch, presale, or vault the fees came from; it does not identify the beneficiary or grant
owner authority.
`protocol_fees::take_cut` moves Blast's rounded-up cut of a fee into it. A ledger is bound at
creation to the partner its sale named, or to none. `protocol_fees::pay` pays everything to the
treasury and aborts when a partner is bound; `protocol_fees::pay_with_partner` first pays that
partner its cut of each asset through `blast_partners::blast_partners::pay`, then the treasury the
rest. Both emit `blast_core_events::ProtocolFeesPaid`; an empty ledger sends and emits nothing. Products expose these payouts as calls anyone
may make. `protocol_fees::balances`, `protocol_fees::package_witness`, `protocol_fees::origin`, and
`protocol_fees::partner_id` read a ledger. `protocol_fees::destroy` deletes one that holds nothing
and aborts while any fee is held, so it must be paid out first.

`blast_treasury::Treasury` is a shared singleton holding the address Blast's fees go to. A Blast
admin with `blast_domain::TreasuryAdmin` schedules a new address with
`blast_treasury::schedule_destination`; anyone applies it with `blast_treasury::apply_destination`
once its notice has passed (48 hours from publication); a Blast admin with
`blast_domain::CancelAdmin` cancels it with `blast_treasury::cancel_destination`. Read the current
address with `blast_treasury::destination`, the notice the next change waits with
`blast_treasury::delay_ms`, and a scheduled change, as a `delayed::Proposal<address>`, with
`blast_treasury::pending_destination`. `blast_treasury::is_destination_ready` takes the `Clock` and
returns whether `blast_treasury::apply_destination` would succeed now: a change is scheduled, the
clock reads its `ready_at_ms` or later, and the clock plus its next notice still fits in a `u64`;
it returns false with nothing scheduled, before `ready_at_ms`, and after a cancel or an apply. The
treasury is never deleted: every ledger pays through it.

### Migration hand-off and owner proof

- Before a sale's supply is minted, its venue prepares the coin and returns a
  `migration::VenueTicket` for the sale's exact Meme and Quote pair, sealed by the venue's witness
  (`migration::issue_ticket`), so a ticket cannot start a sale of another coin or Quote. The venue
  keeps the pair's pool tier. The product's creation call redeems the ticket with `migration::redeem_ticket`
  and stores the venue.
- `migration::VaultTerms` are a vault's terms: the sale, the package witness that sealed them, the fee
  split, Blast's LP-fee shares, the partner, and whether residuals go to Blast or the owner.
  `migration::vault_terms` borrows the sale's `&UID` under the issuing package's witness and records its ID.
  It aborts when either of Blast's LP-fee shares exceeds 3,000 basis points, so every sealed term is within the cap.
- At migration the product creates a `migration::Migration` with `migration::new`, sealed by its own witness, holding the
  pool's Meme and Quote and terms the same package witness sealed. Only the stored venue can consume it,
  with `migration::redeem`; any other venue aborts.
- `owner_proof::OwnerProof` is a product's sealed statement that the caller holds the sale's
  creator authority, issued with `owner_proof::new` by borrowing the sale's `&UID` after checking
  that authority. The proof records the sale's ID. A vault consumes it with
  `owner_proof::assert_terms`, which aborts unless it names
  the vault's package witness and sale.

`VenueTicket`, `Migration`, and `OwnerProof` cannot be dropped, copied, or stored, so the PTB
that creates one must consume it. `VaultTerms` can be copied and stored.

Readers never consume them. `migration::ticket_venue` (called as `ticket.venue()`) reads a ticket's
venue. `migration::venue`, `migration::balances` (the Meme and Quote amounts), and
`migration::terms` read a migration; only `migration::redeem` releases its balances, and a copy of
its terms authorizes nothing, since an admitted venue never takes terms from its caller and each
sale has one vault. `migration::origin`, `migration::package_witness`, `migration::fee_split`,
`migration::protocol_bps`, `migration::partner_id`, and `migration::residuals` read terms;
`migration::is_protocol` and `migration::is_owner` read the `migration::ResidualPolicy` it
returns. `owner_proof::package_witness` and `owner_proof::origin` read
a proof.

### Sealed treasury caps and venue admissions

A product keeps a generated coin's `TreasuryCap` out of every hand but its own from the coin's
publication until the sale starts, so no one mints before the sale. The seal is
`sealed_treasury_cap::SealedTreasuryCap<Coin>` (`key, store`, wallet-held and transferable): the
product's own currency-creation call (`launch_ticket::new` for a launch, `blast_presale::sale_token::new` for a sale token)
wraps the fresh cap with `sealed_treasury_cap::new` under its package witness, and the publisher
receives the sealed cap. Only that product's witness opens it, through
`sealed_treasury_cap::into_treasury_cap`, which the product's `new` calls; a caller with another
witness aborts with `blast_core::errors::EWrongPackageWitness` (code 10).

A venue that must touch the cap while preparing the coin (Cetus mints its pool-creation capability
from it) borrows it with `sealed_treasury_cap::treasury_cap_mut`, presenting its own witness and
a `sealed_treasury_cap::VenueAdmission`: the product's droppable proof that it admits that venue,
issued under its package witness by `sealed_treasury_cap::venue_admission` after the product
checked its own venue allowlist (`launch_config::venue_admission` and
`creation_policy::venue_admission`, both *anyone*, abort with the product's venue-not-allowed
error). The borrow aborts with `blast_core::errors::EWrongPackageWitness` (code 10) when the admission
comes from a product other than the one that sealed the cap, and with
`blast_core::errors::EVenueNotAdmitted` (code 14) when the admission names another venue. A reference
result never leaves Move code, so only the venue's own call reaches the cap.

Readers: `sealed_treasury_cap::package_witness`, `sealed_treasury_cap::treasury_cap_id`, and
`sealed_treasury_cap::total_supply` read a sealed cap; `sealed_treasury_cap::admission_package_witness`
(called as `admission.package_witness()`) and `sealed_treasury_cap::admission_venue` (`admission.venue()`)
read an admission.

### Pool seed price

`migration::sqrt_price_x64` derives the price a concentrated-liquidity venue (Cetus or Bluefin)
seeds a migrated pool at, from the migration's atomic Meme and Quote amounts:
`floor(sqrt(B / A) * 2^64)`, where B / A is Quote / Meme when Meme is coin A and Meme / Quote
otherwise. Display decimals never enter it, and the divisor amount must be positive.
`migration::is_seedable_price` says whether a sqrt price can seed a full-range pool: strictly above
2 × 4,295,048,016 and at most `floor(2^128 / (2 × 4,295,048,016 + 1))`, which is
39,613,336,755,921,976,950,891,976,999. That upper bound is below half the venue maximum
(79,226,673,515,401,279,992,447,579,055 / 2). Presale and launch check only the Meme-as-coin-A
order. `migrate` does not repeat the check; it prices the pool in the venue's coin order. For
every positive amount pair the other order is on the same side of these bounds. 1 Meme atom
against 4,611,512,677,774,425,882 Quote atoms is still under half the maximum in one order and
exactly twice the minimum in the other, so both orders are refused. A product uses the check to
refuse a sale that is outside this range in either coin order. Both are pure reads anyone may call.

### Merkle proofs

`blast_core::merkle::verify` checks a positional Blake2b-256 proof of a leaf digest at an index. Leaves hash
as `blake2b256(0x00 || domain || payload)` with `blast_core::merkle::leaf`, where each tree's
purpose names its own domain string; internal nodes hash as `blake2b256(0x01 || left || right)`;
an odd node at any level is its own sibling. Malformed roots, digests, or siblings,
an empty tree, an index outside it, or a proof of the wrong depth return false instead of aborting.

### Roles

`blast_domain` declares Blast's product roles for the shared ACL: `TreasuryAdmin`, `FeeAdmin`,
`ListingAdmin`, `VenueAdmin`, `RewardsAdmin`, `BuybackAdmin`, `AutoLpAdmin`, `CreatorAdmin`,
`ClaimSignerAdmin`, and `CancelAdmin`. Only Blast admins hold them.

### Errors

Every abort is a small integer from the package's numeric registry; the reference lists each code.
The abort names the module that raised it.
