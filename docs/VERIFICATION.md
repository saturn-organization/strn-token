# Verification and audit evidence

Keep source, tests, scripts, specifications, security documentation, gas snapshots and the STRN and sSTRN ABI/storage baselines in Git. Generated logs, coverage, compiler input, bytecode and manifests belong in ignored `artifacts/` or a separately distributed package. Completed external reports belong in `audits/` only when authorized for publication.

## Reproduce checks

Install Foundry 1.8.1, Solidity 0.8.36 on PATH, Node.js/npm and Python 3. For static analysis also install Slither. Install the pinned formatters described below. Initialize pinned public submodules and locked Node dependencies:

```sh
git submodule update --init
npm ci --ignore-scripts
npm run format:check
STRN_SOLC="$(command -v solc)" bash scripts/verify.sh
python3 scripts/test-gas-verification.py
forge coverage --no-match-contract 'STRNInvariant|CombinedSTRNVotesInvariant' --fuzz-runs 256 --report summary
```

Verification checks deployment-manifest structure and validation regressions, formatting, sizes, gas, audit-profile tests, a second invariant seed, both contracts' initializer/upgrade safety, ABI preservation and ERC-7201 layout compatibility. It includes a compiled incompatible layout fixture that must be rejected. These checks do not overwrite committed baselines or emit audit evidence by default. Staking recovery tests include more than 32 recovery-held positions, same-timestamp/historical voting and supply, immediate separate-role release, role revocation, invalid recipients, maturity/capacity bounds, reentrancy and transfer rollback. The stateful model includes both seizure and release and checks backing, ordinary/recovery ownership, active balances and votes.

Gas updates use `scripts/update-gas.sh`; review the resulting snapshot diff. Intentional ABI/storage baseline updates use `node scripts/check-upgrade.cjs "$(command -v solc)" --write-baseline`, which checks compatibility before writing. For sSTRN, use `node scripts/check-staking-upgrade.cjs "$(command -v solc)" --write-baseline`. Review changes under `verification/baselines/`; do not update a baseline merely to silence a failure.

## Continuous integration

`.github/workflows/verify.yml` runs on pushes, pull requests and manual dispatch. It uses Ubuntu 24.04, Foundry 1.8.1, Node 24.18.1 and the Solidity 0.8.36 pin in `foundry.toml`; action revisions are pinned. It initializes submodules, installs locked npm dependencies without lifecycle scripts, installs pinned formatters, runs `npm run format:check`, `scripts/verify.sh` and the gas-guard regressions. Permissions are read-only; checkout credentials are not retained. No RPC, signing credentials or deployment is required. The workflow uses Forge's installed compiler for the Node compatibility checks.

The staking compatibility checker also enforces the consumer `IStakedSTRN` ABI: input/output types (including position tuples), mutability and event indexing. Its nominal interface struct/address types need not match the implementation's Solidity names; their external encoding must match. Stricter mutability is accepted as Solidity allows: pure can satisfy view/nonpayable, and view can satisfy nonpayable. This covers the deliberately reverting, pure ERC20 transfer/approval functions. Implementation ABI/storage baselines remain authoritative and checked independently of the consumer interface.

The deployment-configuration regressions use explicit fixtures, independent of the repository's approval state. The real manifest is checked as declared: complete approved sections must pass readiness; unapproved sections must not. Approving a valid manifest does not require weakening or rewriting the regression suite.

## Generate a commit-linked handoff

From a clean, reviewed commit with initialized dependencies:

```sh
STRN_SOLC="$(command -v solc)" python3 scripts/package-audit.py
```

The command runs the formatting check, verification, gas-guard regression checks, coverage and Slither, then creates a local `artifacts/audit-<commit>-<unique-id>.tar.gz`. The package contains logs, LCOV, analyzer JSON, compiler input, token creation/runtime bytecode with SHA-256 hashes, dependency commits, tool versions, command results and a SHA-256 file manifest. Both contracts are exported separately (`staking-` prefix for sSTRN); `staking-upgrade-check-input.json` records its upgrade validation compiler input. Static analysis covers both deployment recipes. The production bytecode comes from the normal Foundry build, with its matching compiler input. A separately labeled `upgrade-check-input.json` includes the compatible and deliberately incompatible fixtures used by the upgrade checker; these are not production contracts.

