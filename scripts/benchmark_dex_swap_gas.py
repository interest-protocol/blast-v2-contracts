#!/usr/bin/env python3
"""Measure full continuous-fee swap PTBs on a disposable funded Sui localnet."""
import argparse
import json
from pathlib import Path
import re
import subprocess
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[1]
Q96 = 1 << 96
LIQUIDITY = 1 << 54
BUDGET = 10**16
GAS_BUDGET = 10**10
TICK_MATH = ROOT / "scratch-sui/dex/sources/curve/tick_math.move"
FACTORS = [int(factor, 16) for factor in re.findall(r"0x[0-9a-f]+", TICK_MATH.read_text())]


def price(tick):
    ratio = 1 << 128
    for bit, factor in enumerate(FACTORS):
        if abs(tick) & (1 << bit):
            ratio = ratio * factor >> 128
    if tick > 0:
        ratio = ((1 << 256) - 1) // ratio
    return (ratio + (1 << 32) - 1) >> 32


def ceil_div(numerator, denominator):
    return (numerator + denominator - 1) // denominator


def call(target, *args):
    return ["--move-call", target, *map(str, args)]


def assign(name):
    return ["--assign", name]


class Localnet:
    def __init__(self, artifacts, binary, grpcurl, gas_price):
        self.artifacts = artifacts
        config = artifacts / "client.yaml"
        # Only allow a loopback RPC for the explicit benchmark environment.
        rpc = re.search(r'alias: "?dex-local"?\s+rpc: "?(https?://[^"\s]+)', config.read_text())
        if not rpc or not re.fullmatch(r"http://(?:127\.0\.0\.1|localhost):[0-9]+", rpc[1]):
            raise SystemExit("dex-local must point to a disposable loopback Sui network")
        self.rpc = rpc[1]
        self.grpcurl = grpcurl
        self.gas_price = gas_price
        self.cli = [binary, "client", "--client.config", str(config), "--client.env", "dex-local"]
        self.dex = self.package("dex")
        self.asset = self.package("token") + "::token::TOKEN"
        self.quote = "0x2::sui::SUI"
        self.treasury = self.object("token", "::coin::TreasuryCap")
        self.version = self.object("wrap", "::package_version::PackageVersion")
        self.tiers = self.object("dex", "::lp_fee::BlastDexFeeTiers")
        self.owner = "@" + subprocess.check_output(self.cli + ["active-address"], text=True).strip()
        gas_coins = json.loads(subprocess.check_output(self.cli + ["--json", "gas"], text=True))["gasCoins"]
        self.gas = "@" + max(gas_coins, key=lambda coin: int(coin["mistBalance"]))["gasCoinId"]

    def read(self, name):
        return json.loads((self.artifacts / f"{name}.json").read_text())

    def package(self, name):
        return next(row["packageId"] for row in self.read(name)["objectChanges"] if row["type"] == "published")

    def object(self, name, kind):
        return "@" + next(row["objectId"] for row in self.read(name)["objectChanges"]
                          if row["type"] == "created" and kind in row["objectType"])

    def run(self, name, commands, *, dry_run=False):
        path = self.artifacts / f"{name}.json"
        if path.exists():
            return self.read(name)
        flags = ["--serialize-unsigned-transaction"] if dry_run else []
        result = subprocess.run(self.cli + ["ptb", "--gas-budget", str(GAS_BUDGET), "--gas-price", str(self.gas_price),
                                            "--gas-coin", self.gas] + flags + commands,
                                text=True, capture_output=True)
        if result.returncode:
            raise RuntimeError(f"{name}: {result.stdout}\n{result.stderr}")
        if dry_run and self.grpcurl:
            request = {
                "transaction": {"bcs": {"value": result.stdout.strip()}},
                "readMask": {"paths": ["transaction.effects", "transaction.events"]},
                "checks": "ENABLED",
            }
            raw = subprocess.check_output(
                [self.grpcurl, "-plaintext", "-max-time", "30", "-d", "@", self.rpc.removeprefix("http://"),
                 "sui.rpc.v2.TransactionExecutionService/SimulateTransaction"],
                input=json.dumps(request), text=True,
            )
            transaction = json.loads(raw)["transaction"]
            effects = transaction["effects"]
            success = effects["status"]["success"]
            record = {
                "effects": {
                    "status": {"status": "success"} if success else {"status": "failure", **effects["status"]},
                    "gasUsed": effects["gasUsed"],
                    "mutated": [row for row in effects.get("changedObjects", ()) if row.get("idOperation") == "NONE"
                                and row.get("outputState") == "OUTPUT_OBJECT_STATE_OBJECT_WRITE"],
                },
                "events": [{"type": row["eventType"], "parsedJson": row["json"]}
                           for row in transaction.get("events", {}).get("events", ())],
            }
        elif dry_run:
            request = Request(self.rpc, headers={"Content-Type": "application/json"}, data=json.dumps({
                "jsonrpc": "2.0", "id": 1, "method": "sui_dryRunTransactionBlock",
                "params": [result.stdout.strip()],
            }).encode())
            with urlopen(request, timeout=30) as response:
                payload = json.load(response)
            if "error" in payload:
                raise RuntimeError((name, payload["error"]))
            record = payload["result"]
        else:
            digest = result.stdout.splitlines()[0].split()[-1]
            record = json.loads(subprocess.check_output(self.cli + ["--json", "tx-block", digest], text=True))
        path.write_text(json.dumps(record) + "\n")
        return record

    def pool(self, function, *args):
        return call(f"{self.dex}::pool::{function}", f"<{self.asset},{self.quote}>", *args)

    def finish(self, operation, pool, completion, minimum_asset=0, minimum_quote=0):
        return call(f"{self.dex}::pool::finish", f"<{self.asset},{self.quote},{self.dex}::pool::{operation}>",
                    pool, self.version, completion, minimum_asset, minimum_quote)

    def mint(self, amount):
        return call("0x2::coin::mint", f"<{self.asset}>", self.treasury, amount)

    def create(self, name, start, base, maximum, sensitivity):
        self.run(name,
                 call(f"{self.dex}::lp_fee::new_dynamic", self.tiers, base, maximum, sensitivity) + assign("fee")
                 + self.pool("new", self.version, 1, "fee", f"{price(start)}u256") + assign("init")
                 + self.pool("finalize", "init", self.version) + assign("pool")
                 + self.pool("share", "pool", self.version))
        return self.object(name, "::pool::Pool")

    def add(self, target, name, initial, lower, upper, liquidity):
        def tick(value):
            fn = "neg_from_u32" if value < 0 else "from_u32"
            return call(f"{self.dex}::i32::{fn}", abs(value))

        low = price(lower)
        high = price(upper)
        spot = min(max(price(initial), low), high)
        asset = ceil_div(liquidity * Q96 * (high - spot), spot * high)
        quote = ceil_div(liquidity * (spot - low), Q96)

        def n(field):
            return f"{field}_{name}"

        return (tick(lower) + assign(n("lower")) + tick(upper) + assign(n("upper"))
                + self.pool("new_position", target, self.version, n("lower"), n("upper")) + assign(n("position"))
                + self.mint(asset) + assign(n("asset"))
                + ["--split-coins", "gas", f"[{quote}]"] + assign(n("quote"))
                + self.pool("begin_add_liquidity", target, self.version, n("position"),
                            liquidity, n("asset"), n("quote") + ".0") + assign(n("request"))
                + self.pool("execute_add_liquidity", target, self.version, n("request"), n("position"))
                + assign(n("completion")) + self.finish("AddLiquidity", target, n("completion"))
                + assign(n("refund"))
                + ["--transfer-objects", f'[{n("position")},{n("refund")}.0,{n("refund")}.1]', self.owner])

    def swap(self, target, name, up, limit, budget, *, dry_run=True):
        payment = ["--split-coins", "gas", f"[{budget}]"] if up else self.mint(budget)
        coin = "payment.0" if up else "payment"
        begin = "begin_swap_quote_to_asset" if up else "begin_swap_asset_to_quote"
        return self.run(name, payment + assign("payment")
                        + self.pool(begin, target, self.version, coin, f"{price(limit)}u256")
                        + assign("request") + self.pool("execute_swap", target, self.version, "request", "@0x6")
                        + assign("completion") + self.finish("Swap", target, "completion", int(up), int(not up))
                        + assign("coins") + ["--transfer-objects", "[coins.0,coins.1]", self.owner],
                        dry_run=dry_run)


