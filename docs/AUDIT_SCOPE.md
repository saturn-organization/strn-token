# Proposed STRN + sSTRN external audit scope

This is a review proposal, not an external audit report or launch approval. Agree the final scope with the auditor and identify both the reviewed commit and the remediation commit. The evidence package records the exact clean source commit and dependency revisions; a branch name alone is not an audit identifier.

The joint review covers [STRN](SPEC.md) and [sSTRN](SSTRN_SPEC.md), their interaction, privileged controls and initialization. See the staking [security](SSTRN_SECURITY.md) and [deployment](SSTRN_DEPLOYMENT.md) documentation.

## Components

- `src/StakedSTRN.sol`, `src/interfaces/ISTRNDiscount.sol`, `src/interfaces/IStakedSTRN.sol` and `script/DeployStakedSTRN.s.sol`: principal positions, exact expiry, nontransferability, delegated timestamp votes, non-voting recovery custody, authorized release, historical recovery, excess segregation, fee percentage and unsent role/custody activation. Onchain total-supply checkpoints retain recovered assets; the separate governance-platform integration must exclude historical recovered principal from its quorum denominator.
- `src/STRN.sol`, including inherited behavior from pinned OpenZeppelin contracts and upgradeable contracts.
- TransparentUpgradeableProxy / ProxyAdmin integration, atomic initialization and upgrade authority.
- `script/DeploySTRN.s.sol` and `script/BuildSTRNRoles.s.sol`: offline deployment and initial role-batch construction, validation and governance assumptions.
- Five-day TimelockController integration and role administration. Review the pinned dependency behavior and intended configuration; candidate addresses do not establish production configuration approval.

Tests, fixtures, verification scripts and `verification/baselines/` support review. Test fixtures are not production integrations. The supporting files must be assessed as evidence for the production contracts, not treated as additional deployed components.

## Required properties and privileged powers

- Initialization creates exactly one billion STRN; ordinary operations and seizure preserve total supply. Initialization cannot be repeated.
- Transfers enforce the documented pause and blacklist policy for caller, source and destination. Standard approvals survive restriction changes; rejected transactions preserve state.
- Seizure is separately authorized, allows partial amounts during pause, and uses a controlled recovery address. Registered staking custody cannot be seized directly.
- Custody removal requires zero balance. Recovery configuration cannot bypass custody protection. sSTRN implements claim-level recovery and authorized release; other custody integrations remain separately responsible.
- Emergency pause and resume permissions are separate. Recovery-address changes and ordinary role administration follow the intended timelock arrangement; default-admin transfer delay is a separate mechanism.
- Proxy initialization, role-batch targets/calldata and upgrade authority are correct. ABI and ERC-7201 storage compatibility are checked against committed baselines.

The detailed behavior is specified in [SPEC.md](SPEC.md); powers, assumptions and remaining trust are described in [SECURITY.md](SECURITY.md). Deployment inputs and procedures are in [DEPLOYMENT.md](DEPLOYMENT.md).

## Assumptions and exclusions

Production addresses, signer custody, authentic deployed timelock bytecode/membership, custody registrations and launch transactions require separate verification. The scripts' code-presence and delay checks do not attest a production system. Privileged upgrades can replace the token's rules.

Seasonal reward distribution, deployed governance-platform strategy, Governor, bridges, distribution/vesting, cumulative cap enforcement and real sUSDat integration are not implemented here. [External integration requirements](INTEGRATION_REQUIREMENTS.md) describe the intended consumer responsibilities; those systems are not part of the implemented production scope. The legacy staking-boundary fixture and compatible-upgrade fixtures remain test-only. Tests and static analysis are bounded evidence, not formal proof or an independent audit.

## Handoff and remediation

Supply the source commit with initialized pinned dependencies, this scope, specifications, security/deployment documentation and the separately generated evidence package described in [VERIFICATION.md](VERIFICATION.md). Include auditor-agreed exclusions and unresolved findings. Track fixes with regression tests and identify the final revision re-reviewed by the auditor. Publish an authorized final report under `audits/` with its scope and reviewed/remediation revisions.

The predeployment liquid-voting extension is in scope: timestamp delegation/signatures, backing exclusions, funded-custody registration, restricted recovered balances, immediate RELEASER_ROLE release, recovery checkpoints, combined vote conservation and six-role deployment batch. No migration from a circulating non-voting token is included.