A dirty checkout or mismatched/uninitialized submodule is rejected. Failed runs retain an incomplete directory for diagnosis but do not produce a completed archive. Successful analysis can still contain findings: inspect every finding and the exclusions before handing off. The manifest is provenance and integrity metadata, not auditor approval. Use a dedicated checkout and do not change source or dependencies during the run.

Raw output can contain machine paths. Packages remain local and ignored; inspect and sanitize them before any authorized external sharing, then regenerate `SHA256SUMS` for altered contents. Distribution may use an agreed private delivery channel or separately authorized release attachment. The script does not upload, publish or create a release.

To emit only the upgrade-check compiler input while checking upgrades, set `STRN_EVIDENCE_DIR=artifacts/compiler-review` when running `scripts/check-upgrade.cjs`. Ordinary verification leaves this unset.

## Static-analysis review context

Current finding explanations are maintained in [STRN security](SECURITY.md) and [sSTRN security](SSTRN_SECURITY.md). The STRN role builder uses a bounded six-role read-only loop. Retain and reassess fresh analyzer output against the exact candidate; the documentation is not a detector allowlist.

The compiler checker screens named-error require calls and recursion in the resolved static call graph and uses via IR. This is a targeted check, not a comprehensive or current compiler-advisory feed. Review compiler and dependency advisories separately before deployment.

## Historical evidence

Historical generated evidence is retained separately from this source tree and records earlier runs, not verification of the current commit. STRN and sSTRN ABI/storage baselines are maintained under `verification/baselines/`; generate a fresh package for each agreed audit revision.

sSTRN baselines use `node scripts/check-staking-upgrade.cjs "$(command -v solc)" --write-baseline`; this never rewrites STRN baselines. Both gas groups are compared by the existing regression guard. Read [staking static-analysis triage](SSTRN_SECURITY.md) for findings and limitations.

## Voting and recovery verification

STRN ABI/storage baselines cover Votes/EIP712/Nonces and recovery balance/checkpoint fields. Compatible-upgrade fixtures test state preservation; this is not permission to migrate a circulating non-voting deployment without an activation design. Current runtime sizes are 18,507 bytes for STRN and 23,217 bytes for sSTRN. Deployment is split into implementation creation and atomic proxy initialization to keep each helper under EIP-170.

The STRN stateful reference model covers liquid delegates, restricted balances, release, custody changes and historical snapshots alongside ERC20 balances/allowances. Dedicated tests cover signatures/replay, mixed balances, rotation/allowance escape attempts, combined liquid/receipt vote conservation and compatible upgrades preserving votes/nonces/recovery. Gas baselines include vote/recovery accounting: a transfer to a new undelegated recipient is 70,734 gas in the fixture; a transfer writing both delegate checkpoints is 150,617 gas. Gas figures are fixture-specific, not universal transaction estimates. Read SECURITY.md for current static-analysis triage.

The combined historical-voting invariant maintains an independent ledger of liquid principal, locked recovery balances, staking claims and each token's delegate choices. Random sequences cover transfers, staking, both delegations, liquid seizure/release, position recovery/release, partial matured redemption, donations and time advancement. At each time advance it records expected votes and supply/recovery quantities before querying either token's checkpoints; subsequent mutations recheck the latest and a sampled older snapshot. Both audit-profile and second-seed verification include this campaign. It tests token query primitives, not a deployed governance-platform strategy.

## Formatting

Install the locked Node dependencies with `npm ci --ignore-scripts`, Ruff with
`python3 -m pip install ruff==0.12.0`, and shfmt with
`go install mvdan.cc/sh/v3/cmd/shfmt@v3.12.0` (requires Go 1.23 or newer).
Ensure the Go binary directory is on PATH. Use the Foundry version pinned in CI.

Run `npm run format` to format maintained source and documentation, or
`npm run format:check` to check without changing files. CI and the audit packager
run the check. Ruff owns Python, Prettier owns JavaScript/CommonJS, maintained
JSON, YAML and Markdown, shfmt owns Bash, and Forge owns Solidity.

Generated lockfiles, snapshots, ABI/storage baselines, dependencies, build output
and audit evidence remain generator-owned and are excluded from general formatting.
Formatting does not replace tests or static analysis.
