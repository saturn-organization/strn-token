// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;
import {StakedSTRNFixture} from "./StakedSTRN.t.sol";
import {StakedSTRN} from "../src/StakedSTRN.sol";
import {StakedSTRNV2} from "./fixtures/StakedSTRNV2.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {
    TransparentUpgradeableProxy,
    ITransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

contract AdversarialPrincipal is ERC20 {
    uint256 public mode;
    address public receipt;
    bool public callbackBlocked;
    mapping(address => bool) public isBlacklisted;

    constructor() ERC20("Adversary", "BAD") {
        _mint(msg.sender, 100 ether);
    }

    function configure(address receipt_, uint256 mode_) external {
        receipt = receipt_;
        mode = mode_;
    }

    function blacklist(address account) external {
        isBlacklisted[account] = true;
    }

    function paused() external pure returns (bool) {
        return false;
    }

    function isProtectedStakingCustody(address account) external view returns (bool) {
        return account == receipt;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && mode == 1) {
            super._update(from, address(0), 1);
            super._update(from, to, value - 1);
        } else {
            if (from != address(0) && to != address(0) && mode == 2) {
                (bool ok,) = receipt.call(abi.encodeCall(StakedSTRN.stake, (1)));
                callbackBlocked = !ok;
                require(!ok, "reentry succeeded");
            }
            super._update(from, to, value);
        }
    }
}