def measure(record, name, expected, budget, gas_price):
    effects = record["effects"]
    result = {
        "case": name,
        "status": effects["status"],
        "input_budget": budget,
        "gas_price_mist": gas_price,
        **{field: int(effects["gasUsed"].get(field, 0)) for field in
           ("computationCost", "storageCost", "storageRebate", "nonRefundableStorageFee")},
    }
    result["computation_units"] = result["computationCost"] // gas_price
    result["net_gas_mist"] = result["computationCost"] + result["storageCost"] - result["storageRebate"]
    if effects["status"]["status"] != "success":
        raise RuntimeError(result)
    event = next(row["parsedJson"] for row in record["events"] if row["type"].endswith("::Swapped"))
    result.update({field: int(event[field]) for field in
                   ("sqrt_price_after_x96", "input_spent", "lp_fee_amount", "output_amount")})
    result["mutated_objects"] = len(effects.get("mutated", ()))
    if isinstance(expected, tuple):
        assert min(expected) < result["sqrt_price_after_x96"] < max(expected), result
    else:
        assert result["sqrt_price_after_x96"] == expected, result
    if name.endswith("_cap"):
        assert result["input_spent"] < budget, result
    print(json.dumps(result), flush=True)
    return result


def run_fixture(local, layout, up, gas_price):
    sign = 1 if up else -1
    name = f"{layout}_{'up' if up else 'down'}"
    origin = -100_000 if layout == "large" else 0
    start = origin
    cap_budget = 10**19 if layout == "large" else BUDGET
    fee = (1000, 100_000, 100_000)
    if layout == "gaps":
        width = 1
        first = 256
        spacing = 2048
        intervals = [tuple(sorted((sign * (first + i * spacing), sign * (first + i * spacing + width))))
                     + (10**10,) for i in range(64)]
        boundaries = [sign * (first + i * spacing + offset) for i in range(64) for offset in (0, width)]
    else:
        start = sign * (5800 if up else 51_000) if layout == "shoulder" else 0
        if layout in ("wide", "large"):
            start = origin - sign * 1920
        spacing = 1 if layout == "dense" else 8
        if layout == "span":
            spacing = 52 if up else 405
        boundaries = [start + sign * spacing * i for i in range(1, 129)]
        if layout in ("wide", "large"):
            boundaries[-1] = origin + (9000 if up else -56_000)
        outer = boundaries[-1] + sign * 64
        liquidity = LIQUIDITY
        if layout == "shoulder":
            liquidity = 1 << (53 if up else 47)
        if layout in ("wide", "span"):
            liquidity = 1 << (53 if up else 48)
        if layout == "large":
            liquidity = 1 << 51
        intervals = [(min(origin - 64, start - 64, outer), max(origin + 64, start + 64, outer), liquidity)]
        intervals += [tuple(sorted((tick, outer))) + (1,) for tick in boundaries]

    target = local.create(name + "_pool", origin, *fee)
    for batch in range(0, len(intervals), 12):
        commands = []
        for offset, (lower, upper, liquidity) in enumerate(intervals[batch:batch + 12]):
            commands += local.add(target, str(offset), origin, lower, upper, liquidity)
        record = local.run(f"{name}_fund_{batch}", commands)
        if record["effects"]["status"]["status"] != "success":
            raise RuntimeError((name, batch, record["effects"]["status"]))
    if start != origin:
        warm = local.swap(target, name + "_warm", start > origin, start, BUDGET, dry_run=False)
        measure(warm, name + "_warm", price(start), BUDGET, gas_price)

    limit = boundaries[-1] + sign * spacing
    cap = local.swap(target, name + "_cap", up, limit, cap_budget)
    row = measure(cap, name + "_cap", price(boundaries[-1]), cap_budget, gas_price)
    if layout == "gaps":
        return

    boundary = local.swap(target, name + "_boundary", up, boundaries[-2], cap_budget)
    previous = measure(boundary, name + "_boundary", price(boundaries[-2]), cap_budget, gas_price)
    delta = row["input_spent"] - previous["input_spent"]
    # Make the 128th step use the exact-input inverse within its price range.
    fractions = (1, 2, 3) if layout in ("wide", "span", "large") else (2,)
    for numerator in fractions:
        budget = previous["input_spent"] + delta * numerator // 4
        case = name + ("_terminal" if numerator == 2 else f"_terminal_{numerator}of4")
        terminal = local.swap(target, case, up, limit, budget)
        measure(terminal, case, (price(boundaries[-2]), price(boundaries[-1])), budget, gas_price)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("artifacts", type=Path, help="local client config and admin bootstrap PTB JSON")
    parser.add_argument("--sui", default="sui")
    parser.add_argument("--grpcurl", help="use gRPC simulation on a current Sui localnet")
    parser.add_argument("--gas-price", type=int, required=True, help="local reference gas price in MIST")
    layouts = ("dense", "shoulder", "wide", "span", "gaps", "large")
    parser.add_argument("--layout", choices=layouts, action="append")
    parser.add_argument("--direction", choices=("up", "down"), action="append")
    args = parser.parse_args()
    local = Localnet(args.artifacts, args.sui, args.grpcurl, args.gas_price)
    for layout in args.layout or layouts:
        for direction in args.direction or (("down",) if layout == "large" else ("up", "down")):
            if layout == "large" and direction == "up":
                continue
            run_fixture(local, layout, direction == "up", args.gas_price)


if __name__ == "__main__":
    main()
