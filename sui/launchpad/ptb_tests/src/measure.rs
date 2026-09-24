//! Resource evidence for one executed transaction against the simulator's own protocol limits.
//!
//! Every limit is read from the `ProtocolConfig` the simulator executes under, and every quantity
//! is measured in the unit its limit is enforced in; a quantity over its limit fails the test.

use move_core_types::language_storage::StructTag;
use serde_json::{Value, json};
use sui_types::{
    effects::{TransactionEffects, TransactionEffectsAPI},
    object::Owner,
    transaction::{CallArg, Command, ObjectArg, SharedObjectMutability, TransactionDataAPI, TransactionKind},
};

use crate::{Harness, Outcome};

/// A Move value's shape, enough to walk its BCS bytes.
enum Layout {
    Bool,
    U8,
    U64,
    U128,
    Address,
    Vector(Box<Layout>),
    Struct(Vec<Layout>),
    Enum(Vec<Vec<Layout>>),
}

impl Layout {
    /// The VM abstract size `sui::event::emit` limits, of the BCS value at the front of `bytes`,
    /// which it consumes: 8 per primitive below `u128`, 16 per `u128`, 32 per address, 2 per
    /// struct, variant, or vector, and the packed element width inside a primitive vector.
    fn abstract_size(&self, bytes: &mut &[u8]) -> u64 {
        match self {
            Layout::Bool | Layout::U8 => advance(bytes, 1, 8),
            Layout::U64 => advance(bytes, 8, 8),
            Layout::U128 => advance(bytes, 16, 16),
            Layout::Address => advance(bytes, 32, 32),
            Layout::Struct(fields) => 2 + fields.iter().map(|field| field.abstract_size(bytes)).sum::<u64>(),
            Layout::Enum(variants) => {
                let variant = &variants[uleb128(bytes) as usize];
                2 + variant.iter().map(|field| field.abstract_size(bytes)).sum::<u64>()
            }
            Layout::Vector(element) => {
                let length = uleb128(bytes);
                let width = match **element {
                    Layout::Bool | Layout::U8 => 1,
                    Layout::U64 => 8,
                    Layout::U128 => 16,
                    Layout::Address => 32,
                    _ => return 2 + (0..length).map(|_| element.abstract_size(bytes)).sum::<u64>(),
                };
                2 + advance(bytes, (length * width) as usize, length * width)
            }
        }
    }
}

fn advance(bytes: &mut &[u8], length: usize, size: u64) -> u64 {
    *bytes = &bytes[length..];
    size
}

fn uleb128(bytes: &mut &[u8]) -> u64 {
    let mut value = 0;
    for shift in (0..).step_by(7) {
        let byte = bytes[0];
        *bytes = &bytes[1..];
        value |= u64::from(byte & 0x7f) << shift;
        if byte & 0x80 == 0 {
            break;
        }
    }
    value
}

/// Layout of every event payload the measured transactions emit.
fn payload_layout(payload: &StructTag) -> Layout {
    use Layout::{Address, Bool, Enum, Struct, U8, U64, U128, Vector};
    let id = || Struct(vec![Address]);
    let bps = || Struct(vec![U64]);
    let type_name = || Struct(vec![Struct(vec![Vector(Box::new(U8))])]);
    let amounts = || Vector(Box::new(U64));
    let routes = || {
        let table = || Vector(Box::new(Struct(vec![Address, bps()])));
        Struct(vec![table(), table()])
    };
    let weights = || Vector(Box::new(Struct(vec![U64, bps()])));
    let channels = || Vector(Box::new(Struct(vec![U64, Enum(vec![vec![], vec![], vec![]]), Address])));
    match payload.name.as_str() {
        "LaunchCreated" => Struct(vec![
            id(),
            id(),
            U8,
            U64,
            type_name(),
            type_name(),
            U64,
            U64,
            U64,
            U64,
            Struct(vec![channels(), weights(), weights()]),
            amounts(),
        ]),
        "ProtectionConfigured" => Struct(vec![id(), U64, U64, U64, U64, U64]),
        "FeeRouterCreated" => Struct(vec![id(), id(), id(), routes()]),
        "LaunchShared" => Struct(vec![id(), id(), U64, Bool]),
        "RoutesChanged" => Struct(vec![id(), U64, U64, routes(), routes()]),
        "RouterActivated" => {
            Struct(vec![id(), id(), Bool, U64, U64, type_name(), id(), id(), id(), U64, routes()])
        }
        "MigrationAllocationPaid" => Struct(vec![id(), U64, Address, U64, U64]),
        "Migrated" => Struct(vec![id(), U64, U64, U64, U64, U128, U64, Bool, U64]),
        "FeesCollected" => Struct(vec![id(), id(), U64, U64, U64, Address, U64, U64, amounts(), amounts()]),
        "LaunchTicketCreated" => Struct(vec![
            id(),
            type_name(),
            U8,
            U64,
            id(),
            Struct(vec![Vector(Box::new(Address))]),
            Struct(vec![Vector(Box::new(Vector(Box::new(U8))))]),
            Bool,
            U64,
        ]),
        "PreShareBought" => Struct(vec![id(), U64, U64, U64, U64, U64, U64, U64, U64, U64, U64]),
        "Bought" => Struct(vec![id(), U64, U64, U64, U64, U64, U64, U64, U64]),
        "VestingCreated" => Struct(vec![
            id(),
            type_name(),
            Address,
            Struct(vec![Vector(Box::new(Address))]),
            Struct(vec![Vector(Box::new(id()))]),
            U64,
            U64,
            U64,
            U64,
            U64,
        ]),
        other => panic!("no layout for event payload {other}"),
    }
}

