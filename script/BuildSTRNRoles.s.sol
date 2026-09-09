// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {STRN} from "../src/STRN.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @notice Read-only builder for the initial operational-role grant ceremony. Never schedules or executes.
contract BuildSTRNRoles {
    uint256 public constant ROLE_DELAY = 5 days;

    struct RoleConfig {
        uint256 chainId;
        address timelock;
        address proposer;
        address pauser;
        address unpauser;
        address blacklister;
        address seizer;
        address parameterManager;
        address releaser;
        bytes32 salt;
    }

    struct RoleBatch {
        uint256 chainId;
        address timelock;
        address[] targets;
        uint256[] values;
        bytes[] payloads;
        bytes32 salt;
        bytes32 operationId;
        bytes scheduleCalldata;
        bytes executeCalldata;
        bytes cancelCalldata;
    }

    error InvalidRoleConfiguration();
    error InvalidRoleAdministration();
    error ExistingRoleOperation();

    function buildRoleBatch(STRN token, RoleConfig memory config) public view returns (RoleBatch memory batch) {
        _validateRoleConfig(config);
        if (address(token).code.length == 0 || token.defaultAdmin() != config.timelock) {
            revert InvalidRoleAdministration();
        }
        bytes32[6] memory roles = [
            token.PAUSER_ROLE(),
            token.UNPAUSER_ROLE(),
            token.BLACKLISTER_ROLE(),
            token.SEIZER_ROLE(),
            token.PARAMETER_MANAGER_ROLE(),
            token.RELEASER_ROLE()
        ];
        address[6] memory holders = [
            config.pauser, config.unpauser, config.blacklister, config.seizer, config.parameterManager, config.releaser
        ];
        batch.chainId = config.chainId;
        batch.timelock = config.timelock;
        batch.salt = config.salt;
        batch.targets = new address[](6);
        batch.values = new uint256[](6);
        batch.payloads = new bytes[](6);
        for (uint256 i; i < 6; ++i) {
            if (holders[i] == address(token) || token.getRoleAdmin(roles[i]) != bytes32(0)) {
                revert InvalidRoleAdministration();
            }
            batch.targets[i] = address(token);
            batch.payloads[i] = abi.encodeCall(token.grantRole, (roles[i], holders[i]));
        }
        TimelockController timelock = TimelockController(payable(config.timelock));
        batch.operationId =
            timelock.hashOperationBatch(batch.targets, batch.values, batch.payloads, bytes32(0), config.salt);
        if (timelock.isOperation(batch.operationId)) revert ExistingRoleOperation();
        batch.scheduleCalldata = abi.encodeCall(
            timelock.scheduleBatch, (batch.targets, batch.values, batch.payloads, bytes32(0), config.salt, ROLE_DELAY)
        );
        batch.executeCalldata = abi.encodeCall(
            timelock.executeBatch, (batch.targets, batch.values, batch.payloads, bytes32(0), config.salt)
        );
        batch.cancelCalldata = abi.encodeCall(timelock.cancel, (batch.operationId));
    }

    function _validateRoleConfig(RoleConfig memory config) internal view {
        if (
            config.chainId == 0 || config.chainId != block.chainid || config.salt == bytes32(0)
                || config.timelock.code.length == 0 || config.proposer == address(0) || config.pauser == address(0)
                || config.unpauser == address(0) || config.blacklister == address(0) || config.seizer == address(0)
                || config.releaser == address(0) || config.parameterManager != config.timelock
        ) revert InvalidRoleConfiguration();
        TimelockController timelock = TimelockController(payable(config.timelock));
        if (
            timelock.getMinDelay() != ROLE_DELAY || !timelock.hasRole(timelock.PROPOSER_ROLE(), config.proposer)
                || !timelock.hasRole(timelock.CANCELLER_ROLE(), config.proposer)
                || !timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0))
        ) revert InvalidRoleConfiguration();
    }
}
