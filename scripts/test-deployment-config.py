#!/usr/bin/env python3
"""Configuration regression checks. All mutations stay in memory."""

import copy
import importlib.util
import json
from pathlib import Path
import sys
import unittest

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location(
    "deployment_config", Path(__file__).with_name("check-deployment-config.py")
)
config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(config)


class DeploymentConfigTests(unittest.TestCase):
    def setUp(self):
        # A dedicated fixture must not inherit approval or holder choices from the real manifest.
        self.draft = {
            "chainId": 1,
            "timelock": "0x" + "11" * 20,
            "proposer": "0x" + "22" * 20,
            "strn": {
                "approved": False,
                "allocationRecipient": None,
                "recoveryRecipient": None,
                "adminTransferDelaySeconds": None,
                "pauser": None,
                "unpauser": None,
                "blacklister": None,
                "seizer": None,
                "releaser": None,
                "parameterManager": "0x" + "11" * 20,
                "salt": None,
            },
            "staking": {
                "approved": False,
                "pauser": None,
                "unpauser": None,
                "seizer": None,
                "releaser": None,
                "durationSeconds": None,
                "adminTransferDelaySeconds": None,
                "salt": None,
            },
        }

    def complete(self):
        data = copy.deepcopy(self.draft)
        for section, fields in config.ADDRESS_FIELDS.items():
            data[section]["approved"] = True
            for field in fields:
                if data[section][field] is None:
                    data[section][field] = "0x" + "12" * 20
            data[section]["adminTransferDelaySeconds"] = (
                0  # Explicit zero is valid; null is not.
            )
            data[section]["salt"] = "0x" + ("ab" if section == "strn" else "cd") * 32
        data["staking"]["durationSeconds"] = 120 * 86400
        return data

    def test_unapproved_fixture_is_not_ready(self):
        config.validate(self.draft)
        for section in config.ADDRESS_FIELDS:
            with self.assertRaises(ValueError):
                config.validate(self.draft, section)

    def test_checked_in_manifest_matches_declared_state(self):
        actual = json.loads(
            config.DEFAULT.read_text(), object_pairs_hook=config.unique_object
        )
        config.validate(actual)
        for section in config.ADDRESS_FIELDS:
            if actual[section]["approved"]:
                config.validate(actual, section)
            else:
                with self.assertRaises(ValueError):
                    config.validate(actual, section)

    def test_approval_cannot_bypass_missing_fields(self):
        data = self.complete()
        for section in config.ADDRESS_FIELDS:
            for key in data[section]:
                if key == "approved":
                    continue
                broken = copy.deepcopy(data)
                broken[section][key] = None
                with (
                    self.subTest(section=section, key=key),
                    self.assertRaises(ValueError),
                ):
                    config.validate(broken, section)

    def test_complete_inputs_and_deliberate_shared_holders(self):
        data = self.complete()
        for section in config.ADDRESS_FIELDS:
            config.validate(data, section)

    def test_approval_is_separate_for_each_stage(self):
        data = self.complete()
        data["staking"] = self.draft["staking"]
        config.validate(data, "strn")
        with self.assertRaises(ValueError):
            config.validate(data, "staking")

    def test_rejects_invalid_inputs(self):
        cases = [
            (None, "chainId", 11155111),
            (None, "chainId", True),
            (None, "proposer", "0x" + "00" * 20),
            ("strn", "parameterManager", "0x" + "13" * 20),
            ("staking", "approved", "true"),
            ("staking", "durationSeconds", 0),
            ("staking", "durationSeconds", 366 * 86400),
            ("strn", "adminTransferDelaySeconds", -1),
            ("strn", "adminTransferDelaySeconds", True),
            ("strn", "adminTransferDelaySeconds", 2**48),
            ("staking", "releaser", "0x" + "00" * 20),
            ("strn", "salt", "0x" + "00" * 32),
            ("staking", "salt", "0x" + "ab" * 32),
        ]
        for section, key, value in cases:
            data = self.complete()
            (data[section] if section else data)[key] = value
            with (
                self.subTest(section=section, key=key, value=value),
                self.assertRaises(ValueError),
            ):
                config.validate(data)

    def test_rejects_unknown_and_duplicate_fields(self):
        data = self.complete()
        data["staking"]["releaseOperator"] = data["staking"]["releaser"]
        with self.assertRaises(ValueError):
            config.validate(data)
        with self.assertRaises(ValueError):
            config.unique_object([("approved", False), ("approved", True)])


if __name__ == "__main__":
    unittest.main()
