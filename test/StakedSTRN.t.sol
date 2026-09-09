// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;
import {Test} from "forge-std/Test.sol";
import {STRN} from "../src/STRN.sol";
import {StakedSTRN} from "../src/StakedSTRN.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ISTRNDiscount} from "../src/interfaces/ISTRNDiscount.sol";

/// @dev Integration example only: no cumulative cap and no real vault settlement.
contract DiscountProductFixture {
    ISTRNDiscount public immutable discounts;

    constructor(ISTRNDiscount discounts_) {
        discounts = discounts_;
    }

    function quote(address beneficiary, uint256 nominalFee) external view returns (uint256) {
        return nominalFee - Math.mulDiv(nominalFee, discounts.getFeeDiscountBps(beneficiary), 10_000);
    }
}

abstract contract StakedSTRNFixture is Test {
    STRN internal token;
    StakedSTRN internal stakeToken;
    StakedSTRN internal implementation;
    address internal admin = address(0xA11);
    address internal treasury = address(0xC11);
    address internal recovery = address(0xD11);
    address internal alice = address(0xA1);
    address internal bob = address(0xB1);
    address internal carol = address(0xC1);

    function setUp() public virtual {
        vm.warp(1000);
        token = STRN(
            address(
                new TransparentUpgradeableProxy(
                    address(new STRN()),
                    admin,
                    abi.encodeCall(STRN.initialize, (admin, treasury, recovery, uint48(5 days)))
                )
            )
        );
        implementation = new StakedSTRN();
        stakeToken = StakedSTRN(
            address(
                new TransparentUpgradeableProxy(
                    address(implementation),
                    admin,
                    abi.encodeCall(StakedSTRN.initialize, (admin, address(token), uint48(120 days), uint48(5 days)))
                )
            )
        );
        vm.startPrank(admin);
        token.setStakingCustodyProtection(address(stakeToken), true);
        token.grantRole(token.PAUSER_ROLE(), admin);
        token.grantRole(token.UNPAUSER_ROLE(), admin);
        token.grantRole(token.BLACKLISTER_ROLE(), admin);
        token.grantRole(token.SEIZER_ROLE(), admin);
        token.grantRole(token.PARAMETER_MANAGER_ROLE(), admin);
        stakeToken.grantRole(stakeToken.PAUSER_ROLE(), admin);
        stakeToken.grantRole(stakeToken.UNPAUSER_ROLE(), admin);
        stakeToken.grantRole(stakeToken.PARAMETER_MANAGER_ROLE(), admin);
        stakeToken.grantRole(stakeToken.SEIZER_ROLE(), admin);
        stakeToken.grantRole(stakeToken.RELEASER_ROLE(), admin);
        vm.stopPrank();
        for (uint256 i; i < 3; ++i) {
            address who = i == 0 ? alice : i == 1 ? bob : carol;
            vm.prank(treasury);
            token.transfer(who, 1_000_000 ether);
            vm.prank(who);
            token.approve(address(stakeToken), type(uint256).max);
        }
    }

    function _stake(address who, uint256 amount) internal returns (uint256 id) {
        vm.prank(who);
        id = stakeToken.stake(amount);
    }
}

