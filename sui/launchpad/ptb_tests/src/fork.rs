//! The committed mainnet venue snapshot (`fork/`) and the venue arithmetic and event mirrors the
//! venue-fork tests share.
//!
//! `fork/snapshot/` holds, at one pinned mainnet checkpoint, every package Cetus CLMM, Cetus LP
//! Burn, and Bluefin Spot load and every live object and dynamic field their code reads
//! (`fork/fetch.py` writes it and records why each entry is there).

use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
};

use anyhow::{Context, Result, ensure};
use serde::{Deserialize, de::DeserializeOwned};
use sui_types::{
    TypeTag,
    base_types::{ObjectID, SequenceNumber},
    move_package::MovePackage,
    object::Object,
    parse_sui_type_tag,
};

use crate::{Harness, Outcome};

// === Pinned venue packages (see `fork/fetch.py`) ===

pub const CETUS: &str = "0x260693ec785a6e6c9d81d58c7d2ff72f1288ae0fa6a9725abe05a6478b11f084";
pub const LP_BURN: &str = "0xc4aabc874f5060d3147d8f74c14e3a8a1f9f8d92edea138a51635395ed167cd9";
pub const BLUEFIN: &str = "0xd075338d105482f1527cbfd363d6413558f184dec36d9138a70261e87f486e9c";
pub const USDC: &str = "0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC";

/// Cetus's `tick_math` bounds, the price limits of a swap that runs to completion.
pub const CETUS_MIN_SQRT_PRICE: u128 = 4_295_048_016;
pub const CETUS_MAX_SQRT_PRICE: u128 = 79_226_673_515_401_279_992_447_579_055;
/// Bluefin's `tick_math` bounds; a swap limit must lie strictly inside them (`pool` 1009).
pub const BLUEFIN_MIN_SQRT_PRICE: u128 = 4_295_048_016;
pub const BLUEFIN_MAX_SQRT_PRICE: u128 = 79_226_673_515_401_279_992_447_579_055;

/// The largest tick both venues admit; a full range aligns it inward to the tick spacing.
pub const MAX_TICK: i32 = 443_636;

pub fn id(literal: &str) -> ObjectID {
    ObjectID::from_hex_literal(literal).expect("object ID")
}

pub fn tag(literal: &str) -> TypeTag {
    parse_sui_type_tag(literal).expect("type tag")
}

pub fn sui() -> TypeTag {
    tag("0x2::sui::SUI")
}

// === Snapshot ===

#[derive(Deserialize)]
struct Manifest {
    checkpoint: u64,
    packages: Vec<ManifestEntry>,
    objects: Vec<ManifestEntry>,
}

#[derive(Deserialize)]
struct ManifestEntry {
    #[serde(default)]
    name: String,
    id: String,
    version: u64,
    digest: String,
    file: String,
}

fn snapshot_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("fork/snapshot")
}

/// Inserts every snapshot package and object at its real ID and returns the checkpoint and the
/// objects by name. Each file must hash to its recorded digest. Mainnet packages link the framework
/// at mainnet versions, so those linkage entries are repointed at the simulator's framework.
pub fn insert_snapshot(h: &mut Harness) -> Result<(u64, BTreeMap<String, ObjectID>)> {
    let dir = snapshot_dir();
    let manifest: Manifest = serde_json::from_str(&std::fs::read_to_string(dir.join("manifest.json"))?)?;
    let read = |entry: &ManifestEntry| -> Result<Object> {
        let object: Object = bcs::from_bytes(&std::fs::read(dir.join(&entry.file))?)?;
        ensure!(object.id() == id(&entry.id), "{} holds {}", entry.file, object.id());
        ensure!(object.version().value() == entry.version, "{} version", entry.file);
        ensure!(object.digest().to_string() == entry.digest, "{} does not match its digest", entry.file);
        Ok(object)
    };
    for entry in &manifest.packages {
        let object = read(entry)?;
        let package = object.data.try_as_package().context("package")?;
        let mut linkage = package.linkage_table().clone();
        for framework in 1u8..=3 {
            if let Some(info) = linkage.get_mut(&ObjectID::from_single_byte(framework)) {
                info.upgraded_version = h.object(ObjectID::from_single_byte(framework)).version();
            }
        }
        let package = MovePackage::new(
            package.id(),
            package.version(),
            package.serialized_module_map().clone(),
            u64::MAX,
            package.type_origin_table().clone(),
            linkage,
        )?;
        h.insert(Object::new_from_package(package, object.previous_transaction));
    }
    let mut objects = BTreeMap::new();
    for entry in &manifest.objects {
        let object = read(entry)?;
        objects.insert(entry.name.clone(), object.id());
        h.insert(object);
    }

    Ok((manifest.checkpoint, objects))
}

