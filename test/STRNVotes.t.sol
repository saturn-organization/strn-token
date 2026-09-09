// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;
import {STRNV2} from "./fixtures/STRNV2.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {STRNFixture} from "./STRN.t.sol";
import {StakedSTRNFixture} from "./StakedSTRN.t.sol";

contract STRNVotesTest is STRNFixture {
    function testHistoryDelegationAndSupply() public {
        vm.warp(100);
        vm.prank(alice);
        token.delegate(bob);
        assertEq(token.getVotes(bob), 1000 ether);
        vm.warp(101);
        vm.prank(alice);
        token.transfer(spender, 300 ether);
        vm.prank(spender);
        token.delegate(spender);
        vm.warp(102);
        assertEq(token.getPastVotes(bob, 100), 1000 ether);
        assertEq(token.getPastVotes(bob, 101), 700 ether);
        assertEq(token.getPastVotes(spender, 101), 300 ether);
        assertEq(token.getPastTotalSupply(100), token.INITIAL_SUPPLY());
        assertEq(token.clock(), 102);
        assertEq(token.CLOCK_MODE(), "mode=timestamp");
        vm.expectRevert();
        token.getPastVotes(bob, 102);
    }

    function testRecoveryCannotEscapeAndRotationDoesNotUnlock() public {
        vm.warp(100);
        vm.prank(alice);
        token.delegate(bob);
        vm.prank(recipient);
        token.delegate(recipient);
        vm.startPrank(admin);
        token.grantRole(token.RELEASER_ROLE(), spender);
        token.setBlacklisted(alice, true);
        token.pause();
        token.seize(alice, 600 ether);
        token.setSeizureRecipient(treasury);
        token.unpause();
        vm.stopPrank();
        assertEq(token.getVotes(bob), 400 ether);
        assertEq(token.getVotes(recipient), 0);
        assertEq(token.recoveredBalanceOf(recipient), 600 ether);
        vm.startPrank(recipient);
        token.approve(spender, 600 ether);
        vm.expectRevert();
        token.transfer(bob, 1);
        token.delegate(bob);
        assertEq(token.getVotes(bob), 400 ether);
        vm.stopPrank();
        vm.prank(spender);
        vm.expectRevert();
        token.transferFrom(recipient, bob, 1);
        assertEq(token.allowance(recipient, spender), 600 ether);
        vm.prank(admin);
        vm.expectRevert();
        token.releaseRecovered(recipient, bob, 1);
        vm.prank(bob);
        token.delegate(bob);
        vm.prank(admin);
        token.pause();
        vm.prank(spender);
        token.releaseRecovered(recipient, bob, 200 ether);
        assertEq(token.getVotes(bob), 600 ether);
        assertEq(token.recoveredPrincipal(), 400 ether);
        vm.warp(101);
        assertEq(token.getPastRecoveredPrincipal(100), 400 ether);
        assertEq(token.getPastTotalSupply(100), token.INITIAL_SUPPLY());
    }

    function testMixedRecoveryOnlyLocksSeizedPortion() public {
        vm.prank(alice);
        token.transfer(recipient, 100 ether);
        vm.prank(recipient);
        token.delegate(recipient);
        vm.startPrank(admin);
        token.setBlacklisted(alice, true);
        token.seize(alice, 400 ether);
        vm.stopPrank();
        assertEq(token.getVotes(recipient), 100 ether);
        vm.prank(recipient);
        token.transfer(bob, 100 ether);
        assertEq(token.getVotes(recipient), 0);
        assertEq(token.balanceOf(recipient), 400 ether);
        vm.prank(recipient);
        vm.expectRevert();
        token.transfer(bob, 1);
    }

    function testFundedCustodyClearsOutgoingVotes() public {
        vm.etch(spender, hex"00");
        vm.prank(alice);
        token.transfer(spender, 100 ether);
        vm.prank(spender);
        token.delegate(bob);
        assertEq(token.getVotes(bob), 100 ether);
        vm.prank(admin);
        token.setStakingCustodyProtection(spender, true);
        assertEq(token.getVotes(bob), 0);
        vm.prank(spender);
        vm.expectRevert();
        token.delegate(bob);
        vm.prank(alice);
        token.delegate(alice);
        vm.prank(spender);
        token.transfer(alice, 100 ether);
        assertEq(token.getVotes(alice), 1000 ether);
    }

    function testReleaseValidationAndRecoverySourceRestrictions() public {
        vm.startPrank(admin);
        token.grantRole(token.RELEASER_ROLE(), spender);
        token.setBlacklisted(alice, true);
        token.seize(alice, 500 ether);
        token.setBlacklisted(recipient, true);
        token.setSeizureRecipient(treasury);
        vm.expectRevert();
        token.seize(recipient, 1);
        vm.stopPrank();
        vm.startPrank(spender);
        vm.expectRevert();
        token.releaseRecovered(recipient, bob, 501 ether);
        vm.expectRevert();
        token.releaseRecovered(recipient, alice, 1);
        vm.expectRevert();
        token.releaseRecovered(recipient, address(0), 1);
        vm.expectRevert();
        token.releaseRecovered(recipient, bob, 0);
        vm.stopPrank();
        vm.prank(admin);
        token.setStakingCustodyProtection(address(implementation), true);
        vm.prank(spender);
        vm.expectRevert();
        token.releaseRecovered(recipient, address(implementation), 1);
        vm.prank(spender);
        token.releaseRecovered(recipient, bob, 500 ether);
        assertEq(token.recoveredPrincipal(), 0);
        assertEq(token.balanceOf(bob), 500 ether);
    }

    function testCompatibleUpgradePreservesVotesNonceAndRecovery() public {
        vm.warp(100);
        testSignedDelegationReplay();
        vm.prank(alice);
        token.delegate(bob);
        vm.startPrank(admin);
        token.grantRole(token.RELEASER_ROLE(), spender);
        token.setBlacklisted(alice, true);
        token.seize(alice, 500 ether);
        vm.stopPrank();
        vm.warp(101);
        STRNV2 next = new STRNV2();
        vm.prank(upgradeOwner);
        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(address(token)), address(next), abi.encodeCall(STRNV2.initializeV2, (42))
        );
        assertEq(token.nonces(vm.addr(12345)), 1);
        assertEq(token.getPastVotes(bob, 100), 500 ether);
        assertEq(token.getPastRecoveredPrincipal(100), 500 ether);
        assertEq(token.getPastTotalSupply(100), token.INITIAL_SUPPLY());
        assertEq(token.recoveredBalanceOf(recipient), 500 ether);
        vm.prank(spender);
        token.releaseRecovered(recipient, bob, 500 ether);
        vm.prank(bob);
        token.delegate(bob);
        assertEq(token.getVotes(bob), 1000 ether);
    }

    function testSignedDelegationReplay() public {
        uint256 key = 12345;
        address signer = vm.addr(key);
        vm.prank(alice);
        token.transfer(signer, 100 ether);
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Saturn"),
                keccak256("1"),
                block.chainid,
                address(token)
            )
        );
        bytes32 body = keccak256(
            abi.encode(
                keccak256("Delegation(address delegatee,uint256 nonce,uint256 expiry)"),
                bob,
                uint256(0),
                block.timestamp + 1 days
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, keccak256(abi.encodePacked(hex"1901", domain, body)));
        token.delegateBySig(bob, 0, block.timestamp + 1 days, v, r, s);
        assertEq(token.getVotes(bob), 100 ether);
        vm.expectRevert();
        token.delegateBySig(bob, 0, block.timestamp + 1 days, v, r, s);
    }
}

