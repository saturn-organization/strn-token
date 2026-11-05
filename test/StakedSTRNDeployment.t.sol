// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;
import {StakedSTRNFixture} from "./StakedSTRN.t.sol";
import {StakedSTRN} from "../src/StakedSTRN.sol";
import {DeployStakedSTRN, DeployStakedSTRNImplementation} from "../script/DeployStakedSTRN.s.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

contract StakedSTRNDeploymentTest is StakedSTRNFixture {
    function testFiveDayRoleAndCustodyActivation() public {
        address[] memory proposers = new address[](1);
        proposers[0] = alice;
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        TimelockController timelock = new TimelockController(5 days, proposers, executors, address(0));
        vm.prank(admin);
        token.beginDefaultAdminTransfer(address(timelock));
        vm.warp(vm.getBlockTimestamp() + 5 days + 1);
        vm.prank(address(timelock));
        token.acceptDefaultAdminTransfer();
        DeployStakedSTRN recipe = new DeployStakedSTRN();
        StakedSTRN impl = new DeployStakedSTRNImplementation().run();
        DeployStakedSTRN.Config memory c = DeployStakedSTRN.Config(
            block.chainid,
            address(timelock),
            alice,
            bob,
            carol,
            recovery,
            treasury,
            120 days,
            5 days,
            keccak256("sstrn rehearsal")
        );
        (StakedSTRN deployed, DeployStakedSTRN.Batch memory batch) = recipe.run(token, impl, c);
        assertEq(deployed.defaultAdmin(), address(timelock));
        assertFalse(token.isProtectedStakingCustody(address(deployed)));
        bytes32 slot = bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1);
        assertEq(ProxyAdmin(address(uint160(uint256(vm.load(address(deployed), slot))))).owner(), address(timelock));
        vm.prank(alice);
        (bool ok,) = address(timelock).call(batch.schedule);
        assertTrue(ok);
        (ok,) = address(timelock).call(batch.execute);
        assertFalse(ok);
        vm.warp(vm.getBlockTimestamp() + 5 days);
        (ok,) = address(timelock).call(batch.execute);
        assertTrue(ok);
        assertTrue(timelock.isOperationDone(batch.operationId));
        assertTrue(token.isProtectedStakingCustody(address(deployed)));
        assertTrue(deployed.hasRole(deployed.PAUSER_ROLE(), bob));
        assertTrue(deployed.hasRole(deployed.UNPAUSER_ROLE(), carol));
        assertTrue(deployed.hasRole(deployed.SEIZER_ROLE(), recovery));
        assertTrue(deployed.hasRole(deployed.PARAMETER_MANAGER_ROLE(), address(timelock)));
        assertFalse(deployed.hasRole(deployed.UNPAUSER_ROLE(), bob));
        vm.prank(alice);
        token.approve(address(deployed), 1 ether);
        vm.prank(alice);
        uint256 id = deployed.stake(1 ether);
        assertEq(deployed.totalSupply(), 1 ether);
        (ok,) = address(timelock).call(batch.execute);
        assertFalse(ok);
        vm.prank(admin);
        token.setBlacklisted(alice, true);
        vm.prank(recovery);
        deployed.recoverPosition(id);
        _checkImmediateRelease(timelock, deployed, id);
        c.chainId++;
        vm.expectRevert(DeployStakedSTRN.InvalidConfiguration.selector);
        recipe.run(token, impl, c);
        c.chainId = block.chainid;
        vm.prank(address(timelock));
        timelock.updateDelay(4 days);
        vm.expectRevert(DeployStakedSTRN.InvalidConfiguration.selector);
        recipe.run(token, impl, c);
    }

    function _checkImmediateRelease(TimelockController timelock, StakedSTRN deployed, uint256 id) private {
        assertTrue(deployed.hasRole(deployed.RELEASER_ROLE(), treasury));
        assertFalse(deployed.hasRole(deployed.RELEASER_ROLE(), recovery));
        assertFalse(deployed.hasRole(deployed.RELEASER_ROLE(), address(timelock)));
        vm.prank(recovery);
        vm.expectRevert();
        deployed.releasePosition(id, bob, false);
        vm.prank(address(timelock));
        vm.expectRevert();
        deployed.releasePosition(id, bob, false);
        uint48 maturity = deployed.position(id).unlockAt;
        uint256 releaseAt = vm.getBlockTimestamp();
        vm.prank(treasury);
        deployed.releasePosition(id, bob, false);
        assertEq(vm.getBlockTimestamp(), releaseAt);
        assertEq(deployed.position(id).owner, bob);
        assertEq(deployed.position(id).unlockAt, maturity);
        assertEq(deployed.getVotes(bob), 1 ether);
        assertEq(deployed.recoveredPrincipal(), 0);
        vm.prank(treasury);
        vm.expectRevert();
        deployed.releasePosition(id, bob, false);
    }
}