/// The venue packages a venue adapter links: Cetus, LP Burn, Bluefin, and every package in their
/// linkage tables at the highest version any of them names, as publication requires.
pub fn venue_dependencies(h: &Harness) -> Result<Vec<ObjectID>> {
    let mut table: BTreeMap<ObjectID, (ObjectID, SequenceNumber)> = BTreeMap::new();
    let mut add = |original: ObjectID, current: ObjectID, version: SequenceNumber| {
        let entry = table.entry(original).or_insert((current, version));
        if version > entry.1 {
            *entry = (current, version);
        }
    };
    for root in [CETUS, LP_BURN, BLUEFIN] {
        let object = h.object(id(root));
        let package = object.data.try_as_package().context("venue package")?;
        add(package.original_package_id(), package.id(), package.version());
        for (original, info) in package.linkage_table() {
            if *original > ObjectID::from_single_byte(3) {
                add(*original, info.upgraded_id, info.upgraded_version);
            }
        }
    }

    Ok(table.into_values().map(|(current, _)| current).collect())
}

// === Venue and Blast arithmetic ===

/// Cetus orders a pool's coins by `type_name::with_defining_ids` (64 hex digits, no `0x`); a
/// Meme is coin A exactly when its name sorts after the Quote's.
pub fn cetus_name(coin: &TypeTag) -> String {
    let TypeTag::Struct(coin) = coin else { panic!("struct type") };
    format!("{}::{}::{}", coin.address.to_canonical_string(false), coin.module, coin.name)
}

pub fn meme_is_cetus_a(meme: &TypeTag, quote: &TypeTag) -> bool {
    cetus_name(meme) > cetus_name(quote)
}

/// floor(sqrt(coin_b / coin_a) * 2^64) of the handed-off atoms, as `migration_math` derives it:
/// the largest root whose square is at most `(numerator << 128) / denominator`.
pub fn expected_sqrt_price(meme: u64, quote: u64, meme_is_a: bool) -> u128 {
    let (numerator, denominator) = if meme_is_a { (quote, meme) } else { (meme, quote) };
    // The Q128 ratio as (high, low) 128-bit limbs: (n / d) << 128 plus ((n % d) << 128) / d.
    let (n, d) = (u128::from(numerator), u128::from(denominator));
    let high = n / d;
    let (mut remainder, mut low) = (n % d, 0u128);
    for _ in 0..128 {
        remainder <<= 1;
        low <<= 1;
        if remainder >= d {
            remainder -= d;
            low |= 1;
        }
    }
    // root < 2^96, so its square splits exactly into (a^2 << 128) + (a*b << 65) + b^2 with
    // a = root >> 64 and b the low 64 bits.
    let square_at_most = |root: u128| {
        let (a, b) = (root >> 64, root & u128::from(u64::MAX));
        let (ab, b2) = (a * b, b * b);
        let square_low = b2.wrapping_add(ab << 65);
        let square_high = a * a + (ab >> 63) + u128::from(square_low < b2);
        (square_high, square_low) <= (high, low)
    };
    let (mut lower, mut upper) = (0u128, 1u128 << 96);
    while lower + 1 < upper {
        let middle = (lower + upper) / 2;
        if square_at_most(middle) { lower = middle } else { upper = middle }
    }
    lower
}

/// Largest-remainder apportionment of BPS weights with no protected entry: floors, then one unit
/// each by descending remainder, ties in table order.
pub fn apportion(weights: &[u64], total: u64) -> Vec<u64> {
    let mut amounts: Vec<u64> = weights.iter().map(|bps| (total as u128 * *bps as u128 / 10_000) as u64).collect();
    let mut ranked: Vec<usize> = (0..weights.len()).collect();
    ranked.sort_by(|a, b| {
        let remainder = |i: usize| total as u128 * weights[i] as u128 % 10_000;
        remainder(*b).cmp(&remainder(*a)).then(a.cmp(b))
    });
    let residue = total - amounts.iter().sum::<u64>();
    for i in 0..residue as usize {
        amounts[ranked[i]] += 1;
    }
    amounts
}

// === Venue event and object mirrors (BCS field order) ===

/// Payloads of every event whose type is `module::name`, from any package.
pub fn venue_events<T: DeserializeOwned>(outcome: &Outcome, module: &str, name: &str) -> Vec<T> {
    outcome
        .events
        .iter()
        .filter(|event| event.type_.module.as_str() == module && event.type_.name.as_str() == name)
        .map(|event| bcs::from_bytes(&event.contents).expect("venue event payload"))
        .collect()
}

