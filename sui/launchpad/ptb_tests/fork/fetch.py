#!/usr/bin/env python3
"""Snapshots the mainnet venue state the offline venue-fork tests run against.

Reads, never writes, the official Sui mainnet GraphQL endpoint and records at ONE checkpoint:

- every package the migrators' venue calls can load: Cetus CLMM, Cetus LP Burn, Bluefin Spot, and
  Circle USDC (the second Quote Cetus admits), closed over linkage tables and type origins (the
  VM resolves a type through the package that defined it, whose own linkage must resolve too);
- the shared objects the venue code reads (Cetus `GlobalConfig` and `Pools`, LP Burn's
  `BurnManager`, Bluefin's `GlobalConfig`, and mainnet's shared `Currency<SUI>`); and
- the dynamic fields that code reads under them, each located by its derived field ID: the Cetus
  pool list's tail node, the permission-pair manager and deny list with the SUI and USDC entries,
  and Bluefin's pool-creation fee table and SUI fee balance. A field that does not exist at the
  checkpoint is recorded as absent, so a later appearance is a visible diff.

Each object is stored as its full on-chain `Object` BCS, the file the simulator inserts verbatim
at the object's real ID. The script recomputes every object digest from those bytes, so a
snapshot that does not match the chain cannot be written. Output is deterministic: `snapshot/`
is rebuilt from nothing and `manifest.json` is sorted.

Run from `sui/launchpad/ptb_tests`:

    python3 fork/fetch.py                  # re-fetch at the pinned checkpoint
    python3 fork/fetch.py --checkpoint N   # refresh at checkpoint N (or `latest`)

After a refresh, set `CHECKPOINT` below to the checkpoint printed, then rerun the fork tests. A
fetch fails if a pinned venue lineage has a newer revision at the checkpoint: re-pin the migrators
first. Python standard library only.
"""

import argparse
import base64
import hashlib
import json
import shutil
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

# === Constants ===

ENDPOINT = "https://graphql.mainnet.sui.io/graphql"

# Genesis checkpoint digest of Sui mainnet.
CHAIN_IDENTIFIER = "4btiuiMPvEENsttpZC7CZ53DruC3MAgfznDbASZ7DR6S"

# The pinned checkpoint every committed fixture was read at.
CHECKPOINT = 326297561

OUT = Path(__file__).resolve().parent / "snapshot"

REQUEST_TIMEOUT_S = 60
REQUEST_ATTEMPTS = 3

# Venue packages the migrators link, as (name, original ID, pinned current ID, version).
VENUES = [
    ("cetus_clmm", "0x1eabed72c53feb3805120a081dc15963c204dc8d091542592abaf7a35689b2fb",
     "0x260693ec785a6e6c9d81d58c7d2ff72f1288ae0fa6a9725abe05a6478b11f084", 15),
    ("cetus_lp_burn", "0x12d73de9a6bc3cb658ec9dc0fe7de2662be1cea5c76c092fcc3606048cdbac27",
     "0xc4aabc874f5060d3147d8f74c14e3a8a1f9f8d92edea138a51635395ed167cd9", 8),
    ("bluefin_spot", "0x3492c874c1e3b3e2984e8c41b589e642d4d0a5d6459e5a9cfc2d52fd7c89c267",
     "0xd075338d105482f1527cbfd363d6413558f184dec36d9138a70261e87f486e9c", 17),
    ("usdc", "0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7",
     "0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7", 1),
]

CETUS_GLOBAL_CONFIG = "0xdaa46292632c3c4d8f31f23ea0f9b36a28ff3677e9684980e4438403a67a3d8f"
CETUS_POOLS = "0xf699e7f2276f5c9a75944b37a0c5b5d9ddfd2471bf6242483b03ab2887d198d0"
CETUS_BURN_MANAGER = "0x1d94aa32518d0cb00f9de6ed60d450c9a2090761f326752ffad06b2e9404f845"
BLUEFIN_GLOBAL_CONFIG = "0x03db251ba509a8d5d8777b6338836082335d93eecbdd09a11e190a1cff51c352"
SUI_CURRENCY = "0xf256d3fb6a50eaa748d94335b34f2982fbc3b63ceec78cafaa29ebc9ebaf2bbc"

