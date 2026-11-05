// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;
import {STRNFixture} from "./STRN.t.sol";

contract STRNGas is STRNFixture {
    function testGasTransferNewRecipient() public {
        vm.prank(alice);
        token.transfer(bob, 1 ether);
        vm.snapshotGasLastCall("STRN", "transfer_new_recipient");
    }

    function testGasTransferExistingRecipient() public {
        vm.prank(alice);
        token.transfer(bob, 1 ether);
        vm.prank(alice);
        token.transfer(bob, 1 ether);
        vm.snapshotGasLastCall("STRN", "transfer_existing_warm");
    }

    function testGasDelegatedTransfer() public {
        vm.prank(alice);
        token.delegate(alice);
        vm.prank(bob);
        token.delegate(bob);
        vm.warp(block.timestamp + 1);
        vm.prank(alice);
        token.transfer(bob, 1 ether);
        vm.snapshotGasLastCall("STRN", "transfer_delegated_new_checkpoint");
    }

    function testGasRelease() public {
        vm.startPrank(admin);
        token.grantRole(token.RELEASER_ROLE(), admin);
        token.setBlacklisted(alice, true);
        token.seize(alice, 1 ether);
        vm.warp(block.timestamp + 1);
        token.releaseRecovered(recipient, bob, 1 ether);
        vm.snapshotGasLastCall("STRN", "release_recovered");
        vm.stopPrank();
    }

    function testGasApprove() public {
        vm.prank(alice);
        token.approve(spender, 10 ether);
        vm.snapshotGasLastCall("STRN", "approve");
    }

    function testGasTransferFromFinite() public {
        vm.prank(alice);
        token.approve(spender, 10 ether);
        vm.prank(spender);
        token.transferFrom(alice, bob, 1 ether);
        vm.snapshotGasLastCall("STRN", "transferFrom_finite");
    }

    function testGasTransferFromInfinite() public {
        vm.prank(alice);
        token.approve(spender, type(uint256).max);
        vm.prank(spender);
        token.transferFrom(alice, bob, 1 ether);
        vm.snapshotGasLastCall("STRN", "transferFrom_infinite");
    }

    function testGasSeizeWhilePaused() public {
        vm.startPrank(admin);
        token.setBlacklisted(alice, true);
        token.pause();
        token.seize(alice, 1 ether);
        vm.snapshotGasLastCall("STRN", "seize_paused");
        vm.stopPrank();
    }

    function testGasPause() public {
        vm.prank(admin);
        token.pause();
        vm.snapshotGasLastCall("STRN", "pause");
    }

    function testGasBlacklist() public {
        vm.prank(admin);
        token.setBlacklisted(alice, true);
        vm.snapshotGasLastCall("STRN", "blacklist");
    }

    function testGasUnpause() public {
        vm.startPrank(admin);
        token.pause();
        token.unpause();
        vm.snapshotGasLastCall("STRN", "unpause");
        vm.stopPrank();
    }

    function testGasRecoveryRotation() public {
        vm.prank(admin);
        token.setSeizureRecipient(bob);
        vm.snapshotGasLastCall("STRN", "recovery_rotation");
    }

    function testGasCustodyProtection() public {
        vm.prank(admin);
        token.setStakingCustodyProtection(address(implementation), true);
        vm.snapshotGasLastCall("STRN", "custody_protection");
    }
}
