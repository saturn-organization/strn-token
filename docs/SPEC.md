# STRN v1 audit-candidate specification

Status: engineering audit candidate; not independently audited or deployed. This specification describes STRN behavior, configuration and trust boundaries.

## Requirements and scope

The requirements below define the implementation scope.

| Requirement                                                                                  | Treatment                                                                                       |
| -------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| Standard ERC20, pause, roles, blacklist/seize, one billion tokens, upgradeable, OpenZeppelin | Implemented                                                                                     |
| No operational mint/burn                                                                     | Exactly one initial issuance                                                                    |
| No rebase or value accrual                                                                   | No fee, yield, NAV or transfer callbacks                                                        |
| Staking and voting                                                                           | sSTRN and liquid timestamp votes implemented; points, Governor and product fees remain separate |
| Standalone token audit candidate                                                             | Dedicated repository and audit branch                                                           |
| 1:1 staking principal, no duplicated votes, reserves separate, maturity retains claims/votes | Integration boundary below                                                                      |
| Governance thresholds                                                                        | Unresolved; no Governor or thresholds implemented                                               |

Deployment inputs and external integration requirements are identified separately.

## Asset and initialization

Name `Saturn`, symbol `STRN`, 18 decimals. `INITIAL_SUPPLY = 1_000_000_000 * 10**18` base units. Name/decimals are engineering assumptions requiring branding confirmation. Initialize exactly once through an OpenZeppelin TransparentUpgradeableProxy constructor with nonempty encoded `initialize(admin, initialRecipient, seizureRecipient, adminDelay)` data. All three addresses must be nonzero and not the proxy itself. The offline `script/DeploySTRN.s.sol` recipe requires an existing reviewed five-day timelock and creates a locked implementation with its separate helper, then atomically initializes the proxy using that reviewed implementation. It contains no broadcast or signing operation.

The implementation constructor disables initializers. Initializer calls all required parent initializers; sets the initial seizure recipient and issues the entire supply to the explicit initial recipient. Initial pause is false, blacklist empty. Only DEFAULT_ADMIN_ROLE is initially granted; no implicit operator privileges. Initial allocation/signer addresses and the uint48 admin-transfer delay remain launch parameters, with test values used only as fixtures. An uninitialized generic proxy can be taken over: atomic constructor initialization is mandatory.

## Authority and upgrades

Use pinned OpenZeppelin 5.5.0 ERC20VotesUpgradeable, PausableUpgradeable, AccessControlDefaultAdminRulesUpgradeable and TransparentUpgradeableProxy. Separate ProxyAdmin owner controls upgrades; token admin manages PAUSER_ROLE, UNPAUSER_ROLE, PARAMETER_MANAGER_ROLE, BLACKLISTER_ROLE, SEIZER_ROLE and RELEASER_ROLE (hashes of exact uppercase strings). Token admin has no implicit seizure/pause privilege but can grant those roles. OpenZeppelin delayed two-step default-admin transition and delay changes apply unchanged, including delayed renunciation. Other roles may have multiple members and may be revoked/renounced. Role administration is never disabled by pause/blacklist, to permit recovery. Blacklisting an operator does not revoke its role; revokeRole is required for compromised administrative keys.

ProxyAdmin ownership uses OpenZeppelin Ownable (single-step transfer), distinct from token's two-step default admin. The deployment recipe assigns both ProxyAdmin ownership and token default admin to the reviewed five-day timelock. It checks code presence and `getMinDelay() == 5 days`; these are sanity checks, not proof of authentic timelock bytecode or correct proposer/canceller/executor membership. The token itself does not enforce an upgrade delay. Operational role grants through that timelock must mature before use; granted operators then act without scheduling each call. The deployment recipe grants no operator roles immediately. `runWithRoles` returns a validated, unsent five-day grant batch; `BuildSTRNRoles.buildRoleBatch` supports an existing proxy. Explicit holder inputs cover all six roles, with PARAMETER_MANAGER_ROLE assigned to the timelock. The builder verifies the selected chain, proposer/canceller, open executor, token role administration and nonzero salt/holders, and returns operation identity plus schedule/execute/cancel calldata. See `docs/DEPLOYMENT.md` for review and configuration boundaries. Token admin-transfer delay is a separate explicit input, not a substitute for the upgrade timelock. Upgrade authority is effectively absolute and can replace supply/restriction logic. Never add UUPS to this transparent implementation. No universal safety claim across arbitrary upgrades. Compatible upgrades must preserve inherited ERC-7201 namespaces and the custom namespace's ordered fields. No mutable linear storage. No dependency-major upgrades without separate storage/migration audit.

## ERC20 and restrictions

