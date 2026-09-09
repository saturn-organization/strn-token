// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;
import {STRNTimelockFixture} from "./STRNTimelock.t.sol";
import {STRN} from "../src/STRN.sol";
import {DeploySTRN, DeploySTRNImplementation} from "../script/DeploySTRN.s.sol";
import {BuildSTRNRoles} from "../script/BuildSTRNRoles.s.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

contract STRNRoleBatchTest is STRNTimelockFixture {
    BuildSTRNRoles internal builder;

    function setUp() public override {
        super.setUp();
        builder = new BuildSTRNRoles();
    }

    function _config() internal view returns (BuildSTRNRoles.RoleConfig memory) {
        return BuildSTRNRoles.RoleConfig({
            chainId: block.chainid,
            timelock: address(timelock),
            proposer: proposer,
            pauser: address(0x40),
            unpauser: address(0x41),
            blacklister: address(0x42),
            seizer: address(0x43),
            parameterManager: address(timelock),
            releaser: address(0x45),
            salt: keccak256("role setup fixture")
        });
    }

    function _send(address sender, bytes memory data) internal returns (bool ok) {
        vm.prank(sender);
        (ok,) = address(timelock).call(data);
    }

    function testGeneratedBatchExecutesExactRolesAfterDelay() public {
        BuildSTRNRoles.RoleConfig memory config = _config();
        BuildSTRNRoles.RoleBatch memory batch = builder.buildRoleBatch(token, config);
        assertEq(batch.chainId, block.chainid);
        assertEq(batch.timelock, address(timelock));
        assertEq(batch.targets.length, 6);
        assertEq(
            batch.operationId, timelock.hashOperationBatch(batch.targets, batch.values, batch.payloads, 0, config.salt)
        );
        assertFalse(token.hasRole(token.PAUSER_ROLE(), config.pauser));
        assertFalse(_send(treasury, batch.scheduleCalldata));
        assertTrue(_send(proposer, batch.scheduleCalldata));
        vm.expectRevert(BuildSTRNRoles.ExistingRoleOperation.selector);
        builder.buildRoleBatch(token, config);
        vm.warp(vm.getBlockTimestamp() + 5 days - 1);
        assertFalse(_send(treasury, batch.executeCalldata));
        assertFalse(token.hasRole(token.PAUSER_ROLE(), config.pauser));
        vm.warp(vm.getBlockTimestamp() + 1);
        assertTrue(_send(treasury, batch.executeCalldata));
        assertTrue(token.hasRole(token.PAUSER_ROLE(), config.pauser));
        assertTrue(token.hasRole(token.UNPAUSER_ROLE(), config.unpauser));
        assertTrue(token.hasRole(token.BLACKLISTER_ROLE(), config.blacklister));
        assertTrue(token.hasRole(token.SEIZER_ROLE(), config.seizer));
        assertTrue(token.hasRole(token.RELEASER_ROLE(), config.releaser));
        assertTrue(token.hasRole(token.PARAMETER_MANAGER_ROLE(), address(timelock)));
        assertFalse(token.hasRole(token.UNPAUSER_ROLE(), config.pauser));
        assertFalse(token.hasRole(token.PARAMETER_MANAGER_ROLE(), config.seizer));
        assertEq(token.defaultAdmin(), address(timelock));
        assertEq(token.balanceOf(treasury), token.INITIAL_SUPPLY());
        assertFalse(_send(treasury, batch.executeCalldata));
        vm.prank(config.pauser);
        token.pause();
        vm.prank(config.pauser);
        vm.expectRevert();
        token.unpause();
        vm.prank(config.unpauser);
        token.unpause();
        vm.prank(config.seizer);
        vm.expectRevert();
        token.setSeizureRecipient(config.seizer);
        // Parameter changes remain scheduled even after initial grants.
        bytes memory data = abi.encodeCall(token.setSeizureRecipient, (address(0x44)));
        vm.prank(proposer);
        timelock.schedule(address(token), 0, data, 0, bytes32(uint256(1)), 5 days);
        vm.warp(vm.getBlockTimestamp() + 5 days);
        timelock.execute(address(token), 0, data, 0, bytes32(uint256(1)));
        assertEq(token.seizureRecipient(), address(0x44));
    }

    function testGeneratedCancellationAndNewSalt() public {
        BuildSTRNRoles.RoleConfig memory config = _config();
        BuildSTRNRoles.RoleBatch memory batch = builder.buildRoleBatch(token, config);
        assertTrue(_send(proposer, batch.scheduleCalldata));
        assertFalse(_send(treasury, batch.cancelCalldata));
        assertTrue(_send(proposer, batch.cancelCalldata));
        vm.warp(vm.getBlockTimestamp() + 5 days);
        assertFalse(_send(treasury, batch.executeCalldata));
        config.salt = keccak256("replacement fixture");
        BuildSTRNRoles.RoleBatch memory replacement = builder.buildRoleBatch(token, config);
        assertTrue(replacement.operationId != batch.operationId);
    }

    function testFuzzRejectsUnsetOrInvalidConfiguration(uint8 field) public {
        BuildSTRNRoles.RoleConfig memory c = _config();
        uint8 i = field % 11;
        if (i == 0) c.chainId = 0;
        else if (i == 1) c.chainId = block.chainid + 1;
        else if (i == 2) c.timelock = address(0);
        else if (i == 3) c.proposer = address(0);
        else if (i == 4) c.pauser = address(0);
        else if (i == 5) c.unpauser = address(0);
        else if (i == 6) c.blacklister = address(0);
        else if (i == 7) c.seizer = address(0);
        else if (i == 8) c.parameterManager = proposer;
        else if (i == 9) c.salt = 0;
        else c.releaser = address(0);
        vm.expectRevert(BuildSTRNRoles.InvalidRoleConfiguration.selector);
        builder.buildRoleBatch(token, c);
    }

    function testRejectsWrongDelayAndMissingTimelockAuthority() public {
        BuildSTRNRoles.RoleConfig memory c = _config();
        vm.prank(address(timelock));
        timelock.updateDelay(4 days);
        vm.expectRevert(BuildSTRNRoles.InvalidRoleConfiguration.selector);
        builder.buildRoleBatch(token, c);
        vm.prank(address(timelock));
        timelock.updateDelay(5 days);
        bytes32[3] memory roles = [timelock.PROPOSER_ROLE(), timelock.CANCELLER_ROLE(), timelock.EXECUTOR_ROLE()];
        for (uint256 i; i < 3; i++) {
            address holder = i == 2 ? address(0) : proposer;
            vm.prank(address(timelock));
            timelock.revokeRole(roles[i], holder);
            vm.expectRevert(BuildSTRNRoles.InvalidRoleConfiguration.selector);
            builder.buildRoleBatch(token, c);
            vm.prank(address(timelock));
            timelock.grantRole(roles[i], holder);
        }
    }

    function testRejectsWrongTokenAdministrationAndTokenRoleHolder() public {
        BuildSTRNRoles.RoleConfig memory c = _config();
        vm.expectRevert(BuildSTRNRoles.InvalidRoleAdministration.selector);
        builder.buildRoleBatch(STRN(address(0)), c);
        c.pauser = address(token);
        vm.expectRevert(BuildSTRNRoles.InvalidRoleAdministration.selector);
        builder.buildRoleBatch(token, c);
        c = _config();
        vm.prank(address(timelock));
        token.beginDefaultAdminTransfer(proposer);
        vm.warp(vm.getBlockTimestamp() + 2 days + 1);
        vm.prank(proposer);
        token.acceptDefaultAdminTransfer();
        vm.expectRevert(BuildSTRNRoles.InvalidRoleAdministration.selector);
        builder.buildRoleBatch(token, c);
    }

    function testCompleteRecipeReturnsUnsentBatch() public {
        BuildSTRNRoles.RoleConfig memory c = _config();
        (STRN fresh, BuildSTRNRoles.RoleBatch memory batch) =
            new DeploySTRN().runWithRoles(new DeploySTRNImplementation().run(), treasury, recovery, 2 days, c);
        assertEq(fresh.defaultAdmin(), address(timelock));
        assertEq(fresh.balanceOf(treasury), fresh.INITIAL_SUPPLY());
        assertEq(batch.targets[0], address(fresh));
        assertFalse(timelock.isOperation(batch.operationId));
        assertFalse(fresh.hasRole(fresh.PAUSER_ROLE(), c.pauser));
        assertTrue(_send(proposer, batch.scheduleCalldata));
        vm.warp(vm.getBlockTimestamp() + 5 days);
        assertTrue(_send(treasury, batch.executeCalldata));
        assertTrue(fresh.hasRole(fresh.PAUSER_ROLE(), c.pauser));
    }
}
