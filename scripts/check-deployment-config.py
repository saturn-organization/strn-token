#!/usr/bin/env python3
"""Validate the Ethereum draft or require approved inputs. Never deploys or broadcasts."""

import argparse
import json
from pathlib import Path
import re
import sys

DEFAULT = Path(__file__).resolve().parents[1] / "config" / "ethereum.json"
ADDRESS = re.compile(r"0x[0-9a-fA-F]{40}\Z")
SALT = re.compile(r"0x[0-9a-fA-F]{64}\Z")
ADDRESS_FIELDS = {
    "strn": (
        "allocationRecipient",
        "recoveryRecipient",
        "pauser",
        "unpauser",
        "blacklister",
        "seizer",
        "parameterManager",
        "releaser",
    ),
    "staking": ("pauser", "unpauser", "seizer", "releaser"),
}


def address(value):
    return isinstance(value, str) and ADDRESS.fullmatch(value) and int(value, 16) != 0


def validate(data, ready=None):
    """Drafts permit null required inputs; readiness permits none in the selected section."""
    if not isinstance(data, dict) or set(data) != {
        "chainId",
        "timelock",
        "proposer",
        "strn",
        "staking",
    }:
        raise ValueError("Unexpected top-level fields")
    if type(data["chainId"]) is not int or data["chainId"] != 1:
        raise ValueError("Ethereum configuration requires chainId 1")
    for key in ("timelock", "proposer"):
        if not address(data[key]):
            raise ValueError(f"Invalid {key}")
    for section, fields in ADDRESS_FIELDS.items():
        values = data[section]
        numbers = {"adminTransferDelaySeconds": (0, 2**48 - 1)}
        if section == "staking":
            numbers["durationSeconds"] = (86400, 365 * 86400)
        expected = set(fields) | set(numbers) | {"approved", "salt"}
        if not isinstance(values, dict) or set(values) != expected:
            raise ValueError(f"Unexpected {section} fields")
        if type(values["approved"]) is not bool:
            raise ValueError(f"{section}.approved must be boolean")
        required = ready == section or values["approved"]
        if ready == section and not values["approved"]:
            raise ValueError(f"{section} is not approved")
        for field in fields:
            value = values[field]
            if value is None and not required:
                continue
            if not address(value):
                raise ValueError(f"Missing or invalid {section}.{field}")
        manager = values.get("parameterManager")
        if section == "strn" and (
            not address(manager) or manager.lower() != data["timelock"].lower()
        ):
            raise ValueError("STRN parameterManager must equal timelock")
        for field, (low, high) in numbers.items():
            value = values[field]
            if value is None and not required:
                continue
            if type(value) is not int or not low <= value <= high:
                raise ValueError(f"Missing or invalid {section}.{field}")
        salt = values["salt"]
        if not (salt is None and not required):
            if (
                not isinstance(salt, str)
                or not SALT.fullmatch(salt)
                or int(salt, 16) == 0
            ):
                raise ValueError(f"Missing or invalid {section}.salt")
    salts = [data[s]["salt"] for s in ADDRESS_FIELDS]
    if all(salts) and salts[0].lower() == salts[1].lower():
        raise ValueError("Use distinct reviewed salts for the two role batches")


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"Duplicate field: {key}")
        result[key] = value
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=DEFAULT)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check-draft", action="store_true")
    mode.add_argument("--ready", choices=tuple(ADDRESS_FIELDS))
    args = parser.parse_args()
    try:
        data = json.loads(args.config.read_text(), object_pairs_hook=unique_object)
        validate(data, args.ready)
    except (ValueError, OSError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print(
        "PASS: draft structure only; not deployment approval"
        if args.check_draft
        else f"PASS: approved {args.ready} inputs are complete; live chain and authority checks remain required"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
