// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;
import {StakedSTRNFixture} from "./StakedSTRN.t.sol";

contract StakedSTRNGas is StakedSTRNFixture {
    function testGasStake() public {
        vm.startPrank(alice);
        vm.startSnapshotGas("StakedSTRN", "stake-first");
        stakeToken.stake(10_000 ether);
        vm.stopSnapshotGas();
        vm.stopPrank();
    }

    function testGasBoundedFullAccount() public {
        for (uint256 i; i < 31; ++i) {
            _stake(alice, 5000 ether);
        }
        vm.startPrank(alice);
        vm.startSnapshotGas("StakedSTRN", "stake-32nd");
        uint256 id = stakeToken.stake(5000 ether);
        vm.stopSnapshotGas();
        vm.stopPrank();
        // Cool the contract's storage to measure the product-call path conservatively.
        vm.cool(address(stakeToken));
        vm.cool(address(token));
        vm.startSnapshotGas("StakedSTRN", "discount-32-positions");
        stakeToken.getFeeDiscountBps(alice);
        vm.stopSnapshotGas();
        vm.warp(vm.getBlockTimestamp() + 120 days);
        vm.startPrank(alice);
        vm.startSnapshotGas("StakedSTRN", "renew-full-at-capacity");
        stakeToken.renew(id, 5000 ether);
        vm.stopSnapshotGas();
        vm.stopPrank();
    }

    function testGasRedeemAndRecover() public {
        uint256 id = _stake(alice, 5000 ether);
        vm.prank(admin);
        token.setBlacklisted(alice, true);
        vm.startPrank(admin);
        vm.startSnapshotGas("StakedSTRN", "recover-position");
        stakeToken.recoverPosition(id);
        vm.stopSnapshotGas();
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 120 days);
        vm.startPrank(admin);
        vm.startSnapshotGas("StakedSTRN", "release-matured");
        stakeToken.releasePosition(id, recovery, true);
        vm.stopSnapshotGas();
        vm.stopPrank();
    }

    function testGasRecoveryAtScale() public {
        uint256 first;
        for (uint256 i; i < 65; ++i) {
            vm.prank(admin);
            token.setBlacklisted(alice, false);
            uint256 id = _stake(alice, 1 ether);
            if (i == 0) first = id;
            vm.prank(admin);
            token.setBlacklisted(alice, true);
            if (i == 64) {
                vm.cool(address(stakeToken));
                vm.cool(address(token));
                vm.startPrank(admin);
                vm.startSnapshotGas("StakedSTRN", "recover-position-65-cold");
                stakeToken.recoverPosition(id);
                vm.stopSnapshotGas();
                vm.stopPrank();
            } else {
                vm.prank(admin);
                stakeToken.recoverPosition(id);
            }
        }
        vm.cool(address(stakeToken));
        vm.cool(address(token));
        vm.startPrank(admin);
        vm.startSnapshotGas("StakedSTRN", "release-active-65-cold");
        stakeToken.releasePosition(first, bob, false);
        vm.stopSnapshotGas();
        vm.stopPrank();
    }
}
