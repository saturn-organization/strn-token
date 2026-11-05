// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;
import {STRNFixture} from "./STRN.t.sol";
import {STRN} from "../src/STRN.sol";
import {StakingBoundary} from "./fixtures/StakingBoundary.sol";

contract STRNStakingBoundaryTest is STRNFixture {
    function testPositionRecoveryKeepsBackingMaturityAndAssociatedRecords() public {
        StakingBoundary staking = new StakingBoundary(token, admin);
        vm.prank(admin);
        token.setStakingCustodyProtection(address(staking), true);
        uint256 maturity = block.timestamp + 100 days; // arbitrary fixture duration, not four-month policy
        vm.startPrank(alice);
        token.approve(address(staking), 200);
        uint256 first = staking.stake(100, maturity);
        uint256 second = staking.stake(100, maturity + 1 days);
        token.transfer(bob, 100);
        vm.stopPrank();
        vm.startPrank(bob);
        token.approve(address(staking), 100);
        uint256 other = staking.stake(100, maturity);
        vm.stopPrank();
        vm.startPrank(admin);
        staking.recordReward(first, 17);
        token.setBlacklisted(alice, true);
        token.setBlacklisted(address(staking), true);
        token.pause();
        vm.expectRevert(abi.encodeWithSelector(STRN.ProtectedStakingCustody.selector, address(staking)));
        token.seize(address(staking), 100);
        staking.recoverPosition(first);
        vm.stopPrank();
        (address owner, uint256 principal, uint256 unlockAt, uint256 rewardRecord) = staking.positions(first);
        assertEq(owner, recipient);
        assertEq(principal, 100);
        assertEq(unlockAt, maturity);
        assertEq(rewardRecord, 17);
        assertEq(staking.claimWeight(alice), 100);
        assertEq(staking.claimWeight(recipient), 100);
        assertEq(staking.claimWeight(bob), 100);
        assertEq(staking.principalLiability(), 300);
        assertEq(token.balanceOf(address(staking)), 300);
        (owner,,,) = staking.positions(second);
        assertEq(owner, alice);
        vm.prank(recipient);
        vm.expectRevert();
        staking.redeem(first); // recovery did not shorten the lock
        vm.warp(maturity);
        vm.prank(recipient);
        vm.expectRevert();
        staking.redeem(first); // pause/blacklist cannot be bypassed by recovering a position
        (owner,,,) = staking.positions(first);
        assertEq(owner, recipient);
        assertEq(staking.principalLiability(), 300);
        vm.startPrank(admin);
        token.unpause();
        token.setBlacklisted(address(staking), false);
        vm.stopPrank();
        vm.prank(recipient);
        staking.redeem(first);
        vm.prank(bob);
        staking.redeem(other);
        assertEq(token.balanceOf(recipient), 100);
        assertEq(token.balanceOf(bob), 100);
        assertEq(staking.principalLiability(), 100);
        assertEq(token.balanceOf(address(staking)), 100);
    }

    function testUnprotectedCustodyCannotAcceptNewPositions() public {
        StakingBoundary staking = new StakingBoundary(token, admin);
        vm.startPrank(alice);
        token.approve(address(staking), 100);
        vm.expectRevert();
        staking.stake(100, block.timestamp + 1 days);
        vm.stopPrank();
        assertEq(staking.principalLiability(), 0);
        assertEq(token.balanceOf(address(staking)), 0);
    }
}