# Type names as `type_name::with_defining_ids` renders them: no `0x`, 64 hex digits.
SUI_TYPE = "0000000000000000000000000000000000000000000000000000000000000002::sui::SUI"
USDC_TYPE = "dba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC"

FRAMEWORK = {f"0x{'0' * 63}{n}" for n in "123"}

BASE58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

# === GraphQL ===


def gql(query, variables):
    body = json.dumps({"query": query, "variables": variables}).encode()
    for attempt in range(1, REQUEST_ATTEMPTS + 1):
        request = urllib.request.Request(
            ENDPOINT, data=body, headers={"content-type": "application/json"})
        try:
            with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT_S) as response:
                data = json.load(response)
        except (urllib.error.URLError, TimeoutError) as error:
            is_server = isinstance(error, urllib.error.HTTPError) and error.code >= 500
            if attempt == REQUEST_ATTEMPTS or (
                    isinstance(error, urllib.error.HTTPError) and not is_server):
                raise
            time.sleep(attempt)
            continue
        if data.get("errors"):
            raise RuntimeError(f"GraphQL errors: {data['errors']}")
        return data["data"]


OBJECT_QUERY = """query($a: SuiAddress!, $c: UInt53) {
  object(address: $a, atCheckpoint: $c) {
    address version digest objectBcs
    asMoveObject { contents { type { repr } json } }
    asMovePackage { linkage { originalId upgradedId version } typeOrigins { definingId } }
  }
}"""


def fetch_object(address, checkpoint):
    """The object at `checkpoint`, or None when no version of it exists there."""
    found = gql(OBJECT_QUERY, {"a": address, "c": checkpoint})["object"]
    if found is None:
        return None
    raw = base64.b64decode(found["objectBcs"])
    if base58(hashlib.blake2b(b"Object::" + raw, digest_size=32).digest()) != found["digest"]:
        raise RuntimeError(f"{address}: object BCS does not hash to digest {found['digest']}")
    found["raw"] = raw
    return found


def base58(data):
    number = int.from_bytes(data, "big")
    text = ""
    while number:
        number, digit = divmod(number, 58)
        text = BASE58[digit] + text
    return "1" * (len(data) - len(data.lstrip(b"\0"))) + text

# === Dynamic field IDs ===


def uleb(value):
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        out.append(byte | (0x80 if value else 0))
        if not value:
            return bytes(out)


def address_bytes(address):
    return bytes.fromhex(address[2:].rjust(64, "0"))


def bcs_string(text):
    data = text.encode()
    return uleb(len(data)) + data


def struct_tag(address, module, name, params=()):
    """BCS of `TypeTag::Struct` (variant 7)."""
    return (bytes([7]) + address_bytes(address) + bcs_string(module) + bcs_string(name)
            + uleb(len(params)) + b"".join(params))


STRING = struct_tag("0x1", "string", "String")
TYPE_NAME = struct_tag("0x1", "type_name", "TypeName")
ID = struct_tag("0x2", "object", "ID")
DOF_STRING = struct_tag("0x2", "dynamic_object_field", "Wrapper", [STRING])


def field_id(parent, key_type, key_bcs):
    """`dynamic_field::hash_type_and_key`: Blake2b-256 over the derive-ID scope."""
    digest = hashlib.blake2b(digest_size=32)
    digest.update(bytes([0xF0]))
    digest.update(address_bytes(parent))
    digest.update(len(key_bcs).to_bytes(8, "little"))
    digest.update(key_bcs)
    digest.update(key_type)
    return "0x" + digest.hexdigest()

# === Snapshot ===


