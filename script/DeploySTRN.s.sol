// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {STRN} from "../src/STRN.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {BuildSTRNRoles} from "./BuildSTRNRoles.s.sol";

/// @notice Offline deployment recipe. No broadcast, signing, or implicit production addresses.
/// @dev Supply a reviewed existing Saturn timelock. Operator grants are separate timelocked operations.
contract DeploySTRNImplementation {
    function run() external returns (STRN) {
        return new STRN();
    }
}

contract DeploySTRN is BuildSTRNRoles {
    error InvalidTimelock();
    error InvalidImplementation();

    function run(
        STRN implementation,
        address timelock,
        address allocationRecipient,
        address recoveryRecipient,
        uint48 adminTransferDelay
    ) public returns (STRN token) {
        if (timelock.code.length == 0 || TimelockController(payable(timelock)).getMinDelay() != 5 days) {
            revert InvalidTimelock();
        }
        if (address(implementation).code.length == 0) revert InvalidImplementation();
        token = STRN(
            address(
                new TransparentUpgradeableProxy(
                    address(implementation),
                    timelock,
                    abi.encodeCall(
                        STRN.initialize, (timelock, allocationRecipient, recoveryRecipient, adminTransferDelay)
                    )
                )
            )
        );
    }

    /// @notice Recommended complete local rehearsal: deploy atomically, then return the unsent role batch.
    /// @dev Config is validated before deployment. The legacy run method remains deployment-only.
    function runWithRoles(
        STRN implementation,
        address allocationRecipient,
        address recoveryRecipient,
        uint48 adminTransferDelay,
        RoleConfig memory config
    ) external returns (STRN token, RoleBatch memory batch) {
        _validateRoleConfig(config);
        token = run(implementation, config.timelock, allocationRecipient, recoveryRecipient, adminTransferDelay);
        batch = buildRoleBatch(token, config);
    }
}
