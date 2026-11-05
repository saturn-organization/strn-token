# Offline STRN deployment and role setup

The Ethereum input manifest and unapproved operator candidates are documented in [config/README.md](../config/README.md). Run its readiness check before preparing the explicit recipe arguments.

No script in this package broadcasts, signs, schedules or executes transactions. Use a separately authorized deployment ceremony after independent review. No production chain, recipient or role-holder address is silently chosen.

## Inputs

`DeploySTRN.runWithRoles(implementation, allocationRecipient, recoveryRecipient, adminTransferDelay, config)` is the complete local rehearsal entrypoint. It returns the initialized token and an unsent `RoleBatch`. For an already deployed token, `BuildSTRNRoles.buildRoleBatch(token, config)` builds the same role operation against its current state. `DeploySTRN.run(implementation, timelock, allocationRecipient, recoveryRecipient, adminTransferDelay)` remains available as a deployment-only primitive; it does not configure operators.

Set every field of `BuildSTRNRoles.RoleConfig` explicitly:

| Field              | Required value                                              |
| ------------------ | ----------------------------------------------------------- |
| `chainId`          | Intended chain ID, matching the execution/simulation chain  |
| `timelock`         | Reviewed existing five-day TimelockController               |
| `proposer`         | Reviewed address with both proposer and canceller authority |
| `pauser`           | Emergency pausing authority                                 |
| `unpauser`         | Separately reviewed resumption authority                    |
| `blacklister`      | Freeze/unfreeze authority                                   |
| `seizer`           | Enforcement authority                                       |
| `releaser`         | Separate immediate recovered-balance release authority      |
| `parameterManager` | Exactly `timelock`, so recovery-address changes are delayed |
| `salt`             | Reviewed unique nonzero bytes32 for this exact grant batch  |

Unset placeholders are rejected. Role holders may deliberately overlap, as in the underlying access-control system; the builder does not claim different addresses have independent signers. Review shared holders explicitly. Assigning a pausing role to the timelock makes its use delayed too. The parameter-manager-to-timelock assignment is enforced by this builder, not an immutable token rule.

Additional deployment arguments remain explicit: initial allocation recipient, initial recovery recipient, and the independent default-admin handoff delay. The entire billion-token supply goes to the allocation recipient. Initial operational roles are empty.

## Returned transaction envelope

`RoleBatch` records the chain ID, timelock destination, six targets, six zero ETH values, ordered grant payloads, salt, operation ID, and `scheduleCalldata`, `executeCalldata`, `cancelCalldata`.

The fixed order is PAUSER, UNPAUSER, BLACKLISTER, SEIZER, PARAMETER_MANAGER, RELEASER. All six targets are the STRN proxy. The predecessor is zero and the scheduling delay is five days. The operation identity is the TimelockController's hash of targets, values, payloads, predecessor and salt. Building the envelope does not submit it.

Review and preserve the returned envelope. In a separately authorized ceremony:

1. Verify chain, proxy implementation and ProxyAdmin ownership, timelock bytecode and complete role membership, recipients, holders, salt and all decoded payloads. A hypothetical local deployment address is not a confirmed production address: rebuild against the actual deployed proxy before submission.
2. Have the approved proposer submit `scheduleCalldata` to the recorded timelock with zero ETH. Verify the onchain operation ID and readiness timestamp against the preserved envelope.
3. After readiness, the open executor can submit `executeCalldata` to the same timelock with zero ETH. The designated canceller can instead submit `cancelCalldata` while the operation is pending.
4. Verify all six grants and role boundaries before public distribution. Subsequent role grants/revocations remain under the timelock; operational role use is immediate for directly assigned holders. Recovery-address changes remain timelocked because PARAMETER_MANAGER_ROLE belongs to the timelock.

The builder rejects an operation already pending, ready or done. Use the preserved envelope after scheduling rather than rebuilding it. A cancelled operation is removed by OpenZeppelin and can technically be scheduled again; use a newly reviewed salt for a revised ceremony.

## Validation boundaries

The builder checks chain ID, nonzero inputs/salt, timelock code presence, exact five-day delay, the supplied proposer/canceller, open executor, token default admin, and default-admin control of each operational role. It rejects the token itself as an operator. It does not enumerate all timelock members or existing token-role holders, attest bytecode authenticity, verify custody/signing arrangements, remove old grants, or freeze configuration against later governance changes. It is an additive initial-grant builder, not a role-reconciliation tool.

The deployment recipe establishes ProxyAdmin ownership when it creates the proxy. The standalone role builder checks token administration, not the proxy's hidden admin storage; independently verify ProxyAdmin ownership for an existing proxy. Revalidate all relevant state before scheduling and execution. The separate token default-admin handoff safeguard remains unchanged.

Staking custody registration is intentionally separate: no production staking address exists in this candidate, and the test fixture must never be registered as production custody.

## Tests

`forge test --match-contract 'STRNRoleBatchTest|STRNTimelockTest' -v` exercises the generated calldata with a local TimelockController, including early/unauthorized execution, exact grants, parameter changes through the timelock, cancellation, replay, configuration failures and complete unsent deployment rehearsal. Tests use explicit fixture addresses and do not contact a chain.

## Implementation verification and signing

The deployment recipes construct and validate local deployments and transaction envelopes. Production signing, custody credential resolution and broadcast tooling are separate operational responsibilities. Configure the deployer and proposer explicitly, verify the implementation and decoded calldata, and verify resulting state after each authorized transaction.

This recipe targets the new token initialization with liquid vote checkpoints. It is not a migration recipe for an already circulating non-voting token. Release is immediate for the assigned operator; only its role grant/revocation is timelock-administered.

Create the locked STRN implementation with `DeploySTRNImplementation.run()` first, then pass the independently verified implementation to the proxy recipe. Splitting creation keeps both helpers below EIP-170. Code presence alone is not implementation authenticity; compare the candidate runtime before deployment. Proxy initialization remains atomic.