contract CombinedSTRNVotesTest is StakedSTRNFixture {
    function testStakeRecoveryReleaseRedemptionNeverDuplicatesVotes() public {
        vm.prank(alice);
        token.delegate(alice);
        uint256 initial = token.getVotes(alice);
        uint256 id = _stake(alice, 600 ether);
        assertEq(token.getVotes(alice) + stakeToken.getVotes(alice), initial);
        vm.prank(alice);
        token.transfer(address(stakeToken), 100 ether);
        assertEq(token.getVotes(address(stakeToken)), 0);
        vm.startPrank(admin);
        token.setBlacklisted(alice, true);
        stakeToken.recoverPosition(id);
        vm.stopPrank();
        assertEq(stakeToken.getVotes(alice), 0);
        assertEq(token.getVotes(alice), initial - 700 ether);
        vm.prank(bob);
        token.delegate(bob);
        uint256 bobBefore = token.getVotes(bob);
        vm.prank(admin);
        stakeToken.releasePosition(id, bob, false);
        assertEq(stakeToken.getVotes(bob), 600 ether);
        vm.warp(block.timestamp + 120 days);
        vm.prank(bob);
        stakeToken.redeem(id, 600 ether);
        assertEq(stakeToken.getVotes(bob), 0);
        assertEq(token.getVotes(bob), bobBefore + 600 ether);
    }
}