contract StakedSTRNSecurityTest is StakedSTRNFixture {
    function testIncomingAndOutgoingMismatchRollBack() public {
        AdversarialPrincipal bad = new AdversarialPrincipal();
        StakedSTRN receipt = StakedSTRN(
            address(
                new TransparentUpgradeableProxy(
                    address(new StakedSTRN()),
                    admin,
                    abi.encodeCall(StakedSTRN.initialize, (admin, address(bad), uint48(1 days), uint48(0)))
                )
            )
        );
        bad.approve(address(receipt), 10 ether);
        bad.configure(address(receipt), 1);
        vm.expectRevert(StakedSTRN.ReceiptMismatch.selector);
        receipt.stake(10 ether);
        assertEq(receipt.totalSupply(), 0);
        assertEq(bad.balanceOf(address(receipt)), 0);
        assertEq(bad.allowance(address(this), address(receipt)), 10 ether);
        bad.configure(address(receipt), 0);
        uint256 id = receipt.stake(10 ether);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        bad.configure(address(receipt), 1);
        vm.expectRevert(StakedSTRN.ReceiptMismatch.selector);
        receipt.redeem(id, 10 ether);
        assertEq(receipt.totalSupply(), 10 ether);
        assertEq(receipt.position(id).principal, 10 ether);
        assertEq(bad.balanceOf(address(receipt)), 10 ether);
    }

    function testTokenCallbackCannotReenter() public {
        AdversarialPrincipal bad = new AdversarialPrincipal();
        StakedSTRN receipt = StakedSTRN(
            address(
                new TransparentUpgradeableProxy(
                    address(new StakedSTRN()),
                    admin,
                    abi.encodeCall(StakedSTRN.initialize, (admin, address(bad), uint48(1 days), uint48(0)))
                )
            )
        );
        bad.configure(address(receipt), 2);
        bad.approve(address(receipt), 10 ether);
        uint256 id = receipt.stake(10 ether);
        assertTrue(bad.callbackBlocked());
        assertEq(receipt.totalSupply(), 10 ether);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        receipt.redeem(id, 10 ether);
        assertEq(receipt.totalSupply(), 0);
    }

    function testRecoveredUnderlyingMismatchAndCallbackRollback() public {
        AdversarialPrincipal bad = new AdversarialPrincipal();
        StakedSTRN receipt = StakedSTRN(
            address(
                new TransparentUpgradeableProxy(
                    address(new StakedSTRN()),
                    admin,
                    abi.encodeCall(StakedSTRN.initialize, (admin, address(bad), uint48(1 days), uint48(0)))
                )
            )
        );
        bad.configure(address(receipt), 0);
        bad.approve(address(receipt), 10 ether);
        uint256 id = receipt.stake(10 ether);
        bad.blacklist(address(this));
        vm.startPrank(admin);
        receipt.grantRole(receipt.SEIZER_ROLE(), admin);
        receipt.grantRole(receipt.RELEASER_ROLE(), admin);
        receipt.recoverPosition(id);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 1 days);
        bad.configure(address(receipt), 1);
        vm.prank(admin);
        vm.expectRevert(StakedSTRN.ReceiptMismatch.selector);
        receipt.releasePosition(id, bob, true);
        assertEq(receipt.totalSupply(), 10 ether);
        assertEq(receipt.recoveredPrincipal(), 10 ether);
        assertEq(receipt.position(id).principal, 10 ether);
        assertEq(bad.balanceOf(bob), 0);
        uint256 failedAt = vm.getBlockTimestamp();
        vm.warp(failedAt + 1);
        assertEq(receipt.getPastRecoveredPrincipal(failedAt), 10 ether);
        assertEq(receipt.getPastTotalSupply(failedAt), 10 ether);
        bad.configure(address(receipt), 2);
        vm.prank(admin);
        receipt.releasePosition(id, bob, true);
        assertTrue(bad.callbackBlocked());
        assertEq(bad.balanceOf(bob), 10 ether);
        assertEq(receipt.totalSupply(), 0);
    }

    function testUpgradePreservesClaimsMaturitiesRolesAndHistoricalVotes() public {
        uint256 id = _stake(alice, 6000 ether);
        uint256 other = _stake(bob, 4000 ether);
        vm.prank(alice);
        stakeToken.delegate(carol);
        uint256 at = vm.getBlockTimestamp();
        vm.warp(at + 1);
        vm.startPrank(admin);
        token.setBlacklisted(bob, true);
        stakeToken.recoverPosition(other);
        vm.stopPrank();
        vm.warp(at + 2);
        vm.prank(admin);
        stakeToken.setLockDuration(90 days);
        vm.prank(admin);
        stakeToken.pause();
        StakedSTRN.Position memory beforePosition = stakeToken.position(id);
        bytes32 slot = bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1);
        ProxyAdmin proxyAdmin = ProxyAdmin(address(uint160(uint256(vm.load(address(stakeToken), slot)))));
        StakedSTRNV2 next = new StakedSTRNV2();
        vm.prank(alice);
        vm.expectRevert();
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(stakeToken)), address(next), "");
        vm.prank(admin);
        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(address(stakeToken)),
            address(next),
            abi.encodeCall(StakedSTRNV2.initializeV2, (42))
        );
        assertEq(StakedSTRNV2(address(stakeToken)).marker(), 42);
        assertEq(stakeToken.position(id).principal, beforePosition.principal);
        assertEq(stakeToken.position(id).unlockAt, beforePosition.unlockAt);
        assertEq(stakeToken.position(other).owner, address(stakeToken));
        assertEq(stakeToken.recoveredPrincipal(), 4000 ether);
        assertEq(stakeToken.getPastRecoveredPrincipal(at + 1), 4000 ether);
        assertEq(stakeToken.getPastTotalSupply(at + 1), 10_000 ether);
        assertEq(stakeToken.getVotes(bob), 0);
        assertEq(stakeToken.totalSupply(), 10_000 ether);
        assertEq(stakeToken.getPastVotes(carol, at), 6000 ether);
        assertEq(stakeToken.delegates(alice), carol);
        assertEq(stakeToken.lockDuration(), 90 days);
        assertTrue(stakeToken.paused());
        assertTrue(stakeToken.hasRole(stakeToken.SEIZER_ROLE(), admin));
        vm.expectRevert();
        StakedSTRNV2(address(stakeToken)).initializeV2(9);
        vm.warp(beforePosition.unlockAt);
        vm.prank(alice);
        stakeToken.redeem(id, 6000 ether);
        assertEq(token.balanceOf(address(stakeToken)), 4000 ether);
    }

    function testDefaultAdminHandoffRejectsRestrictedRecipient() public {
        assertEq(stakeToken.clock(), vm.getBlockTimestamp());
        uint256 id = _stake(bob, 1 ether);
        vm.prank(admin);
        stakeToken.beginDefaultAdminTransfer(bob);
        vm.prank(bob);
        vm.expectRevert();
        stakeToken.acceptDefaultAdminTransfer();
        vm.warp(vm.getBlockTimestamp() + 5 days + 1);
        vm.prank(admin);
        token.setBlacklisted(bob, true);
        vm.prank(bob);
        vm.expectRevert();
        stakeToken.acceptDefaultAdminTransfer();
        assertEq(stakeToken.defaultAdmin(), admin);
        vm.prank(admin);
        token.setBlacklisted(bob, false);
        vm.prank(bob);
        stakeToken.acceptDefaultAdminTransfer();
        assertEq(stakeToken.defaultAdmin(), bob);
        vm.prank(admin);
        token.setBlacklisted(bob, true);
        vm.prank(admin);
        vm.expectRevert(StakedSTRN.InvalidRecovery.selector);
        stakeToken.recoverPosition(id);
        assertEq(stakeToken.position(id).owner, bob);
    }

    function testCannotDelegateToCustodyOrUseBlacklistedCustody() public {
        uint256 id = _stake(alice, 5000 ether);
        vm.prank(alice);
        vm.expectRevert(StakedSTRN.InvalidAddress.selector);
        stakeToken.delegate(address(stakeToken));
        assertEq(stakeToken.getVotes(address(stakeToken)), 0);
        vm.prank(admin);
        token.setBlacklisted(address(stakeToken), true);
        assertEq(stakeToken.getFeeDiscountBps(alice), 0);
        vm.prank(alice);
        vm.expectRevert();
        stakeToken.stake(1);
        vm.warp(stakeToken.position(id).unlockAt);
        vm.prank(alice);
        vm.expectRevert();
        stakeToken.renew(id, 1);
        assertEq(stakeToken.position(id).principal, 5000 ether);
    }

    function testZeroInputsAndInvalidInitializers() public {
        vm.prank(alice);
        vm.expectRevert(StakedSTRN.InvalidAmount.selector);
        stakeToken.stake(0);
        vm.prank(alice);
        vm.expectRevert(StakedSTRN.InvalidAmount.selector);
        stakeToken.stake(type(uint256).max);
        uint256 id = _stake(alice, 1 ether);
        vm.warp(stakeToken.position(id).unlockAt);
        vm.startPrank(alice);
        vm.expectRevert();
        stakeToken.redeem(id, 0);
        vm.expectRevert();
        stakeToken.redeem(id, 1 ether + 1);
        vm.expectRevert();
        stakeToken.renew(id, 0);
        vm.expectRevert();
        stakeToken.renew(id, 1 ether + 1);
        vm.stopPrank();
        StakedSTRN impl = new StakedSTRN();
        vm.expectRevert();
        new TransparentUpgradeableProxy(
            address(impl),
            admin,
            abi.encodeCall(StakedSTRN.initialize, (address(0), address(token), uint48(1 days), uint48(0)))
        );
        vm.expectRevert();
        new TransparentUpgradeableProxy(
            address(impl), admin, abi.encodeCall(StakedSTRN.initialize, (admin, address(1), uint48(1 days), uint48(0)))
        );
        vm.expectRevert();
        new TransparentUpgradeableProxy(
            address(impl), admin, abi.encodeCall(StakedSTRN.initialize, (admin, address(token), uint48(0), uint48(0)))
        );
    }

    function testRecoveryIgnoresWalletCapacityAndRestrictedDestination() public {
        uint256 id = _stake(alice, 10 ether);
        vm.prank(treasury);
        token.transfer(recovery, 100 ether);
        vm.prank(recovery);
        token.approve(address(stakeToken), type(uint256).max);
        for (uint256 i; i < 32; ++i) {
            _stake(recovery, 1 ether);
        }
        vm.startPrank(admin);
        token.setBlacklisted(alice, true);
        token.setBlacklisted(recovery, true);
        stakeToken.recoverPosition(id);
        assertEq(stakeToken.position(id).owner, address(stakeToken));
        assertEq(stakeToken.positionIds(recovery).length, 32);
        token.setSeizureRecipient(carol);
        token.setBlacklisted(carol, true);
        vm.expectRevert();
        stakeToken.releasePosition(id, carol, false);
        token.setBlacklisted(carol, false);
        stakeToken.releasePosition(id, carol, false);
        vm.stopPrank();
        assertEq(stakeToken.position(id).owner, carol);
    }
}
