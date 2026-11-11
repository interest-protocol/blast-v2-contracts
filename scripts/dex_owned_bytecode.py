"""Validate the production bytecode boundary for the owned-position ledger."""

from collections import Counter
from hashlib import sha256
import re

from dex_mul_div_bytecode import disassemble_module


def function_bodies(source, module):
    bodies = dict(re.findall(
        r"^(?:public(?:\(friend\))? )?(\w+)(?:<[^\n]*>)?\([^\n]*\)\s*(?:: [^\n]+)? \{\n(.*?)^\}",
        source, re.M | re.S,
    ))
    instructions = re.findall(r"^\s+\d+: .*", source, re.M)
    if not bodies or sum(len(re.findall(r"^\s+\d+: .*", body, re.M)) for body in bodies.values()) != len(instructions):
        raise SystemExit(f"Could not enumerate all compiled {module} instructions.")
    return bodies


def field_effects(bodies, tracked):
    pattern = rf"^\s+\d+: (Unpack|Pack|MutBorrowField)(?:Generic)?\[\d+\]\(({tracked})(?:[<.]|\))([\w]*)"
    effects = Counter()
    for name, body in bodies.items():
        for operation, struct, field in re.findall(pattern, body, re.M):
            effects[(name, operation, struct, field if operation == "MutBorrowField" else "")] += 1
    return effects


def require_effects(effects, expected, module):
    if effects != expected:
        raise SystemExit(f"Compiled {module} effects changed. Extra: {effects - expected}. Missing: {expected - effects}.")


def check_position_route(bodies):
    for operation, settle_index in (("add", 52), ("remove", 50)):
        name = f"execute_{operation}_liquidity"
        code = re.findall(r"^\s+\d+: ([^\n]+)", bodies[name], re.M)
        locals_ = [re.sub(r"^(\w+Loc\[\d+\])\(.*\)$", r"\1", op) for op in code]
        if (locals_[:6] != ["CopyLoc[0]", "FreezeRef", "MoveLoc[1]", "MoveLoc[2]", "CopyLoc[3]", "FreezeRef"]
                or not code[6].startswith(f"Call open_{operation}_liquidity<")
                or locals_[43:45] != ["MoveLoc[0]", "MoveLoc[3]"]
                or not code[settle_index].startswith(f"Call settle_{operation}_liquidity<")
                or locals_[settle_index + 1:] != ["Ret"]
                or any(re.match(r"^StLoc\[[03]\]", op) for op in code)):
            raise SystemExit(f"Compiled {name} no longer opens and settles against the same arguments.")
    delegates = Counter((name, callee)
                        for name, body in bodies.items()
                        for callee in re.findall(
                            r"^\s+\d+: Call ([^<(]+)(?:<[^\n]*)?\([^\n]*&mut Position<", body, re.M))
    if delegates != Counter({("execute_add_liquidity", "settle_add_liquidity"): 1,
                             ("execute_remove_liquidity", "settle_remove_liquidity"): 1}):
        raise SystemExit("Compiled position mutation delegates changed.")

    create = re.findall(r"^\s+\d+: (.*)", bodies["new_position"], re.M)
    destroy = re.findall(r"^\s+\d+: (.*)", bodies["destroy_empty_position"], re.M)
    if (len(create) != 45 or create[35] != "Call object::new(&mut TxContext): UID"
            or not create[43].startswith("PackGeneric[")
            or len(destroy) != 18 or destroy[16] != "Call object::delete(UID)"):
        raise SystemExit("Compiled position construction or destruction no longer uses Sui UID operations.")


