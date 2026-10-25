#!/usr/bin/env python3
"""Compile the real adapter with each fill proof omitted, in an isolated copy.

Run under the host's heavy-job guard. The unchanged package must compile;
each omission must fail specifically because FillReceipt cannot be dropped.
"""
import argparse
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


PACKAGE = Path(__file__).resolve().parents[1]
REPO = PACKAGE.parents[2]
CALLERS = ("fill_orders", "rebalance_orders", "close_orders", "fill_exact_order")


def copy_packages(target):
    for relative in ("sui/admin", "sui/partners", "sui/boosts/core", "sui/boosts/aftermath_adapter"):
        shutil.copytree(
            REPO / relative, target / relative,
            ignore=shutil.ignore_patterns("build", "node_modules", ".git", "__pycache__"),
        )
    return target / "sui/boosts/aftermath_adapter"


def compile_package(package):
    return subprocess.run(
        ["sui", "move", "build", "--path", str(package), "--build-env", "mainnet"],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
    )


def omit_proof(source, caller):
    start = source.index(f"fun {caller}<")
    end = source.index("\n}\n", start)
    body = source[start:end]
    # Read the same amounts without consuming the receipt. This keeps all
    # variables defined, so only the missing consumption breaks compilation.
    body, count = re.subn(
        r"receipt\.proven_fill\([^;]+\)",
        "(receipt.filled, receipt.filled_quote)", body,
    )
    assert count == 1, f"Expected one consuming proof in {caller}, got {count}"
    return source[:start] + body + source[end:]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log-dir", type=Path, help="Keep complete compiler output for each case")
    args = parser.parse_args()
    if args.log_dir:
        args.log_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="boosts-a5-") as temporary:
        package = copy_packages(Path(temporary))
        path = package / "sources/orders.move"
        source = path.read_text()
        for caller in (None, *CALLERS):
            name = caller or "control"
            path.write_text(omit_proof(source, caller) if caller else source)
            result = compile_package(package)
            output = re.sub(r"\x1b\[[0-9;]*m", "", result.stdout)
            if args.log_dir:
                (args.log_dir / f"{name}.log").write_text(output)
            if caller is None:
                assert result.returncode == 0, f"Unchanged control failed:\n{output}"
                print("PASS: unchanged adapter compiles", flush=True)
            else:
                assert result.returncode != 0, f"Omitting {caller}'s proof compiled"
                assert "error[EC06001]: unused value without 'drop'" in output, output
                assert "'blast_boosts_aftermath::orders::FillReceipt' does not have the ability 'drop'" in output, output
                print(f"PASS: {caller} omission rejected for non-droppable FillReceipt", flush=True)


if __name__ == "__main__":
    main()