Inherit standard totalSupply, balanceOf, allowance, transfer, approve, transferFrom, name, symbol, decimals. Transfers return true, zero and self transfers emit Transfer, zero endpoints revert under ERC20 semantics. Infinite allowances remain infinite. Finite transferFrom consumes allowance without emitting Approval as in OZ 5.5. No permit, public mint/burn, arbitrary call or payable entrypoints. Historical votes and restricted-balance release are described below.

Normal transfer/transferFrom: require unpaused and nonblacklisted caller, source, destination, including zero-value/self transfers. Checks reside in `_update` to cover both routes. A rejected transferFrom reverts the preceding allowance decrement atomically. Direct transfer is unaffected by approvals to unrelated blacklisted spenders.

approve uses unmodified OpenZeppelin ERC20 semantics: setting, replacing and revoking approvals remain available while paused or either address is blacklisted; zero spender is still invalid. Existing allowances persist through pause, blacklisting, unblacklisting and seizure. Frozen allowances cannot move funds until restrictions clear; unblacklisting deliberately restores surviving approvals. This avoids unbounded allowance enumeration and custom allowance semantics. Users/operators must understand stale approvals; allowance-epoch invalidation is a separately reviewable policy change, not implemented. Standard ERC20 allowance replacement race remains; clients should use zero-first where appropriate.

pause: PAUSER_ROLE; unpause: UNPAUSER_ROLE; standard Paused/Unpaused events and EnforcedPause/ExpectedPause errors. Pause restricts ordinary movement; approvals, role recovery, blacklist changes, recovery-address configuration, custody configuration, upgrades and seizure remain available.

setBlacklisted(account,status): BLACKLISTER_ROLE. Reject address zero and token proxy; reject blacklisting any current DEFAULT_ADMIN_ROLE holder; permit other accounts including operators, staking custody and seizure recipient. An already-blacklisted pending admin cannot accept the role until cleared. Removing a blacklist is always permitted for a valid address. Idempotent updates emit only on change. emit BlacklistUpdated(account indexed, status). Getter isBlacklisted(address). Blacklisting recipient deliberately suspends seizure until restored.

## Seizure

seize(from,amount): SEIZER_ROLE. Source must not be protected staking custody, must currently be blacklisted, must differ from configured seizureRecipient, amount must be positive and no greater than the unseized portion of its balance. Destination must not be blacklisted. No caller-specified destination. `setSeizureRecipient(address)` requires PARAMETER_MANAGER_ROLE and rejects zero, the proxy, blacklisted addresses and protected staking custody. It emits SeizureRecipientUpdated(previousRecipient,newRecipient), including same-address assignments; it changes only future seizure destinations. Registering the current recipient as protected custody is also rejected. Works while paused. Explicitly invokes ERC20Upgradeable.\_update only after these checks: seizure and authorized recovery release intentionally bypass ordinary movement restrictions. Updates the recovery/vote checkpoints and emits Transfer and Seized(operator indexed, from indexed, recipient indexed, amount). Source remains blacklisted; no mint/burn, no allowance consumption/reset. No hooks or external calls. A wrong/lost seizure recipient can be changed by the parameter manager without upgrading. The seizer cannot redirect it unless separately granted parameter-management authority. Blacklister plus seizer can confiscate unprotected, non-admin holders' tokens to that recipient. Admin can grant both roles. No legal-order predicate is enforced.

Custom errors: InvalidAddress(address), AccountBlacklisted(address), AccountNotBlacklisted(address), InvalidSeizure(), CannotBlacklistAdmin(), ProtectedStakingCustody(address), FundedStakingCustody(address), RecoveryBalanceLocked(address), InvalidRelease(), InvalidDelegate(address). Inherited ERC20/ERC6093, access/default-admin, initialization and pause errors are retained. Complete generated ABI is canonical for signatures/events/errors.

## Accounting and complexity

After initialized: totalSupply always INITIAL_SUPPLY; sum of balances across all holders equals supply. Every successful movement subtracts/adds equal amount (self transfer net zero). Failed calls leave balances, allowances, supply, roles, restrictions and implementation unchanged. Only authorized roles may mutate their domains. Transfers and administrative balance changes are bounded, with no holder enumeration or external calls. Historical checkpoint lookup is logarithmic in checkpoint count; same-timestamp writes coalesce.

## Liquid votes and recovery

STRN uses ERC20Votes from initial deployment, with timestamp clock matching sSTRN, EIP712 domain Saturn/version 1 and signature nonces. Liquid holders explicitly delegate or self-delegate; no automatic self-delegation is performed. Zero delegation opts out. Blacklisted accounts cannot delegate and new delegation to a blacklisted account is rejected; blacklist alone does not erase existing votes or rewrite history. Pause does not freeze delegation. Liquid and sSTRN delegate choices are independent.