class Snapshot:
    def __init__(self, checkpoint):
        self.checkpoint = checkpoint
        self.packages = {}
        self.objects = {}
        self.absent = {}

    def package(self, address, role):
        if address in self.packages or address in FRAMEWORK:
            return None
        found = fetch_object(address, self.checkpoint)
        if found is None or found["asMovePackage"] is None:
            raise RuntimeError(f"package {address} is missing at checkpoint {self.checkpoint}")
        self.packages[address] = {"role": role, **found}
        return found["asMovePackage"]

    def object(self, name, address, expected_type):
        found = fetch_object(address, self.checkpoint)
        if found is None:
            raise RuntimeError(f"{name} ({address}) is missing at checkpoint {self.checkpoint}")
        repr_ = found["asMoveObject"]["contents"]["type"]["repr"]
        if expected_type not in repr_:
            raise RuntimeError(f"{name} ({address}) has type {repr_}, expected {expected_type}")
        self.objects[name] = found
        return found["asMoveObject"]["contents"]["json"]

    def field(self, name, parent, key_type, key_bcs, expected_type, required=True):
        address = field_id(parent, key_type, key_bcs)
        found = fetch_object(address, self.checkpoint)
        if found is None:
            if required:
                raise RuntimeError(f"required field {name} ({address}) is absent")
            self.absent[name] = address
            return None
        return self.object(name, address, expected_type)


def fetch(checkpoint):
    snapshot = Snapshot(checkpoint)

    # Packages: each venue's pinned revision must still be its lineage tip at the checkpoint.
    for name, original, current, version in VENUES:
        tip = gql("query($a: SuiAddress!, $c: UInt53) { package(address: $a, atCheckpoint: $c)"
                  " { address version } }", {"a": original, "c": checkpoint})["package"]
        if tip is None or (tip["address"], tip["version"]) != (current, version):
            raise RuntimeError(f"{name}: lineage tip at {checkpoint} is {tip}, pinned "
                               f"{current} v{version}; re-pin the migrators first")
        # The closure over linkage and type origins: loading a type goes through the package that
        # defined it, and that package's linkage must resolve too.
        pending = [(current, f"{name} v{version}")]
        while pending:
            address, role = pending.pop()
            package = snapshot.package(address, role)
            if package is None:
                continue
            for origin in sorted({origin["definingId"] for origin in package["typeOrigins"]}):
                pending.append((origin, f"defines types used by {name}"))
            for link in package["linkage"]:
                pending.append((link["upgradedId"], f"linked by {name}: {link['originalId']}"))

    # Cetus: configuration, the pool registry, its list tail, and the permission and deny lists.
    snapshot.object("cetus_global_config", CETUS_GLOBAL_CONFIG, "::config::GlobalConfig")
    pools = snapshot.object("cetus_pools", CETUS_POOLS, "::factory::Pools")
    snapshot.field("cetus_pools_list_tail", pools["list"]["id"], ID,
                   address_bytes(pools["list"]["tail"]), "::linked_table::Node<")
    for key, name, child_type in [
        ("permission_pair_manager", "cetus_permission_pair_manager",
         "::factory::PermissionPairManager"),
        ("deny_coin_list", "cetus_deny_coin_list", "::factory::DenyCoinList"),
    ]:
        field = snapshot.field(f"{name}_field", pools["id"], DOF_STRING, bcs_string(key),
                               "::dynamic_object_field::Wrapper<")
        snapshot.object(name, field["value"], child_type)
    manager = snapshot.objects["cetus_permission_pair_manager"]["asMoveObject"]["contents"]["json"]
    deny = snapshot.objects["cetus_deny_coin_list"]["asMoveObject"]["contents"]["json"]
    for quote, type_name in [("sui", SUI_TYPE), ("usdc", USDC_TYPE)]:
        key = bcs_string(type_name)
        pair = snapshot.field(f"cetus_allowed_pair_config_{quote}",
                              manager["allowed_pair_config"]["id"], TYPE_NAME, key, "VecSet<u32>")
        if 200 not in pair["value"]["contents"]:
            raise RuntimeError(f"Cetus no longer admits {quote} at tick spacing 200")
        for table in ["allowed_list", "denied_list"]:
            snapshot.field(f"cetus_deny_coin_list_{table}_{quote}", deny[table]["id"], TYPE_NAME,
                           key, "bool>", required=False)

    snapshot.object("cetus_burn_manager", CETUS_BURN_MANAGER, "::lp_burn::BurnManager")

    # Bluefin: configuration, its pool-creation fee table entry for SUI, and the SUI fee balance.
    snapshot.object("bluefin_global_config", BLUEFIN_GLOBAL_CONFIG, "::config::GlobalConfig")
    fee_table = snapshot.field("bluefin_pool_creation_fee_table", BLUEFIN_GLOBAL_CONFIG, STRING,
                               bcs_string("pool_creation_fee"), "::table::Table<")
    snapshot.field("bluefin_pool_creation_fee_sui", fee_table["value"]["id"], STRING,
                   bcs_string(SUI_TYPE), "u64>")
    snapshot.field("bluefin_pool_creation_fee_balance_sui", BLUEFIN_GLOBAL_CONFIG, STRING,
                   bcs_string(SUI_TYPE), "::balance::Balance<", required=False)

    snapshot.object("sui_currency", SUI_CURRENCY, "::coin_registry::Currency<")

    return snapshot


