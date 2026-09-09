// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;
import {StakedSTRN} from "../src/StakedSTRN.sol";
import {STRN} from "../src/STRN.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @notice Offline rehearsal only. Returns the exact unsent timelock batch; never broadcasts.
contract DeployStakedSTRN {
    struct Config {
        uint256 chainId;
        address timelock;
        address proposer;
        address pauser;
        address unpauser;
        address seizer;
        address releaser;
        uint48 duration;
        uint48 adminTransferDelay;
        bytes32 salt;
    }

    struct Batch {
        address[] targets;
        uint256[] values;
        bytes[] payloads;
        bytes32 operationId;
        bytes schedule;
        bytes execute;
    }
    error InvalidConfiguration();

    function run(STRN token, StakedSTRN implementation, Config memory c)
        external
        returns (StakedSTRN receipt, Batch memory b)
    {
        if (
            c.chainId != block.chainid || c.timelock.code.length == 0 || address(token).code.length == 0
                || address(implementation).code.length == 0 || c.proposer == address(0) || c.pauser == address(0)
                || c.unpauser == address(0) || c.seizer == address(0) || c.releaser == address(0)
                || token.defaultAdmin() != c.timelock
        ) revert InvalidConfiguration();
        TimelockController timelock = TimelockController(payable(c.timelock));
        if (
            timelock.getMinDelay() != 5 days || !timelock.hasRole(timelock.PROPOSER_ROLE(), c.proposer)
                || !timelock.hasRole(timelock.CANCELLER_ROLE(), c.proposer)
                || !timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0))
        ) revert InvalidConfiguration();
        receipt = StakedSTRN(
            address(
                new TransparentUpgradeableProxy(
                    address(implementation),
                    c.timelock,
                    abi.encodeCall(
                        StakedSTRN.initialize, (c.timelock, address(token), c.duration, c.adminTransferDelay)
                    )
                )
            )
        );
        b.targets = new address[](6);
        b.values = new uint256[](6);
        b.payloads = new bytes[](6);
        b.targets[0] = address(token);
        b.payloads[0] = abi.encodeCall(STRN.setStakingCustodyProtection, (address(receipt), true));
        bytes32[5] memory roles = [
            receipt.PAUSER_ROLE(),
            receipt.UNPAUSER_ROLE(),
            receipt.SEIZER_ROLE(),
            receipt.PARAMETER_MANAGER_ROLE(),
            receipt.RELEASER_ROLE()
        ];
        address[5] memory holders = [c.pauser, c.unpauser, c.seizer, c.timelock, c.releaser];
        for (uint256 i; i < 5; ++i) {
            b.targets[i + 1] = address(receipt);
            b.payloads[i + 1] = abi.encodeWithSignature("grantRole(bytes32,address)", roles[i], holders[i]);
        }
        b.operationId = timelock.hashOperationBatch(b.targets, b.values, b.payloads, bytes32(0), c.salt);
        b.schedule = abi.encodeCall(
            TimelockController.scheduleBatch, (b.targets, b.values, b.payloads, bytes32(0), c.salt, uint256(5 days))
        );
        b.execute =
            abi.encodeCall(TimelockController.executeBatch, (b.targets, b.values, b.payloads, bytes32(0), c.salt));
    }
}

/// @notice Separate offline implementation creation keeps both helpers below EIP-170.
contract DeployStakedSTRNImplementation {
    function run() external returns (StakedSTRN) {
        return new StakedSTRN();
    }
}