/// Mirrors `cetus_clmm::factory::RegisterPermissionPairEvent`.
#[derive(Deserialize)]
pub struct RegisterPermissionPair {
    pub cap: ObjectID,
    pub _pool_key: ObjectID,
    pub coin_type: String,
    pub coin_pair: String,
    pub tick_spacing: u32,
}

#[derive(Deserialize)]
pub struct MintPoolCreationCap {
    pub _coin_type: String,
    pub cap: ObjectID,
}

#[derive(Deserialize)]
pub struct CreatePool {
    pub pool_id: ObjectID,
    pub _coin_type_a: String,
    pub _coin_type_b: String,
    pub tick_spacing: u32,
}

#[derive(Deserialize)]
pub struct CetusOpenPosition {
    pub _pool: ObjectID,
    pub tick_lower: u32,
    pub tick_upper: u32,
    pub position: ObjectID,
}

#[derive(Deserialize)]
pub struct CetusAddLiquidity {
    pub _pool: ObjectID,
    pub position: ObjectID,
    pub _tick_lower: u32,
    pub _tick_upper: u32,
    pub liquidity: u128,
    pub _after_liquidity: u128,
    pub _current_sqrt_price: u128,
    pub amount_a: u64,
    pub amount_b: u64,
}

#[derive(Deserialize)]
pub struct CetusCollectFee {
    pub _position: ObjectID,
    pub pool: ObjectID,
    pub amount_a: u64,
    pub amount_b: u64,
}

/// The fixed-size head of `cetus_clmm::pool::Pool`.
#[derive(Deserialize)]
pub struct CetusPoolState {
    pub _id: ObjectID,
    pub coin_a: u64,
    pub coin_b: u64,
    pub tick_spacing: u32,
    pub fee_rate: u64,
    pub liquidity: u128,
    pub sqrt_price: u128,
    pub _tick: u32,
}

impl CetusPoolState {
    pub fn of(h: &Harness, pool: ObjectID) -> Result<Self> {
        Ok(bcs::from_bytes(&h.contents(pool)[..96])?)
    }
}

#[derive(Deserialize)]
pub struct CetusPosition {
    pub id: ObjectID,
    pub pool: ObjectID,
    pub _index: u64,
    pub _coin_type_a: String,
    pub _coin_type_b: String,
    pub _name: String,
    pub _description: String,
    pub _url: String,
    pub _tick_lower: u32,
    pub _tick_upper: u32,
    pub liquidity: u128,
}

/// Mirrors `lp_burn::CetusLPBurnProof`.
#[derive(Deserialize)]
pub struct BurnProof {
    pub _id: ObjectID,
    pub _name: String,
    pub _description: String,
    pub _image_url: String,
    pub position: CetusPosition,
}

#[derive(Deserialize)]
pub struct BurnPosition {
    pub position_id: ObjectID,
    pub burned_position_id: ObjectID,
    pub pool_id: ObjectID,
}

/// `dynamic_field::Field<ID, lp_burn::BurnedPositionInfo>` under the BurnManager's pool table.
#[derive(Deserialize)]
pub struct BurnRecord {
    pub _id: ObjectID,
    pub name: ObjectID,
    pub burned_position_id: ObjectID,
    pub position_id: ObjectID,
    pub pool_id: ObjectID,
}

#[derive(Deserialize)]
pub struct BluefinPoolCreated {
    pub id: ObjectID,
    pub _coin_a: String,
    pub _coin_a_symbol: String,
    pub _coin_a_decimals: u8,
    pub _coin_a_url: String,
    pub _coin_b: String,
    pub _coin_b_symbol: String,
    pub _coin_b_decimals: u8,
    pub _coin_b_url: String,
    pub current_sqrt_price: u128,
    pub _current_tick_index: u32,
    pub tick_spacing: u32,
    pub fee_rate: u64,
    pub _protocol_fee_share: u64,
}

#[derive(Deserialize)]
pub struct LiquidityProvided {
    pub _pool_id: ObjectID,
    pub position_id: ObjectID,
    pub coin_a_amount: u64,
    pub coin_b_amount: u64,
    pub pool_coin_a_amount: u64,
    pub pool_coin_b_amount: u64,
    pub liquidity: u128,
    pub _before_liquidity: u128,
    pub after_liquidity: u128,
    pub _current_sqrt_price: u128,
    pub _current_tick_index: u32,
    pub lower_tick: u32,
    pub upper_tick: u32,
    pub _sequence_number: u128,
}

#[derive(Deserialize)]
pub struct UserFeeCollected {
    pub _pool_id: ObjectID,
    pub position_id: ObjectID,
    pub coin_a_amount: u64,
    pub coin_b_amount: u64,
    pub _pool_coin_a_amount: u64,
    pub _pool_coin_b_amount: u64,
    pub _sequence_number: u128,
}
