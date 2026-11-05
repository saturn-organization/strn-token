// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;
import {STRNFixture} from "./STRN.t.sol";
import {STRN} from "../src/STRN.sol";

contract CustodyAccount {}

contract STRNPolicy is STRNFixture {
    event SeizureRecipientUpdated(address indexed previousRecipient, address indexed newRecipient);
    event StakingCustodyProtectionUpdated(address indexed account, bool protected);

    function testPauseRolesAreIndependent() public {
        bytes32 pauser = token.PAUSER_ROLE();
        bytes32 unpauser = token.UNPAUSER_ROLE();
        vm.startPrank(admin);
        token.grantRole(pauser, alice);
        token.grantRole(unpauser, bob);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert();
        token.pause();
        vm.startPrank(alice);
        token.pause();
        vm.expectRevert();
        token.unpause();
        vm.stopPrank();
        vm.prank(bob);
        token.unpause();
        assertFalse(token.paused());
    }

    function testRecoveryRotationDuringPauseAndBlacklistRevalidation() public {
        bytes32 manager = token.PARAMETER_MANAGER_ROLE();
        vm.startPrank(admin);
        token.grantRole(manager, bob);
        token.setBlacklisted(alice, true);
        token.seize(alice, 10);
        token.pause();
        vm.stopPrank();
        vm.prank(bob);
        vm.expectEmit(true, true, false, true, address(token));
        emit SeizureRecipientUpdated(recipient, spender);
        token.setSeizureRecipient(spender);
        assertEq(token.balanceOf(recipient), 10);
        vm.startPrank(admin);
        token.seize(alice, 20);
        token.setBlacklisted(spender, true);
        vm.expectRevert(abi.encodeWithSelector(STRN.AccountBlacklisted.selector, spender));
        token.seize(alice, 1);
        vm.stopPrank();
        assertEq(token.balanceOf(spender), 20);
        assertEq(token.balanceOf(alice), 1000 ether - 30);
        assertTrue(token.paused());
    }

    function testRecoveryValidationAndNoImplicitSeizerConfigurationPower() public {
        bytes32 seizer = token.SEIZER_ROLE();
        vm.prank(admin);
        token.grantRole(seizer, bob);
        vm.prank(bob);
        vm.expectRevert();
        token.setSeizureRecipient(bob);
        vm.startPrank(admin);
        vm.expectRevert();
        token.setSeizureRecipient(address(0));
        vm.expectRevert();
        token.setSeizureRecipient(address(token));
        token.setBlacklisted(alice, true);
        vm.expectRevert();
        token.setSeizureRecipient(alice);
        address custody = address(new CustodyAccount());
        token.setStakingCustodyProtection(custody, true);
        vm.expectRevert();
        token.setSeizureRecipient(custody);
        vm.stopPrank();
        assertEq(token.seizureRecipient(), recipient);
    }

    function testAdminProtectionAcrossHandoff() public {
        vm.startPrank(admin);
        vm.expectRevert(STRN.CannotBlacklistAdmin.selector);
        token.setBlacklisted(admin, true);
        token.setBlacklisted(bob, true);
        token.beginDefaultAdminTransfer(bob);
        vm.stopPrank();
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(STRN.AccountBlacklisted.selector, bob));
        token.acceptDefaultAdminTransfer();
        assertEq(token.defaultAdmin(), admin);
        vm.prank(admin);
        token.setBlacklisted(bob, false);
        vm.prank(bob);
        token.acceptDefaultAdminTransfer();
        vm.startPrank(admin); // Existing blacklister authority survives handoff.
        vm.expectRevert(STRN.CannotBlacklistAdmin.selector);
        token.setBlacklisted(bob, true);
        token.setBlacklisted(admin, true);
        vm.stopPrank();
        assertEq(token.defaultAdmin(), bob);
    }

    function testCustodyRegistrationControlsAndIdempotency() public {
        address custody = address(new CustodyAccount());
        vm.prank(alice);
        vm.expectRevert();
        token.setStakingCustodyProtection(custody, true);
        vm.startPrank(admin);
        vm.expectRevert();
        token.setStakingCustodyProtection(alice, true);
        vm.expectRevert();
        token.setStakingCustodyProtection(address(0), true);
        vm.expectRevert();
        token.setStakingCustodyProtection(address(token), true);
        token.setSeizureRecipient(custody);
        vm.expectRevert();
        token.setStakingCustodyProtection(custody, true);
        token.setSeizureRecipient(recipient);
        vm.expectEmit(true, false, false, true, address(token));
        emit StakingCustodyProtectionUpdated(custody, true);
        token.setStakingCustodyProtection(custody, true);
        vm.recordLogs();
        token.setStakingCustodyProtection(custody, true);
        assertEq(vm.getRecordedLogs().length, 0);
        token.setStakingCustodyProtection(custody, false);
        assertFalse(token.isProtectedStakingCustody(custody));
        vm.stopPrank();
    }

    function testFuzzCustodyProtectionPreservesFundsWithoutTransferExemption(uint256 amount, bool pause_) public {
        amount = bound(amount, 1, 1000 ether);
        address custody = address(new CustodyAccount());
        vm.prank(admin);
        token.setStakingCustodyProtection(custody, true);
        vm.prank(alice);
        token.transfer(custody, amount);
        vm.startPrank(admin);
        token.setBlacklisted(custody, true);
        if (pause_) token.pause();
        vm.expectRevert(abi.encodeWithSelector(STRN.ProtectedStakingCustody.selector, custody));
        token.seize(custody, amount);
        vm.expectRevert(abi.encodeWithSelector(STRN.FundedStakingCustody.selector, custody));
        token.setStakingCustodyProtection(custody, false);
        vm.stopPrank();
        vm.prank(custody);
        token.approve(spender, amount);
        vm.prank(spender);
        vm.expectRevert();
        token.transferFrom(custody, bob, amount);
        assertEq(token.allowance(custody, spender), amount);
        assertEq(token.balanceOf(custody), amount);
        vm.startPrank(admin);
        token.setBlacklisted(custody, false);
        vm.stopPrank();
        if (pause_) {
            vm.prank(custody);
            vm.expectRevert();
            token.transfer(bob, amount);
            vm.prank(admin);
            token.unpause();
        }
        vm.prank(custody);
        token.transfer(bob, amount);
        vm.prank(admin);
        token.setStakingCustodyProtection(custody, false);
        assertEq(token.balanceOf(bob), amount);
        assertFalse(token.isProtectedStakingCustody(custody));
    }
}
