// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;
import {Test} from "forge-std/Test.sol";
import {STRN} from "../src/STRN.sol";
import {DeploySTRN, DeploySTRNImplementation} from "../script/DeploySTRN.s.sol";
import {STRNV2} from "./fixtures/STRNV2.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

abstract contract STRNTimelockFixture is Test {
    TimelockController internal timelock;
    STRN internal token;
    ProxyAdmin internal proxyAdmin;
    address internal proposer = address(0x1010);
    address internal treasury = address(0x2020);
    address internal recovery = address(0x3030);

    function setUp() public virtual {
        address[] memory proposers = new address[](1);
        proposers[0] = proposer;
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        timelock = new TimelockController(5 days, proposers, executors, address(0));
        token =
            new DeploySTRN().run(new DeploySTRNImplementation().run(), address(timelock), treasury, recovery, 2 days);
        bytes32 slot = bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1);
        proxyAdmin = ProxyAdmin(address(uint160(uint256(vm.load(address(token), slot)))));
    }
}

contract STRNTimelockTest is STRNTimelockFixture {
    function testRecipeRejectsMissingOrWrongDelayTimelock() public {
        DeploySTRN recipe = new DeploySTRN();
        vm.expectRevert(DeploySTRN.InvalidTimelock.selector);
        recipe.run(token, address(0), treasury, recovery, 0);
        address[] memory empty = new address[](0);
        TimelockController shortDelay = new TimelockController(4 days, empty, empty, address(this));
        vm.expectRevert(DeploySTRN.InvalidTimelock.selector);
        recipe.run(token, address(shortDelay), treasury, recovery, 0);
    }

    function testFiveDayUpgradeAndNoDirectSignerBypass() public {
        assertEq(proxyAdmin.owner(), address(timelock));
        assertEq(token.defaultAdmin(), address(timelock));
        assertEq(token.balanceOf(treasury), token.INITIAL_SUPPLY());
        assertFalse(token.hasRole(token.PAUSER_ROLE(), address(timelock)));
        STRNV2 next = new STRNV2();
        bytes memory data = abi.encodeCall(
            proxyAdmin.upgradeAndCall,
            (ITransparentUpgradeableProxy(address(token)), address(next), abi.encodeCall(STRNV2.initializeV2, (42)))
        );
        vm.prank(proposer);
        vm.expectRevert();
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(token)), address(next), "");
        vm.prank(proposer);
        vm.expectRevert();
        timelock.schedule(address(proxyAdmin), 0, data, 0, 0, 5 days - 1);
        vm.prank(proposer);
        timelock.schedule(address(proxyAdmin), 0, data, 0, 0, 5 days);
        vm.warp(block.timestamp + 5 days - 1);
        vm.expectRevert();
        timelock.execute(address(proxyAdmin), 0, data, 0, 0);
        vm.warp(block.timestamp + 1);
        timelock.execute(address(proxyAdmin), 0, data, 0, 0); // open execution only after readiness
        assertEq(STRNV2(address(token)).marker(), 42);
        assertEq(token.balanceOf(treasury), token.INITIAL_SUPPLY());
        assertEq(token.defaultAdmin(), address(timelock));
        vm.expectRevert();
        timelock.execute(address(proxyAdmin), 0, data, 0, 0);
    }

    function testTimelockedRoleGrantsThenImmediatePauseButSeparateUnpause() public {
        bytes32 pauseRole = token.PAUSER_ROLE();
        bytes memory data = abi.encodeCall(token.grantRole, (pauseRole, proposer));
        vm.prank(proposer);
        vm.expectRevert();
        token.grantRole(pauseRole, proposer);
        vm.prank(proposer);
        timelock.schedule(address(token), 0, data, 0, 0, 5 days);
        vm.warp(block.timestamp + 5 days);
        timelock.execute(address(token), 0, data, 0, 0);
        vm.startPrank(proposer);
        token.pause();
        vm.expectRevert();
        token.unpause();
        vm.stopPrank();
        assertTrue(token.paused());
    }

    function testProposerCancellationPreventsExecution() public {
        bytes memory data = abi.encodeCall(token.grantRole, (token.SEIZER_ROLE(), proposer));
        vm.prank(treasury);
        vm.expectRevert();
        timelock.schedule(address(token), 0, data, 0, 0, 5 days);
        vm.prank(proposer);
        timelock.schedule(address(token), 0, data, 0, 0, 5 days);
        bytes32 id = timelock.hashOperation(address(token), 0, data, 0, 0);
        vm.prank(proposer);
        timelock.cancel(id);
        vm.warp(block.timestamp + 5 days);
        vm.expectRevert();
        timelock.execute(address(token), 0, data, 0, 0);
        assertFalse(token.hasRole(token.SEIZER_ROLE(), proposer));
    }
}