contract StakedSTRNTest is StakedSTRNFixture {
    function testInitializationAndNontransferability() public {
        assertEq(stakeToken.symbol(), "sSTRN");
        assertEq(stakeToken.decimals(), 18);
        assertEq(address(stakeToken.asset()), address(token));
        assertEq(stakeToken.lockDuration(), 120 days);
        assertEq(stakeToken.defaultAdmin(), admin);
        assertEq(stakeToken.CLOCK_MODE(), "mode=timestamp");
        vm.expectRevert();
        implementation.initialize(admin, address(token), 120 days, 0);
        vm.expectRevert();
        stakeToken.initialize(admin, address(token), 120 days, 0);
        _stake(alice, 100 ether);
        vm.startPrank(alice);
        vm.expectRevert(StakedSTRN.Nontransferable.selector);
        stakeToken.transfer(bob, 1);
        vm.expectRevert(StakedSTRN.Nontransferable.selector);
        stakeToken.transferFrom(alice, bob, 0);
        vm.expectRevert(StakedSTRN.Nontransferable.selector);
        stakeToken.approve(bob, 0);
        vm.stopPrank();
    }

    function testExactMaturityPartialRedeemRenewAndVotes() public {
        uint256 id = _stake(alice, 10_000 ether);
        uint48 end = stakeToken.position(id).unlockAt;
        vm.prank(alice);
        stakeToken.delegate(bob);
        assertEq(stakeToken.getVotes(bob), 10_000 ether);
        vm.warp(end - 1);
        assertEq(stakeToken.activeBalanceOf(alice), 10_000 ether);
        vm.prank(alice);
        vm.expectRevert(StakedSTRN.PositionNotMature.selector);
        stakeToken.redeem(id, 1);
        vm.warp(end);
        assertEq(stakeToken.activeBalanceOf(alice), 0);
        assertEq(stakeToken.getFeeDiscountBps(alice), 0);
        assertEq(stakeToken.getVotes(bob), 10_000 ether);
        vm.prank(alice);
        uint256 renewed = stakeToken.renew(id, 6000 ether);
        assertEq(stakeToken.maturedBalanceOf(alice), 4000 ether);
        assertEq(stakeToken.activeBalanceOf(alice), 6000 ether);
        assertEq(stakeToken.position(id).unlockAt, end);
        assertEq(stakeToken.position(renewed).unlockAt, end + 120 days);
        vm.prank(alice);
        stakeToken.redeem(id, 1000 ether);
        assertEq(stakeToken.getVotes(bob), 9000 ether);
        assertEq(stakeToken.principalLiability(), 9000 ether);
        vm.prank(alice);
        stakeToken.redeem(id, 3000 ether);
        assertEq(stakeToken.positionIds(alice).length, 1);
        assertEq(stakeToken.position(id).owner, address(0));
        assertEq(token.balanceOf(address(stakeToken)), stakeToken.totalSupply());
    }

    function testDurationDoesNotRelockExistingPrincipal() public {
        uint256 a = _stake(alice, 1 ether);
        uint48 end = stakeToken.position(a).unlockAt;
        vm.prank(admin);
        stakeToken.setLockDuration(90 days);
        uint256 b = _stake(bob, 1 ether);
        assertEq(stakeToken.position(b).unlockAt, vm.getBlockTimestamp() + 90 days);
        assertEq(stakeToken.position(a).unlockAt, end);
        vm.warp(end);
        vm.prank(alice);
        assertEq(stakeToken.renew(a, 1 ether), a);
        assertEq(stakeToken.position(a).unlockAt, end + 90 days);
        vm.startPrank(admin);
        vm.expectRevert(StakedSTRN.InvalidDuration.selector);
        stakeToken.setLockDuration(0);
        vm.expectRevert(StakedSTRN.InvalidDuration.selector);
        stakeToken.setLockDuration(366 days);
        vm.stopPrank();
    }

    function testCapacityAndSwapRemoval() public {
        uint256[] memory ids = new uint256[](32);
        for (uint256 i; i < 32; ++i) {
            ids[i] = _stake(alice, 2 ether);
        }
        vm.prank(alice);
        vm.expectRevert(StakedSTRN.TooManyPositions.selector);
        stakeToken.stake(1);
        vm.warp(vm.getBlockTimestamp() + 120 days);
        vm.prank(alice);
        vm.expectRevert(StakedSTRN.TooManyPositions.selector);
        stakeToken.renew(ids[0], 1 ether);
        assertEq(stakeToken.position(ids[0]).principal, 2 ether);
        vm.prank(alice);
        stakeToken.renew(ids[0], 2 ether);
        vm.prank(alice);
        stakeToken.redeem(ids[8], 2 ether);
        vm.prank(alice);
        stakeToken.redeem(ids[31], 2 ether);
        assertEq(stakeToken.positionIds(alice).length, 30);
        _stake(alice, 1 ether);
        assertEq(stakeToken.positionIds(alice).length, 31);
    }

    function testRecoveryPreservesBackingExpiryAndDisablesVotes() public {
        uint256 a = _stake(alice, 6000 ether);
        uint256 b = _stake(alice, 4000 ether);
        uint48 end = stakeToken.position(a).unlockAt;
        vm.prank(alice);
        stakeToken.delegate(bob);
        vm.prank(recovery);
        stakeToken.delegate(carol);
        vm.startPrank(admin);
        token.setBlacklisted(alice, true);
        token.pause();
        stakeToken.pause();
        stakeToken.recoverPosition(a);
        vm.stopPrank();
        assertEq(stakeToken.position(a).owner, address(stakeToken));
        assertEq(stakeToken.position(a).unlockAt, end);
        assertEq(stakeToken.position(b).owner, alice);
        assertEq(stakeToken.getVotes(bob), 4000 ether);
        assertEq(stakeToken.getVotes(carol), 0);
        assertEq(stakeToken.totalSupply(), 10_000 ether);
        assertEq(token.balanceOf(address(stakeToken)), 10_000 ether);
        vm.startPrank(admin);
        token.setBlacklisted(address(stakeToken), true);
        vm.expectRevert();
        token.seize(address(stakeToken), 1);
        vm.stopPrank();
        vm.warp(end);
        vm.prank(recovery);
        vm.expectRevert();
        stakeToken.redeem(a, 6000 ether);
        assertEq(stakeToken.position(a).principal, 6000 ether);
        vm.startPrank(admin);
        token.setBlacklisted(address(stakeToken), false);
        token.unpause();
        vm.stopPrank();
        vm.prank(admin); // local pause still permits authorized mature release
        stakeToken.releasePosition(a, recovery, true);
        assertEq(stakeToken.getVotes(carol), 0);
    }

    function testBlacklistCustodyAndPausePolicies() public {
        uint256 id = _stake(alice, 5000 ether);
        vm.prank(admin);
        token.setBlacklisted(alice, true);
        assertEq(stakeToken.getFeeDiscountBps(alice), 0);
        vm.prank(alice);
        vm.expectRevert();
        stakeToken.delegate(bob);
        vm.prank(alice);
        vm.expectRevert();
        stakeToken.stake(1);
        vm.warp(vm.getBlockTimestamp() + 120 days);
        vm.prank(alice);
        vm.expectRevert();
        stakeToken.renew(id, 1);
        vm.prank(alice);
        vm.expectRevert();
        stakeToken.redeem(id, 1);
        vm.prank(admin);
        token.setBlacklisted(alice, false);
        vm.prank(admin);
        token.pause();
        vm.prank(alice);
        vm.expectRevert();
        stakeToken.renew(id, 1);
        vm.prank(admin);
        token.unpause();
        vm.prank(admin);
        stakeToken.pause();
        vm.prank(alice);
        vm.expectRevert();
        stakeToken.renew(id, 1);
        vm.prank(alice);
        stakeToken.redeem(id, 5000 ether);
        vm.prank(admin);
        token.setStakingCustodyProtection(address(stakeToken), false);
        vm.prank(admin);
        stakeToken.unpause();
        vm.prank(alice);
        vm.expectRevert(StakedSTRN.CustodyNotProtected.selector);
        stakeToken.stake(1);
    }

    function testDonationCannotMintVotesOrSpendPrincipal() public {
        _stake(alice, 100 ether);
        vm.prank(bob);
        token.transfer(address(stakeToken), 30 ether);
        assertEq(stakeToken.totalSupply(), 100 ether);
        assertEq(stakeToken.excessUnderlying(), 30 ether);
        assertEq(stakeToken.getVotes(address(stakeToken)), 0);
        vm.prank(admin);
        vm.expectRevert(StakedSTRN.InvalidAmount.selector);
        stakeToken.recoverExcess(30 ether + 1);
        vm.prank(admin);
        stakeToken.recoverExcess(30 ether);
        assertEq(token.balanceOf(address(stakeToken)), 100 ether);
        assertEq(token.balanceOf(recovery), 30 ether);
    }

    function testUnauthorizedOwnershipAndRoles() public {
        uint256 id = _stake(alice, 100 ether);
        vm.warp(vm.getBlockTimestamp() + 120 days);
        vm.startPrank(bob);
        vm.expectRevert();
        stakeToken.redeem(id, 1);
        vm.expectRevert();
        stakeToken.renew(id, 1);
        vm.expectRevert();
        stakeToken.recoverPosition(id);
        vm.expectRevert();
        stakeToken.recoverExcess(1);
        vm.expectRevert();
        stakeToken.pause();
        vm.expectRevert();
        stakeToken.unpause();
        vm.expectRevert();
        stakeToken.setLockDuration(1 days);
        vm.expectRevert();
        stakeToken.grantRole(bytes32(0), bob);
        vm.stopPrank();
        vm.prank(admin);
        vm.expectRevert(StakedSTRN.InvalidRecovery.selector);
        stakeToken.recoverPosition(id);
    }

    function testDiscountCurveAndWholeFeeRounding() public {
        DiscountProductFixture product = new DiscountProductFixture(stakeToken);
        uint256[7] memory levels = [uint256(4999), 5000, 10000, 25000, 50000, 75000, 100000];
        uint256 deposited;
        for (uint256 i; i < levels.length; ++i) {
            _stake(alice, (levels[i] - deposited) * 1 ether);
            deposited = levels[i];
            uint256 expected = deposited < 5000 ? 0 : deposited / 40;
            assertEq(stakeToken.getFeeDiscountBps(alice), expected);
        }
        assertEq(product.quote(alice, 100), 75);
        assertEq(product.quote(alice, 3), 3);
        assertEq(product.quote(bob, 100), 100);
        assertEq(product.quote(alice, 0), 0);
        vm.warp(vm.getBlockTimestamp() + 120 days);
        assertEq(product.quote(alice, 100), 100);
    }

    function testDelegationHistoryAndExplicitOptOut() public {
        vm.prank(alice);
        stakeToken.delegate(address(0));
        uint256 id = _stake(alice, 5 ether);
        assertEq(stakeToken.getVotes(alice), 0);
        vm.prank(alice);
        stakeToken.delegate(bob);
        uint256 t = vm.getBlockTimestamp();
        vm.warp(t + 1);
        assertEq(stakeToken.getPastVotes(bob, t), 5 ether);
        assertEq(stakeToken.getPastTotalSupply(t), 5 ether);
        vm.prank(alice);
        stakeToken.delegate(carol);
        assertEq(stakeToken.getVotes(bob), 0);
        assertEq(stakeToken.getVotes(carol), 5 ether);
        assertEq(stakeToken.getPastVotes(bob, t), 5 ether);
        vm.expectRevert();
        stakeToken.getPastVotes(bob, vm.getBlockTimestamp());
        vm.warp(stakeToken.position(id).unlockAt);
        assertEq(stakeToken.getVotes(carol), 5 ether);
        vm.prank(alice);
        stakeToken.redeem(id, 5 ether);
        assertEq(stakeToken.getVotes(carol), 0);
        assertEq(stakeToken.getPastVotes(bob, t), 5 ether);
    }

    function testDelegationSignatureReplayExpiryAndRestrictedSigner() public {
        uint256 key = 12345;
        address signer = vm.addr(key);
        vm.prank(treasury);
        token.transfer(signer, 10 ether);
        vm.prank(signer);
        token.approve(address(stakeToken), 10 ether);
        _stake(signer, 10 ether);
        uint256 expiry = vm.getBlockTimestamp() + 1 days;
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Staked Saturn"),
                keccak256("1"),
                block.chainid,
                address(stakeToken)
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                domain,
                keccak256(
                    abi.encode(keccak256("Delegation(address delegatee,uint256 nonce,uint256 expiry)"), bob, 0, expiry)
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        vm.prank(admin);
        token.setBlacklisted(signer, true);
        vm.expectRevert();
        stakeToken.delegateBySig(bob, 0, expiry, v, r, s);
        assertEq(stakeToken.nonces(signer), 0);
        vm.prank(admin);
        token.setBlacklisted(signer, false);
        stakeToken.delegateBySig(bob, 0, expiry, v, r, s);
        assertEq(stakeToken.getVotes(bob), 10 ether);
        vm.expectRevert();
        stakeToken.delegateBySig(bob, 0, expiry, v, r, s);
        vm.warp(expiry + 1);
        vm.expectRevert();
        stakeToken.delegateBySig(bob, 1, expiry, v, r, s);
    }

    function testFuzzPrincipalAndDiscount(uint256 raw, uint256 redeemed) public {
        uint256 amount = bound(raw, 1, 1_000_000 ether);
        uint256 id = _stake(alice, amount);
        uint256 expected = amount < 5000 ether ? 0 : amount >= 100_000 ether ? 2500 : amount * 2500 / 100_000 ether;
        assertEq(stakeToken.getFeeDiscountBps(alice), expected);
        vm.warp(stakeToken.position(id).unlockAt);
        redeemed = bound(redeemed, 1, amount);
        vm.prank(alice);
        stakeToken.redeem(id, redeemed);
        assertEq(stakeToken.totalSupply(), amount - redeemed);
        assertEq(token.balanceOf(address(stakeToken)), amount - redeemed);
        assertEq(stakeToken.balanceOf(alice), amount - redeemed);
    }

    function testLongInactivityNeedsNoKeeper() public {
        for (uint256 i; i < 32; ++i) {
            _stake(alice, 5000 ether);
            vm.warp(vm.getBlockTimestamp() + 1);
        }
        vm.warp(vm.getBlockTimestamp() + 100 * 365 days);
        assertEq(stakeToken.activeBalanceOf(alice), 0);
        assertEq(stakeToken.getFeeDiscountBps(alice), 0);
        uint256[] memory ids = stakeToken.positionIds(alice);
        for (uint256 i; i < ids.length; ++i) {
            vm.prank(alice);
            stakeToken.redeem(ids[i], 5000 ether);
        }
        assertEq(stakeToken.totalSupply(), 0);
    }
}
