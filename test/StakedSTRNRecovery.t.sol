// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;
import {StakedSTRNFixture} from "./StakedSTRN.t.sol";
import {StakedSTRN} from "../src/StakedSTRN.sol";

contract StakedSTRNRecoveryTest is StakedSTRNFixture {
    function _recover(uint256 id) internal {
        vm.startPrank(admin);
        token.setBlacklisted(stakeToken.position(id).owner, true);
        stakeToken.recoverPosition(id);
        vm.stopPrank();
    }

    function testSeizureReleaseSnapshotsPreserveDenominatorAndDelegation() public {
        uint256 id = _stake(alice, 6000 ether);
        _stake(bob, 4000 ether);
        vm.prank(alice);
        stakeToken.delegate(carol);
        uint256 beforeSeizure = vm.getBlockTimestamp();
        vm.warp(beforeSeizure + 1);
        _recover(id);
        uint256 seizedAt = vm.getBlockTimestamp();
        assertEq(stakeToken.getVotes(carol), 0);
        assertEq(stakeToken.getVotes(address(stakeToken)), 0);
        assertEq(stakeToken.recoveredPrincipal(), 6000 ether);
        assertEq(stakeToken.totalSupply(), 10_000 ether);
        vm.prank(recovery);
        stakeToken.delegate(carol);
        assertEq(stakeToken.getVotes(carol), 0);
        vm.prank(bob);
        stakeToken.delegate(carol);
        vm.warp(seizedAt + 1);
        vm.prank(admin);
        stakeToken.releasePosition(id, bob, false);
        uint256 releasedAt = vm.getBlockTimestamp();
        assertEq(stakeToken.getVotes(carol), 10_000 ether);
        assertEq(stakeToken.recoveredPrincipal(), 0);
        assertEq(stakeToken.positionIds(bob).length, 2);
        assertEq(stakeToken.position(id).unlockAt, beforeSeizure + 120 days);
        vm.warp(releasedAt + 1);
        assertEq(stakeToken.getPastVotes(carol, beforeSeizure), 6000 ether);
        assertEq(stakeToken.getPastVotes(carol, seizedAt), 4000 ether);
        assertEq(stakeToken.getPastVotes(carol, releasedAt), 10_000 ether);
        assertEq(stakeToken.getPastTotalSupply(beforeSeizure), 10_000 ether);
        assertEq(stakeToken.getPastTotalSupply(seizedAt), 10_000 ether);
        assertEq(stakeToken.getPastTotalSupply(releasedAt), 10_000 ether);
        assertEq(stakeToken.getPastRecoveredPrincipal(beforeSeizure), 0);
        assertEq(stakeToken.getPastRecoveredPrincipal(seizedAt), 6000 ether);
        assertEq(stakeToken.getPastRecoveredPrincipal(releasedAt), 0);
        vm.expectRevert();
        stakeToken.getPastRecoveredPrincipal(vm.getBlockTimestamp());
    }

    function testSameTimestampRecoveryHistoryUsesFinalState() public {
        uint256 a = _stake(alice, 6000 ether);
        uint256 b = _stake(bob, 4000 ether);
        uint256 beforeRecovery = vm.getBlockTimestamp();
        vm.warp(beforeRecovery + 1);
        _recover(a);
        _recover(b);
        vm.prank(admin);
        stakeToken.releasePosition(a, carol, false);
        uint256 at = vm.getBlockTimestamp();
        vm.warp(at + 1);
        assertEq(stakeToken.getPastTotalSupply(at), 10_000 ether);
        assertEq(stakeToken.getPastRecoveredPrincipal(at), 4000 ether);
        assertEq(stakeToken.getPastVotes(carol, at), 6000 ether);
        // Platform denominator derives from the same finalized timestamp; token supply is never rewritten.
        assertEq(stakeToken.getPastTotalSupply(at) - stakeToken.getPastRecoveredPrincipal(at), 6000 ether);
        assertEq(stakeToken.getPastRecoveredPrincipal(beforeRecovery), 0);
    }

    function testRecoveryHasNoUtilityOrWalletEscapeAndRequiresReleaseRole() public {
        uint256 id = _stake(alice, 10_000 ether);
        _recover(id);
        assertEq(stakeToken.positionIds(alice).length, 0);
        assertEq(stakeToken.positionIds(address(stakeToken)).length, 0);
        assertEq(stakeToken.activeBalanceOf(address(stakeToken)), 0);
        assertEq(stakeToken.maturedBalanceOf(address(stakeToken)), 0);
        assertEq(stakeToken.getFeeDiscountBps(address(stakeToken)), 0);
        vm.prank(admin);
        token.setSeizureRecipient(bob);
        vm.startPrank(admin);
        stakeToken.grantRole(stakeToken.SEIZER_ROLE(), carol);
        vm.stopPrank();
        vm.prank(carol);
        vm.expectRevert();
        stakeToken.releasePosition(id, bob, false);
        vm.prank(bob);
        vm.expectRevert();
        stakeToken.releasePosition(id, bob, false);
        vm.prank(admin);
        vm.expectRevert(StakedSTRN.InvalidRecovery.selector);
        stakeToken.recoverPosition(id);
        vm.warp(stakeToken.position(id).unlockAt);
        vm.prank(recovery);
        vm.expectRevert();
        stakeToken.redeem(id, 10_000 ether);
        vm.prank(bob);
        vm.expectRevert();
        stakeToken.renew(id, 10_000 ether);
        // Even custody impersonation cannot delegate or use ordinary owner operations.
        vm.startPrank(address(stakeToken));
        vm.expectRevert(StakedSTRN.InvalidAddress.selector);
        stakeToken.delegate(bob);
        vm.expectRevert(StakedSTRN.InvalidAddress.selector);
        stakeToken.redeem(id, 10_000 ether);
        vm.expectRevert(StakedSTRN.InvalidAddress.selector);
        stakeToken.renew(id, 10_000 ether);
        vm.stopPrank();
        assertEq(stakeToken.getVotes(bob), 0);
        assertEq(stakeToken.recoveredPrincipal(), 10_000 ether);
    }

    function testReleaseRoleGrantAndRevocationDoNotConflateAuthority() public {
        uint256 id = _stake(alice, 1 ether);
        _recover(id);
        vm.startPrank(admin);
        stakeToken.revokeRole(stakeToken.RELEASER_ROLE(), admin);
        vm.expectRevert();
        stakeToken.releasePosition(id, bob, false);
        stakeToken.grantRole(stakeToken.RELEASER_ROLE(), carol);
        vm.stopPrank();
        vm.prank(carol);
        vm.expectRevert();
        stakeToken.recoverPosition(id);
        vm.prank(carol);
        stakeToken.releasePosition(id, bob, false);
        _recover(id);
        vm.startPrank(admin);
        stakeToken.revokeRole(stakeToken.RELEASER_ROLE(), carol);
        vm.stopPrank();
        vm.prank(carol);
        vm.expectRevert();
        stakeToken.releasePosition(id, recovery, false);
        assertEq(stakeToken.recoveredPrincipal(), 1 ether);
    }

    function testMatureUnderlyingReleaseAtomicRollbackAndReplay() public {
        uint256 id = _stake(alice, 6000 ether);
        uint48 end = stakeToken.position(id).unlockAt;
        _recover(id);
        vm.startPrank(admin);
        vm.expectRevert(StakedSTRN.PositionNotMature.selector);
        stakeToken.releasePosition(id, bob, true);
        vm.warp(end);
        token.pause();
        stakeToken.pause();
        vm.expectRevert();
        stakeToken.releasePosition(id, bob, true);
        assertEq(stakeToken.recoveredPrincipal(), 6000 ether);
        assertEq(stakeToken.position(id).principal, 6000 ether);
        token.unpause();
        token.setBlacklisted(address(stakeToken), true);
        vm.expectRevert();
        stakeToken.releasePosition(id, bob, true);
        token.setBlacklisted(address(stakeToken), false);
        uint256 beforeBalance = token.balanceOf(bob);
        stakeToken.releasePosition(id, bob, true);
        assertEq(token.balanceOf(bob), beforeBalance + 6000 ether);
        assertEq(stakeToken.totalSupply(), 0);
        assertEq(stakeToken.recoveredPrincipal(), 0);
        assertEq(stakeToken.position(id).owner, address(0));
        vm.expectRevert(StakedSTRN.InvalidRecovery.selector);
        stakeToken.releasePosition(id, bob, true);
        vm.stopPrank();
        vm.warp(end + 1);
        assertEq(stakeToken.getPastTotalSupply(end), 0);
        assertEq(stakeToken.getPastRecoveredPrincipal(end), 0);
    }

    function testReleaseValidatesDestinationAndNormalCapacity() public {
        uint256 id = _stake(alice, 5000 ether);
        for (uint256 i; i < 32; ++i) {
            _stake(bob, 1 ether);
        }
        _recover(id);
        vm.startPrank(admin);
        vm.expectRevert(StakedSTRN.InvalidAddress.selector);
        stakeToken.releasePosition(id, address(0), false);
        vm.expectRevert(StakedSTRN.InvalidAddress.selector);
        stakeToken.releasePosition(id, address(stakeToken), false);
        vm.expectRevert();
        stakeToken.releasePosition(id, alice, false);
        token.setStakingCustodyProtection(address(implementation), true);
        vm.expectRevert(StakedSTRN.InvalidRecovery.selector);
        stakeToken.releasePosition(id, address(implementation), false);
        vm.expectRevert(StakedSTRN.TooManyPositions.selector);
        stakeToken.releasePosition(id, bob, false);
        assertEq(stakeToken.recoveredPrincipal(), 5000 ether);
        vm.warp(stakeToken.position(id).unlockAt);
        stakeToken.releasePosition(id, bob, true); // no ordinary slot required
        vm.stopPrank();
        assertEq(stakeToken.positionIds(bob).length, 32);
        assertEq(stakeToken.totalSupply(), 32 ether);
    }

    function testMoreThan32RecoveriesAndReleaseExistingId() public {
        uint256 first;
        for (uint256 i; i < 65; ++i) {
            vm.prank(admin);
            token.setBlacklisted(alice, false);
            uint256 id = _stake(alice, 1 ether);
            if (i == 0) first = id;
            _recover(id);
        }
        assertEq(stakeToken.recoveredPrincipal(), 65 ether);
        assertEq(stakeToken.positionIds(address(stakeToken)).length, 0);
        assertEq(stakeToken.positionIds(alice).length, 0);
        vm.prank(bob);
        stakeToken.delegate(address(0));
        vm.prank(admin);
        stakeToken.releasePosition(first, bob, false);
        assertEq(stakeToken.position(first).owner, bob);
        assertEq(stakeToken.getVotes(bob), 0); // preserve explicit opt-out
        assertEq(stakeToken.recoveredPrincipal(), 64 ether);
        vm.prank(bob);
        stakeToken.delegate(carol);
        assertEq(stakeToken.getVotes(carol), 1 ether);
        _recover(first); // released position can legitimately be seized again
        assertEq(stakeToken.getVotes(carol), 0);
        assertEq(stakeToken.recoveredPrincipal(), 65 ether);
    }

    function testReleaseBackToUnblacklistedOwnerPreservesMatureClaim() public {
        uint256 id = _stake(alice, 6000 ether);
        uint48 end = stakeToken.position(id).unlockAt;
        _recover(id);
        vm.warp(end);
        vm.startPrank(admin);
        token.setBlacklisted(alice, false);
        stakeToken.releasePosition(id, alice, false);
        vm.stopPrank();
        assertEq(stakeToken.position(id).unlockAt, end);
        assertEq(stakeToken.getVotes(alice), 6000 ether);
        assertEq(stakeToken.getFeeDiscountBps(alice), 0);
        vm.prank(alice);
        stakeToken.renew(id, 6000 ether);
        assertEq(stakeToken.getFeeDiscountBps(alice), 150);
    }
}
