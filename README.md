# STRN and sSTRN audit candidate

Standalone implementation on branch `audit/strn-v1`. Built and tested; not independently audited, deployed, or approved for launch.

Start with [the concrete spec](docs/SPEC.md), [security and privileged powers](docs/SECURITY.md), and [audit scope](docs/AUDIT_SCOPE.md) and [verification / evidence packaging](docs/VERIFICATION.md). The repository includes `src/StakedSTRN.sol`, its product-callable discount interface and offline deployment recipe. Start with [the staking spec](docs/SSTRN_SPEC.md), [staking security](docs/SSTRN_SECURITY.md) and [integration/deployment guidance](docs/SSTRN_DEPLOYMENT.md).

Fixed 1 billion STRN, 18 decimals, one-time initialization, ERC20, pause, roles, blacklist, controlled recovery-address rotation and partial seizure, with protection for designated staking custody. STRN includes timestamp delegated votes, non-voting restricted seizure balances and separately authorized release; it has no operational mint/burn, Governor or bridge. The separate sSTRN receipt implements 1:1 locked principal, explicit renewal, delegation/checkpoints, non-voting recovery custody with separately authorized release, and an active-stake fee percentage. Seasonal distributions, product cap enforcement and actual sUSDat integration remain separate. An offline deployment recipe assigns administration and ProxyAdmin ownership to a reviewed five-day timelock; it does not broadcast. Upgrade authority can replace these rules. See [deployment and role setup](docs/DEPLOYMENT.md) for the complete unsent role-batch recipe and required inputs. The spec labels engineering assumptions and unresolved product choices explicitly.

```sh
git submodule update --init
npm ci --ignore-scripts
# Install Foundry 1.8.1 and Solidity 0.8.36; make the pinned solc available on PATH.
STRN_SOLC="$(command -v solc)" ./scripts/verify.sh
```

The specifications describe the implemented contracts. [External integration requirements](docs/INTEGRATION_REQUIREMENTS.md) separately describe governance-platform, points/distributor and product-fee responsibilities that are not implemented here.

Committed gas snapshots are read-only during tests and verification. `python3 scripts/check-gas.py` compares freshly generated temporary snapshots against the complete committed baseline, including filenames, measurement names and values. Run `python3 scripts/test-gas-verification.py` to exercise the regression guard. Use `./scripts/update-gas.sh` only for an intentional baseline update, then review `git diff -- snapshots/`.
