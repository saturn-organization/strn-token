#!/usr/bin/env python3
"""Exercise complete gas comparison and deliberate updates using disposable baselines."""

import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
baseline = {
    p.relative_to(ROOT / "snapshots").as_posix(): p.read_bytes()
    for p in (ROOT / "snapshots").rglob("*.json")
}
expected = json.loads(baseline["STRN.json"])


def run(args, env):
    return subprocess.run(
        args, cwd=ROOT, env=env, capture_output=True, text=True, timeout=60
    )


def files(directory):
    return {
        p.relative_to(directory).as_posix(): p.read_bytes()
        for p in directory.rglob("*.json")
    }


for case in [
    "valid",
    "changed-value",
    "missing-key",
    "missing-file",
    "extra-key",
    "extra-file",
    "missing-directory",
    "malformed-json",
    "duplicate-key",
]:
    with tempfile.TemporaryDirectory(prefix="strn-gas-regression-") as directory:
        root = Path(directory)
        for name, contents in baseline.items():
            (root / name).parent.mkdir(parents=True, exist_ok=True)
            (root / name).write_bytes(contents)
        destination = root / "STRN.json"
        data = dict(expected)
        if case == "changed-value":
            data["approve"] = "1"
        elif case == "missing-key":
            del data["approve"]
        elif case == "extra-key":
            data["obsolete_measurement"] = "1"
        destination.write_text(json.dumps(data))
        if case == "missing-file":
            destination.unlink()
        elif case == "extra-file":
            (root / "obsolete.json").write_text('{"obsolete": "1"}')
        elif case == "missing-directory":
            for path in root.rglob("*.json"):
                path.unlink()
            root.rmdir()
        elif case == "malformed-json":
            destination.write_text("{")
        elif case == "duplicate-key":
            destination.write_text('{"approve": "1", "approve": "57407"}')
        original = files(root)
        env = os.environ.copy()
        env["FOUNDRY_SNAPSHOTS"] = directory

        # Exercise actual verification-script wiring for a bad baseline; valid runs use its checker directly.
        command = (
            ["bash", "scripts/verify.sh"]
            if case == "changed-value"
            else ["python3", "scripts/check-gas.py"]
        )
        result = run(command, env)
        output = result.stdout + result.stderr
        assert (result.returncode == 0) == (case == "valid"), (case, output)
        if case != "valid":
            assert "Gas verification failed:" in output, (case, output)
        assert files(root) == original, f"{case}: verification altered baseline"
        print(
            f"PASS: {case} {'accepted' if case == 'valid' else 'rejected'}; baseline unchanged"
        )

        if case == "changed-value":
            ordinary = run(
                ["forge", "test", "--offline", "--match-contract", "STRNGas", "-q"], env
            )
            assert ordinary.returncode == 0, ordinary.stdout + ordinary.stderr
            assert files(root) == original, "Ordinary tests overwrote baseline"
            update = run(["bash", "scripts/update-gas.sh"], env)
            assert update.returncode == 0, update.stdout + update.stderr
            assert json.loads(destination.read_text()) == expected
            check = run(["python3", "scripts/check-gas.py"], env)
            assert check.returncode == 0, check.stdout + check.stderr
            print(
                "PASS: ordinary tests preserve baseline; explicit update restores passing comparison"
            )

assert files(ROOT / "snapshots") == baseline, "Repository baseline was modified"