/// A quantity with the inclusive protocol limit it must not exceed.
fn at_most(measured: u64, limit: u64) -> Value {
    assert!(measured <= limit, "{measured} exceeds the protocol limit {limit}");
    json!({ "measured": measured, "limit": limit, "rule": "<=", "margin": limit - measured })
}

/// A quantity with the exclusive protocol limit it must stay below.
fn below(measured: u64, limit: u64) -> Value {
    assert!(measured < limit, "{measured} reaches the protocol limit {limit}");
    json!({ "measured": measured, "limit": limit, "rule": "<", "margin": limit - 1 - measured })
}

impl Harness {
    /// Protocol version, the limits `resources` compares against, the identifier bound that caps a
    /// type name's length, and the reference gas price.
    pub fn protocol_limits(&self) -> Value {
        let config = self.sim.protocol_config();
        json!({
            "protocol_version": config.version.as_u64(),
            "source": "sui-protocol-config at the pinned revision, as executed by simulacrum",
            "max_tx_size_bytes": config.max_tx_size_bytes(),
            "max_programmable_tx_commands": config.max_programmable_tx_commands(),
            "max_arguments": config.max_arguments(),
            "max_pure_argument_size": config.max_pure_argument_size(),
            "max_input_objects": config.max_input_objects(),
            "max_tx_gas": config.max_tx_gas(),
            "max_gas_computation_bucket": config.max_gas_computation_bucket(),
            "max_serialized_tx_effects_size_bytes": config.max_serialized_tx_effects_size_bytes(),
            "max_num_new_move_object_ids": config.max_num_new_move_object_ids(),
            "max_num_transferred_move_object_ids": config.max_num_transferred_move_object_ids(),
            "max_size_written_objects": config.max_size_written_objects(),
            "max_move_object_size": config.max_move_object_size(),
            "max_num_event_emit": config.max_num_event_emit(),
            "max_event_emit_size": config.max_event_emit_size(),
            "max_event_emit_size_total": config.max_event_emit_size_total_as_option(),
            "max_move_identifier_len": config.max_move_identifier_len(),
            "reference_gas_price_mist": self.sim.reference_gas_price(),
        })
    }

