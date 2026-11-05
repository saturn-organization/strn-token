// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;
import {StakedSTRNFixture} from "./StakedSTRN.t.sol";
import {IStakedSTRN} from "../src/interfaces/IStakedSTRN.sol";

contract StakedSTRNInterfaceTest is StakedSTRNFixture {
    function testConsumerLifecycleAndPositionDecoding() public {
        IStakedSTRN consumer = IStakedSTRN(address(stakeToken));
        vm.prank(alice);
        uint256 id = consumer.stake(6000 ether);
        IStakedSTRN.Position memory p = consumer.position(id);
        assertEq(p.owner, alice);
        assertEq(p.index, 0);
        assertEq(p.principal, 6000 ether);
        assertEq(p.unlockAt, vm.getBlockTimestamp() + consumer.lockDuration());
        assertEq(consumer.asset(), address(token));
        assertEq(consumer.balanceOf(alice), 6000 ether);
        assertEq(consumer.activeBalanceOf(alice), 6000 ether);
        assertEq(consumer.getFeeDiscountBps(alice), 150);
        assertEq(consumer.positionIds(alice)[0], id);
        assertEq(consumer.principalLiability(), consumer.totalSupply());
        vm.prank(alice);
        consumer.delegate(bob);
        uint48 at = consumer.clock();
        vm.warp(p.unlockAt);
        assertEq(consumer.getPastVotes(bob, at), 6000 ether);
        assertEq(consumer.maturedBalanceOf(alice), 6000 ether);
        vm.prank(alice);
        uint256 renewed = consumer.renew(id, 1000 ether);
        assertTrue(renewed != id);
        assertEq(consumer.position(renewed).principal, 1000 ether);
        vm.prank(alice);
        consumer.redeem(id, 5000 ether);
        assertEq(consumer.totalSupply(), 1000 ether);
        assertEq(consumer.getVotes(bob), 1000 ether);
    }

    function testConsumerRecoveryHistory() public {
        IStakedSTRN consumer = IStakedSTRN(address(stakeToken));
        uint256 id = _stake(alice, 5000 ether);
        vm.startPrank(admin);
        token.setBlacklisted(alice, true);
        stakeToken.recoverPosition(id);
        vm.stopPrank();
        assertEq(consumer.position(id).owner, address(consumer));
        assertEq(consumer.recoveredPrincipal(), 5000 ether);
        assertEq(consumer.getVotes(alice), 0);
        uint48 at = consumer.clock();
        vm.warp(at + 1);
        assertEq(consumer.getPastRecoveredPrincipal(at), 5000 ether);
        assertEq(consumer.getPastTotalSupply(at), 5000 ether);
    }
}
