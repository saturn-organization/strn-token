#!/usr/bin/env python3
"""Compare fresh gas measurements with the complete baseline without modifying it."""

import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def run(args, env):
    result = subprocess.run(
        args, cwd=ROOT, env=env, capture_output=True, text=True, check=True
    )
    return result.stdout


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"Duplicate snapshot key: {key}")
        result[key] = value
    return result


def snapshots(directory):
    result = {}
    for path in sorted(directory.rglob("*.json")):
        data = json.loads(path.read_text(), object_pairs_hook=unique_object)
        if not isinstance(data, dict) or not data:
            raise ValueError(f"Empty or invalid snapshot group: {path.name}")
        for name, value in data.items():
            if (
                not name
                or not isinstance(value, str)
                or re.fullmatch(r"[0-9]+", value) is None
            ):
                raise ValueError(f"Invalid snapshot measurement: {path.name}/{name}")
        result[path.relative_to(directory).as_posix()] = data
    return result


def main():
    env = os.environ.copy()
    configured = Path(json.loads(run(["forge", "config", "--json"], env))["snapshots"])
    baseline_directory = (ROOT / configured).resolve()
    baseline = snapshots(baseline_directory)
    with tempfile.TemporaryDirectory(prefix="strn-gas-check-") as directory:
        generated_directory = Path(directory).resolve()
        env["FOUNDRY_SNAPSHOTS"] = str(generated_directory)
        actual_directory = Path(
            json.loads(run(["forge", "config", "--json"], env))["snapshots"]
        )
        if (ROOT / actual_directory).resolve() != generated_directory:
            raise ValueError("Could not isolate generated gas snapshots")
        run(
            [
                "forge",
                "test",
                "--match-contract",
                "^(STRNGas|StakedSTRNGas)$",
                "--gas-snapshot-check",
                "false",
                "--gas-snapshot-emit",
                "true",
            ],
            env,
        )
        generated = snapshots(generated_directory)
        if not generated:
            raise ValueError("No gas snapshots generated; verification cannot pass")
        if baseline.keys() != generated.keys():
            missing = sorted(generated.keys() - baseline.keys())
            extra = sorted(baseline.keys() - generated.keys())
            raise ValueError(
                f"Gas snapshot files differ: missing={missing}, extra={extra}"
            )
        for file, actual in generated.items():
            expected = baseline[file]
            if expected.keys() != actual.keys():
                missing = sorted(actual.keys() - expected.keys())
                extra = sorted(expected.keys() - actual.keys())
                raise ValueError(
                    f"Gas snapshot entries differ in {file}: missing={missing}, extra={extra}"
                )
            for name, value in actual.items():
                if expected[name] != value:
                    raise ValueError(
                        f"Gas snapshot changed: {file}/{name}: {expected[name]} -> {value}"
                    )
    print(
        f"PASS: complete gas baseline matches ({len(generated)} files, "
        f"{sum(map(len, generated.values()))} measurements); baseline unchanged"
    )


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        print(error.stdout + error.stderr, file=sys.stderr)
        sys.exit(error.returncode or 1)
    except (ValueError, OSError) as error:
        print(f"Gas verification failed: {error}", file=sys.stderr)
        sys.exit(1)