    /// Resource use of an executed `outcome`, which may have failed, against this simulator's
    /// protocol limits.
    pub fn resources(&self, outcome: &Outcome) -> Value {
        let config = self.sim.protocol_config();
        let data = outcome.transaction.data();
        let TransactionKind::ProgrammableTransaction(pt) = data.transaction_data().kind() else {
            panic!("not a programmable transaction");
        };

        let (mut pure, mut owned, mut receiving, mut shared_mutable, mut shared_immutable) = (0, 0, 0, 0, 0);
        let mut largest_pure = 0;
        for input in &pt.inputs {
            match input {
                CallArg::Pure(bytes) => {
                    pure += 1;
                    largest_pure = largest_pure.max(bytes.len() as u64);
                }
                CallArg::Object(ObjectArg::ImmOrOwnedObject(_)) => owned += 1,
                CallArg::Object(ObjectArg::Receiving(_)) => receiving += 1,
                CallArg::Object(ObjectArg::SharedObject { mutability, .. }) => {
                    if *mutability == SharedObjectMutability::Mutable {
                        shared_mutable += 1
                    } else {
                        shared_immutable += 1
                    }
                }
                CallArg::FundsWithdrawal(_) => panic!("unmeasured funds withdrawal"),
            }
        }
        let largest_command = pt
            .commands
            .iter()
            .map(|command| match command {
                Command::MoveCall(call) => call.arguments.len(),
                Command::MakeMoveVec(_, arguments) => arguments.len(),
                Command::TransferObjects(objects, _) => objects.len(),
                Command::SplitCoins(_, amounts) => amounts.len(),
                Command::MergeCoins(_, sources) => sources.len(),
                Command::Publish(..) | Command::Upgrade(..) => 0,
            })
            .max()
            .unwrap_or(0) as u64;
        let input_objects = pt.input_objects().expect("input objects").len() as u64 + receiving;
        let packages = input_objects - receiving - owned - shared_mutable - shared_immutable;

        let effects = &outcome.effects;
        let gas = effects.gas_cost_summary();
        let price = data.transaction_data().gas_price();
        let changed = effects.all_changed_objects();
        let written: Vec<_> = changed
            .iter()
            .map(|((id, version, _), ..)| {
                self.sim.store().get_object_at_version(id, *version).expect("written object")
            })
            .collect();
        let largest_object = written
            .iter()
            .filter_map(|object| object.data.try_as_move())
            .map(|object| object.contents().len() as u64)
            .max()
            .unwrap_or(0);
        let owner_count =
            |kind: fn(&Owner) -> bool| effects.created().iter().filter(|(_, owner)| kind(owner)).count();

        let mut total_event_size = 0;
        let events: Vec<_> = outcome
            .events
            .iter()
            .map(|event| {
                // A Blast payload travels inside the `blast_events::Event<T>` envelope, one more
                // struct; another package's event is its own payload.
                let (payload, layout) = match event.type_.type_params.as_slice() {
                    [sui_types::TypeTag::Struct(inner)] if event.type_.module.as_str() == "blast_events" => {
                        (inner.as_ref(), Layout::Struct(vec![payload_layout(inner)]))
                    }
                    _ => (&event.type_, payload_layout(&event.type_)),
                };
                let mut contents = event.contents.as_slice();
                let value = layout.abstract_size(&mut contents);
                assert!(contents.is_empty(), "layout of {} left bytes unread", payload.name);
                let size = u64::from(event.type_.abstract_size_for_gas_metering()) + value;
                total_event_size += size;
                json!({
                    "payload": payload.name.as_str(),
                    "bcs_bytes": event.contents.len(),
                    "emit_size": at_most(size, config.max_event_emit_size()),
                })
            })
            .collect();

        json!({
            "status": format!("{:?}", outcome.effects.status()),
            "transaction": {
                "signed_bytes": at_most(
                    data.serialized_size().expect("transaction size") as u64,
                    config.max_tx_size_bytes(),
                ),
                "commands": below(pt.commands.len() as u64, config.max_programmable_tx_commands().into()),
                "largest_command_arguments": below(largest_command, config.max_arguments().into()),
                "largest_pure_argument_bytes": below(largest_pure, config.max_pure_argument_size().into()),
                "input_objects": at_most(input_objects, config.max_input_objects()),
                "inputs": {
                    "pure": pure,
                    "owned": owned,
                    "receiving": receiving,
                    "shared_mutable": shared_mutable,
                    "shared_immutable": shared_immutable,
                    "packages": packages,
                    "gas_payment": data.transaction_data().gas().len(),
                },
            },
            "gas": {
                "gas_price_mist": price,
                "computation_cost_mist": gas.computation_cost,
                "computation_units": at_most(
                    gas.computation_cost / price,
                    config.max_gas_computation_bucket(),
                ),
                "storage_cost_mist": gas.storage_cost,
                "storage_rebate_mist": gas.storage_rebate,
                "non_refundable_storage_fee_mist": gas.non_refundable_storage_fee,
                "charged_before_rebate_mist": at_most(
                    gas.computation_cost + gas.storage_cost,
                    config.max_tx_gas(),
                ),
                "net_mist": gas.net_gas_usage(),
            },
            "effects": {
                "bcs_bytes": at_most(
                    bcs::serialized_size(effects).expect("effects size") as u64,
                    config.max_serialized_tx_effects_size_bytes(),
                ),
                // Execution enforces the limit on this upper bound, not on the final encoding.
                "enforced_size_estimate": at_most(
                    TransactionEffects::estimate_effects_size_upperbound_v2(
                        changed.len(),
                        effects.modified_at_versions().len(),
                        (input_objects - receiving) as usize + data.transaction_data().gas().len(),
                    ) as u64,
                    config.max_serialized_tx_effects_size_bytes(),
                ),
                // IDs created and destroyed or wrapped in the same transaction are not in effects,
                // so this is a lower bound on new IDs.
                "created": at_most(effects.created().len() as u64, config.max_num_new_move_object_ids()),
                "created_address_owned": owner_count(|owner| matches!(owner, Owner::AddressOwner(_))),
                "created_shared": owner_count(|owner| owner.is_shared()),
                "created_object_owned": owner_count(|owner| matches!(owner, Owner::ObjectOwner(_))),
                // Every created or unwrapped top-level object was transferred or shared.
                "transferred": at_most(
                    (effects.created().len() + effects.unwrapped().len()) as u64,
                    config.max_num_transferred_move_object_ids(),
                ),
                "mutated": effects.mutated().len(),
                "unwrapped": effects.unwrapped().len(),
                "deleted": effects.deleted().len(),
                "wrapped": effects.wrapped().len(),
            },
            "written_objects": {
                "count": written.len(),
                "metered_bytes": at_most(
                    written.iter().map(|object| object.object_size_for_gas_metering() as u64).sum(),
                    config.max_size_written_objects(),
                ),
                "largest_move_object_bytes": at_most(largest_object, config.max_move_object_size()),
            },
            "events": {
                "count": at_most(events.len() as u64, config.max_num_event_emit()),
                "total_emit_size": config
                    .max_event_emit_size_total_as_option()
                    .map_or(json!(total_event_size), |limit| at_most(total_event_size, limit)),
                "each": events,
            },
        })
    }
}
