#!/usr/bin/env python3
"""Generate local audit evidence tied to a clean source commit. Never publishes."""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def output(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()


def export_build(bundle, name="STRN", prefix=""):
    # Capture the normal build before coverage replaces its artifacts.
    artifact = json.loads((ROOT / f"out/{name}.sol/{name}.json").read_text())
    for path in sorted((ROOT / "out/build-info").glob("*.json")):
        build = json.loads(path.read_text())
        contract = (
            build.get("output", {})
            .get("contracts", {})
            .get(f"src/{name}.sol", {})
            .get(name, {})
        )
        evm = contract.get("evm", {})
        if all(
            evm.get(key, {}).get("object") == artifact[key]["object"].removeprefix("0x")
            for key in ["bytecode", "deployedBytecode"]
        ):
            # Foundry build-info also stores adapter fields (paths/version) that
            # are not accepted by solc's standard-JSON interface.
            compiler_input = {
                key: build["input"][key] for key in ["language", "sources", "settings"]
            }
            (bundle / f"{prefix}compiler-input.json").write_text(
                json.dumps(compiler_input, indent=2) + "\n"
            )
            break
    else:
        raise RuntimeError(
            f"No compiler input matches the normal {name} build artifact."
        )
    bytecode = {}
    for name, key in [("creation", "bytecode"), ("runtime", "deployedBytecode")]:
        hex_data = artifact[key]["object"].removeprefix("0x")
        data = bytes.fromhex(hex_data)
        bytecode[name] = {
            "object": hex_data,
            "bytes": len(data),
            "sha256": hashlib.sha256(data).hexdigest(),
        }
    (bundle / f"{prefix}bytecode.json").write_text(
        json.dumps(bytecode, indent=2) + "\n"
    )


def main():
    os.chdir(ROOT)
    if output("git", "status", "--porcelain", "--untracked-files=all"):
        raise SystemExit("Commit the reviewed changes before packaging audit evidence.")
    commit = output("git", "rev-parse", "HEAD")
    submodules = output("git", "submodule", "status")
    if any(line.startswith(("-", "+", "U")) for line in submodules.splitlines()):
        raise SystemExit("Initialize submodules at their pinned commits first.")
    base = ROOT / "artifacts"
    base.mkdir(exist_ok=True)
    bundle = Path(tempfile.mkdtemp(prefix=f"audit-{commit[:12]}-", dir=base))
    env = dict(os.environ, STRN_EVIDENCE_DIR=str(bundle))
    commands = []

    def run(name, args, allowed=(0,), extra_env=None):
        with (bundle / name).open("w") as log:
            result = subprocess.run(
                args,
                cwd=ROOT,
                env=env | (extra_env or {}),
                stdout=log,
                stderr=subprocess.STDOUT,
            )
        commands.append({"log": name, "command": args, "exit_code": result.returncode})
        if result.returncode not in allowed:
            raise RuntimeError(f"{name} failed; inspect the local evidence directory.")

    try:
        versions = {
            name: output(name, "--version")
            for name in ["forge", "node", "npm", "python3", "slither"]
        }
        solc = os.environ.get("STRN_SOLC", "solc")
        versions["solc"] = output(solc, "--version")
        run("formatting.txt", ["npm", "run", "format:check"])
        run("verification.txt", ["bash", "scripts/verify.sh"])
        export_build(bundle)
        export_build(bundle, "StakedSTRN", "staking-")
        run("gas-guard.txt", ["python3", "scripts/test-gas-verification.py"])
        run(
            "coverage.txt",
            [
                "forge",
                "coverage",
                "--no-match-contract",
                "STRNInvariant|CombinedSTRNVotesInvariant",
                "--fuzz-runs",
                "256",
                "--report",
                "summary",
                "--report",
                "lcov",
                "--report-file",
                str(bundle / "lcov.info"),
            ],
        )
        for target, prefix in [
            ("script/DeploySTRN.s.sol", ""),
            ("script/DeployStakedSTRN.s.sol", "staking-"),
        ]:
            run(
                prefix + "slither.txt",
                [
                    "slither",
                    target,
                    "--compile-force-framework",
                    "solc",
                    "--solc",
                    solc,
                    "--solc-remaps",
                    "@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/ @openzeppelin/contracts-upgradeable/=lib/openzeppelin-contracts-upgradeable/contracts/",
                    "--solc-args",
                    "--optimize --optimize-runs 200 --via-ir --evm-version cancun",
                    "--filter-paths",
                    "lib/",
                    "--json",
                    str(bundle / (prefix + "slither.json")),
                ],
                allowed=(0, 255),
                extra_env={"FOUNDRY_SOLC": solc},
            )
            report = json.loads((bundle / (prefix + "slither.json")).read_text())
            if report.get("success") is not True or report.get("error"):
                raise RuntimeError("Slither analysis failed: " + target)
        # Findings require human triage; a successful run is not a clean audit opinion.
        if output("git", "rev-parse", "HEAD") != commit or output(
            "git", "status", "--porcelain", "--untracked-files=all"
        ):
            raise RuntimeError(
                "Source changed during packaging; discard this evidence and rerun."
            )
        manifest = {
            "source_commit": commit,
            "source_tree": output("git", "rev-parse", "HEAD^{tree}"),
            "submodules": submodules.splitlines(),
            "tool_versions": versions,
            "commands": commands,
            "independent_audit": False,
            "slither_findings_require_review": True,
        }
        (bundle / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        (bundle / "SHA256SUMS").write_text(
            "".join(
                f"{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n"
                for p in sorted(bundle.iterdir())
                if p.is_file()
            )
        )
        archive = bundle.with_suffix(".tar.gz")
        with tarfile.open(archive, "w:gz") as tar:
            tar.add(bundle, arcname=bundle.name)
        print(
            f"Created {archive.relative_to(ROOT)}; review findings and privacy before sharing."
        )
    except Exception:
        print(
            f"Incomplete evidence retained at {bundle.relative_to(ROOT)}; no complete archive produced."
        )
        raise


if __name__ == "__main__":
    main()