def check_owned_bytecode(price_module):
    pool_module = price_module.with_name("pool.mv")
    source = disassemble_module(pool_module, 0, "pool")
    if not re.search(r"^use 0*2::object;$", source, re.M):
        raise SystemExit("Compiled pool does not bind Sui object operations.")
    if not re.search(r"^struct Position<.*> has store, key \{$", source, re.M):
        raise SystemExit("The compiled Position abilities changed.")
    for name in ("AddLiquidityRequest", "RemoveLiquidityRequest", "SwapRequest", "Completion"):
        if not re.search(rf"^struct {name}<[^\n]*> \{{$", source, re.M):
            raise SystemExit(f"The compiled {name} abilities changed.")
    if re.search(r"^\S.*\): &mut Position<", source, re.M):
        raise SystemExit("Compiled pool returns a mutable position reference.")
    bodies = function_bodies(source, "pool")
    check_position_route(bodies)
    effects = field_effects(
        bodies, "Position|Pool|PoolInitializer|AddLiquidityRequest|RemoveLiquidityRequest|SwapRequest|Completion|Approval",
    )

    expected = Counter({
        ("new", "Pack", "Pool", ""): 1,
        ("new_position", "Pack", "Position", ""): 1,
        ("destroy_empty_position", "Unpack", "Position", ""): 1,
        ("begin_add_liquidity", "Pack", "AddLiquidityRequest", ""): 1,
        ("open_add_liquidity", "Unpack", "AddLiquidityRequest", ""): 1,
        ("approve_add_liquidity", "MutBorrowField", "AddLiquidityRequest", "approval"): 1,
        ("begin_remove_liquidity", "Pack", "RemoveLiquidityRequest", ""): 1,
        ("open_remove_liquidity", "Unpack", "RemoveLiquidityRequest", ""): 1,
        ("approve_remove_liquidity", "MutBorrowField", "RemoveLiquidityRequest", "approval"): 1,
        ("new", "Pack", "PoolInitializer", ""): 1,
        ("finalize", "Unpack", "PoolInitializer", ""): 1,
        ("register_hook", "MutBorrowField", "PoolInitializer", "pool"): 1,
        ("new_swap_request", "Pack", "SwapRequest", ""): 1,
        ("open_swap", "Unpack", "SwapRequest", ""): 1,
        ("swap_asset_payment_mut", "MutBorrowField", "SwapRequest", "asset_payment"): 1,
        ("swap_quote_payment_mut", "MutBorrowField", "SwapRequest", "quote_payment"): 1,
        ("approve_swap", "MutBorrowField", "SwapRequest", "approval"): 1,
        ("asset_output_mut", "MutBorrowField", "Completion", "asset_output"): 1,
        ("quote_output_mut", "MutBorrowField", "Completion", "quote_output"): 1,
        ("approve_completion", "MutBorrowField", "Completion", "approval"): 1,
        ("finish", "Unpack", "Completion", ""): 1,
        ("approve", "MutBorrowField", "Approval", "is_approved"): 1,
    })
    for name in ("begin_add_liquidity", "begin_remove_liquidity", "begin_donate",
                 "new_swap_request", "approval_for_completion"):
        expected[(name, "Pack", "Approval", "")] = 1
    for name in ("settle_swap", "settle_add_liquidity", "settle_remove_liquidity", "settle_donate"):
        expected[(name, "Pack", "Completion", "")] = 1
    for name, fields in {
        "register_hook": {"hooks": 1},
        "lock": {"is_in_operation": 1},
        "finish": {"is_in_operation": 1},
        "add_hook_state": {"id": 1},
        "hook_state_mut": {"id": 1},
        "remove_hook_state": {"id": 1},
        "swap_fee_path": {"price_reference": 1},
        "settle_add_liquidity": {"curve": 1, "asset_reserve": 1, "quote_reserve": 1},
        "settle_remove_liquidity": {"curve": 1, "asset_reserve": 1, "quote_reserve": 1, "asset_fees": 1, "quote_fees": 1},
        "settle_swap": {"asset_reserve": 2, "quote_reserve": 2, "asset_fees": 1, "quote_fees": 1, "sqrt_price_x96": 1},
        "swap_amounts": {"curve": 4},
        "execute_donate": {"curve": 1, "asset_fees": 1, "quote_fees": 1},
    }.items():
        for field, count in fields.items():
            expected[(name, "MutBorrowField", "Pool", field)] = count
    for name, fees in (("settle_add_liquidity", 1), ("settle_remove_liquidity", 2)):
        expected[(name, "MutBorrowField", "Position", "fees")] = fees
        expected[(name, "MutBorrowField", "Position", "liquidity")] = 1

    require_effects(effects, expected, "pool")

    curve_module = price_module.with_name("curve.mv")
    curve = function_bodies(disassemble_module(curve_module, 0, "curve"), "curve")
    effects = field_effects(curve, "Curve|PositionFees")
    expected = Counter({("new", "Pack", "Curve", ""): 1, ("new_position_fees", "Pack", "PositionFees", ""): 1})
    for name, struct, fields in (
        ("change_liquidity", "PositionFees", {"checkpoint": 2, "owed_x128": 2}),
        ("take_fees", "PositionFees", {"owed_x128": 1}),
        ("change_liquidity", "Curve", {"liquidity": 1, "total_liquidity": 1}),
        ("credit", "Curve", {"growth": 2}),
        ("cross", "Curve", {"ticks": 1, "liquidity": 2, "index": 2}),
        ("move_inside", "Curve", {"index": 1}),
        ("change_tick", "Curve", {"ticks": 3}),
        ("set_initialized", "Curve", {"words": 1, "groups": 1, "group_index": 1}),
    ):
        for field, count in fields.items():
            expected[(name, "MutBorrowField", struct, field)] = count
    require_effects(effects, expected, "curve")
    for module in (pool_module, curve_module):
        print(f"PASS compiled {module.name} lifecycle and mutation sites, SHA-256 {sha256(module.read_bytes()).hexdigest()}",
              flush=True)