Voting units equal balance minus recovered balance, or zero for protected staking custody. Registering custody clears its own outgoing delegation before excluding its units. It cannot subsequently delegate its backing. Other holders may still designate that address as their representative: those are their votes, not votes created by backing. Registration does not erase other holders' independent delegation choices. All backing and donations in registered custody carry zero liquid voting units.

Seizure retains the existing recipient wallet and records the seized amount as a restricted portion of its balance. That portion cannot vote or move through transfer/transferFrom, even after unblacklisting or recipient rotation. Unseized balances in the same wallet remain ordinary balances. Subsequent seizure cannot move its already-recovered portion. Positive self-transfers are subject to the same available-balance guard. Recovery records and aggregate timestamp checkpoints track current/historical seized principal without burning supply.

`releaseRecovered(custodian, recipient, amount)` is RELEASER_ROLE-only and immediate, including during pause. It transfers a positive amount no greater than the custodian's recorded recovered balance to an eligible, nonzero, non-proxy, non-staking-custody recipient different from the custodian. The custody source may be blacklisted: release is an explicit recovery operation. Only the released amount becomes ordinary liquid voting units, assigned to the recipient's existing delegate, if any. Wallet ownership, approvals, changing the recovery recipient and SEIZER_ROLE alone cannot release funds. Role administration remains timelocked; individual seizure/release operations do not. RecoveryReleased plus Seized identify transitions for external points cases.

Recovery balances/checkpoints occupy the STRN namespace; Votes, Nonces and EIP712 use their own OpenZeppelin namespaces. The committed ABI/storage baselines cover this implementation. Storage compatibility does NOT make upgrading an already circulating non-voting token safe: that would require a separate checkpoint activation/migration design. No such migration is supplied.

## Staking custody and combined governance

`setStakingCustodyProtection` is DEFAULT_ADMIN_ROLE-only. Registration requires contract code, excludes the token proxy, configured recovery recipient and any account with recovered balance. Removing protection requires zero STRN balance. Code presence is not an attestation; governance must inspect implementation and upgrades. Protected custody cannot be directly seized. No normal transfer/pause/blacklist exemption is added. See SSTRN_SPEC.md for the implemented position lifecycle; StakingBoundary remains a legacy synthetic fixture only.

Both tokens expose historical delegated votes, total supply and recovered principal using the same timestamp clock. STRN excludes registered backing from liquid voting units; sSTRN accounts for receipt voting units. The external platform must combine these values without counting backing twice. See [governance integration requirements](INTEGRATION_REQUIREMENTS.md#governance-platform) for snapshot alignment and denominator calculation. No Governor, points distributor or product fee enforcement is implemented here.

## Verification properties

Unit/error/event and role tests; bounded differential ERC20 tests; multi-actor hostile sequences with independent balance/allowance model; fuzz boundaries and deterministic seeds; supply conservation and failed-state checks. Proxy initialization and compatible upgrade preserve balances, allowance, roles, blacklist, pause, configured recipient, protected custody and admin transition state. Negative incompatible layout fixture must fail storage checking; ABI baseline must retain all selectors. Gas snapshots and contract size, source/dependency pins, static analysis findings triage, reproducible local audit package. These establish tested evidence, not formal proof or independent audit.

## Toolchain

The build uses Solidity 0.8.36 (`8a079791`), optimizer enabled with 200 runs, via IR and the Cancun EVM target. No experimental SSA pipeline is enabled. OpenZeppelin 5.5.0 and the remaining dependency revisions are pinned by the repository gitlinks. Reproduce the exact build settings in `foundry.toml`; dependency or compiler changes require renewed verification.

## Technical references

- [OpenZeppelin 5.x access control API](https://docs.openzeppelin.com/contracts/5.x/api/access)
- [Writing upgradeable contracts and namespaced storage](https://docs.openzeppelin.com/upgrades-plugins/writing-upgradeable)
- [OpenZeppelin 5.5.0 release](https://github.com/OpenZeppelin/openzeppelin-contracts/releases/tag/v5.5.0)
- [Solidity 0.8.36 release and fixes](https://github.com/argotorg/solidity/releases/tag/v0.8.36)

Version pins, source inspection and local evidence are authoritative for this candidate; unversioned documentation may change.

## Staking specification

[SSTRN_SPEC.md](SSTRN_SPEC.md) defines the companion staking contract, position lifecycle, discount getter and claim-level recovery. Both contracts and their interaction are included in the joint audit scope.
