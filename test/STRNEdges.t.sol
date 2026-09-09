// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;
import {STRNFixture} from "./STRN.t.sol";
import {STRNV2} from "./fixtures/STRNV2.sol";
import {STRN} from "../src/STRN.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract STRNEdges is STRNFixture {
    function testNamespaceRootMatchesActualStorage() public {
        bytes32 root = keccak256(abi.encode(uint256(keccak256("saturn.storage.STRN")) - 1)) & ~bytes32(uint256(255));
        assertEq(address(uint160(uint256(vm.load(address(token), bytes32(uint256(root) + 1))))), recipient);
        vm.prank(admin);
        token.setBlacklisted(alice, true);
        assertEq(uint256(vm.load(address(token), keccak256(abi.encode(alice, root)))), 1);
        address custody = address(new STRN());
        vm.prank(admin);
        token.setStakingCustodyProtection(custody, true);
        assertEq(uint256(vm.load(address(token), keccak256(abi.encode(custody, uint256(root) + 2)))), 1);
    }

    function testFiniteAllowanceRollbackOnInsufficientBalance() public {
        vm.prank(alice);
        token.approve(spender, 2000 ether);
        vm.prank(spender);
        vm.expectRevert();
        token.transferFrom(alice, bob, 1001 ether);
        assertEq(token.allowance(alice, spender), 2000 ether);
        assertEq(token.balanceOf(alice), 1000 ether);
        vm.prank(spender);
        vm.expectRevert();
        token.transferFrom(alice, bob, 2001 ether);
        assertEq(token.allowance(alice, spender), 2000 ether);
    }

    function testDistinctRoleDomainsAndEmergencyRecovery() public {
        bytes32 pauseRole = token.PAUSER_ROLE();
        bytes32 blackRole = token.BLACKLISTER_ROLE();
        bytes32 seizeRole = token.SEIZER_ROLE();
        vm.startPrank(admin);
        token.grantRole(pauseRole, alice);
        token.grantRole(blackRole, bob);
        token.grantRole(seizeRole, spender);
        vm.stopPrank();
        vm.startPrank(alice);
        token.pause();
        vm.expectRevert();
        token.setBlacklisted(bob, true);
        vm.expectRevert();
        token.seize(bob, 1);
        vm.stopPrank();
        vm.startPrank(bob);
        token.setBlacklisted(alice, true);
        vm.expectRevert();
        token.unpause();
        vm.expectRevert();
        token.seize(alice, 1);
        vm.stopPrank();
        vm.prank(spender);
        token.seize(alice, 1);
        vm.prank(admin);
        vm.expectRevert(STRN.CannotBlacklistAdmin.selector);
        token.setBlacklisted(admin, true);
        // Restrictions concern token movement, not administrative recovery.
        vm.prank(admin);
        token.revokeRole(pauseRole, alice);
        vm.prank(admin);
        token.unpause();
        assertFalse(token.paused());
    }

    function testBlacklistIdempotencyAndZeroTransferEvents() public {
        vm.startPrank(admin);
        token.setBlacklisted(alice, true);
        vm.recordLogs();
        token.setBlacklisted(alice, true);
        assertEq(vm.getRecordedLogs().length, 0);
        token.setBlacklisted(alice, false);
        vm.stopPrank();
        vm.recordLogs();
        vm.prank(alice);
        token.transfer(bob, 0);
        assertEq(vm.getRecordedLogs().length, 1);
    }

    function testAdminTransferCancellationAndRenunciation() public {
        vm.startPrank(admin);
        token.beginDefaultAdminTransfer(bob);
        token.cancelDefaultAdminTransfer();
        vm.stopPrank();
        vm.warp(block.timestamp + 3 days);
        vm.prank(bob);
        vm.expectRevert();
        token.acceptDefaultAdminTransfer();
        vm.startPrank(admin);
        vm.expectRevert();
        token.renounceRole(bytes32(0), admin);
        token.beginDefaultAdminTransfer(address(0));
        vm.stopPrank();
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(admin);
        token.renounceRole(bytes32(0), admin);
        assertEq(token.defaultAdmin(), address(0));
        // Renouncing admin does not remove separately held operator roles or ProxyAdmin owner.
        assertTrue(token.hasRole(token.PAUSER_ROLE(), admin));
        assertEq(proxyAdmin.owner(), upgradeOwner);
    }

    function testRejectedUpgradeIsAtomicAndProxyAdminCannotFallback() public {
        bytes32 implementationSlot = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
        bytes32 original = vm.load(address(token), implementationSlot);
        vm.prank(upgradeOwner);
        vm.expectRevert();
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(token)), address(0x123), "");
        assertEq(vm.load(address(token), implementationSlot), original);
        STRNV2 v2 = new STRNV2();
        vm.prank(upgradeOwner);
        vm.expectRevert();
        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(address(token)),
            address(v2),
            abi.encodeCall(STRN.initialize, (bob, bob, bob, uint48(0)))
        );
        assertEq(vm.load(address(token), implementationSlot), original);
        assertEq(token.balanceOf(alice), 1000 ether);
        vm.prank(address(proxyAdmin));
        vm.expectRevert();
        token.transfer(bob, 0);
    }

    function testSeizedSourceApprovalsRemainExplicitlyRestorable() public {
        vm.prank(alice);
        token.approve(spender, 50);
        vm.startPrank(admin);
        token.setBlacklisted(alice, true);
        token.seize(alice, 1000 ether);
        token.setBlacklisted(alice, false);
        vm.stopPrank();
        vm.prank(treasury);
        token.transfer(alice, 50);
        vm.prank(spender);
        token.transferFrom(alice, bob, 50);
        assertEq(token.balanceOf(bob), 50);
        assertEq(token.allowance(alice, spender), 0);
    }
}