def write(snapshot, timestamp):
    if OUT.exists():
        shutil.rmtree(OUT)
    (OUT / "packages").mkdir(parents=True)
    (OUT / "objects").mkdir()
    packages = []
    for address, found in sorted(snapshot.packages.items()):
        path = f"packages/{address}.bcs"
        (OUT / path).write_bytes(found["raw"])
        packages.append({"id": address, "version": found["version"], "digest": found["digest"],
                         "role": found["role"], "file": path, "bytes": len(found["raw"])})
    objects = []
    for name, found in sorted(snapshot.objects.items()):
        path = f"objects/{name}.bcs"
        (OUT / path).write_bytes(found["raw"])
        objects.append({"name": name, "id": found["address"], "version": found["version"],
                        "digest": found["digest"],
                        "type": found["asMoveObject"]["contents"]["type"]["repr"],
                        "file": path, "bytes": len(found["raw"])})
    manifest = {
        "network": "mainnet",
        "chain_identifier": CHAIN_IDENTIFIER,
        "checkpoint": snapshot.checkpoint,
        "checkpoint_timestamp": timestamp,
        "packages": packages,
        "objects": objects,
        "absent_fields": [{"name": name, "id": address}
                          for name, address in sorted(snapshot.absent.items())],
    }
    (OUT / "manifest.json").write_text(json.dumps(manifest, indent=1, sort_keys=True) + "\n")
    total = sum(entry["bytes"] for entry in packages + objects)
    print(f"checkpoint {snapshot.checkpoint} ({timestamp}): {len(packages)} packages, "
          f"{len(objects)} objects, {len(snapshot.absent)} absent fields, {total} bytes")


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--checkpoint", default=str(CHECKPOINT),
                        help="checkpoint sequence number, or `latest`")
    args = parser.parse_args()

    if gql("{ chainIdentifier }", {})["chainIdentifier"] != CHAIN_IDENTIFIER:
        sys.exit("endpoint is not Sui mainnet")
    if args.checkpoint == "latest":
        checkpoint = gql("{ checkpoint { sequenceNumber } }", {})["checkpoint"]["sequenceNumber"]
    else:
        checkpoint = int(args.checkpoint)
    found = gql("query($c: UInt53) { checkpoint(sequenceNumber: $c) { timestamp } }",
                {"c": checkpoint})["checkpoint"]
    if found is None:
        sys.exit(f"checkpoint {checkpoint} is not available")

    write(fetch(checkpoint), found["timestamp"])
    if checkpoint != CHECKPOINT:
        print(f"set CHECKPOINT = {checkpoint} in {Path(__file__).name}")


if __name__ == "__main__":
    main()
