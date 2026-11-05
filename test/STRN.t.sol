// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {STRN} from "../src/STRN.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {
    TransparentUpgradeableProxy,
    ITransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

import {STRNV2} from "./fixtures/STRNV2.sol";

contract ReferenceToken is ERC20 {
    constructor(address recipient) ERC20("Saturn", "STRN") {
        _mint(recipient, 1_000_000_000 ether);
    }
}

abstract contract STRNFixture is Test {
    STRN internal token;
    STRN internal implementation;
    ProxyAdmin internal proxyAdmin;
    address internal admin = address(0xA11);
    address internal upgradeOwner = address(0xB11);
    address internal treasury = address(0xC11);
    address internal recipient = address(0xD11);
    address internal alice = address(0xA1);
    address internal bob = address(0xB1);
    address internal spender = address(0x51);
    bytes32 internal constant ADMIN_SLOT = bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1);

    function setUp() public {
        implementation = new STRN();
        token = STRN(
            address(
                new TransparentUpgradeableProxy(
                    address(implementation),
                    upgradeOwner,
                    abi.encodeCall(STRN.initialize, (admin, treasury, recipient, uint48(2 days)))
                )
            )
        );
        proxyAdmin = ProxyAdmin(address(uint160(uint256(vm.load(address(token), ADMIN_SLOT)))));
        vm.startPrank(admin);
        token.grantRole(token.PAUSER_ROLE(), admin);
        token.grantRole(token.UNPAUSER_ROLE(), admin);
        token.grantRole(token.PARAMETER_MANAGER_ROLE(), admin);
        token.grantRole(token.BLACKLISTER_ROLE(), admin);
        token.grantRole(token.SEIZER_ROLE(), admin);
        vm.stopPrank();
        vm.prank(treasury);
        token.transfer(alice, 1000 ether);
    }
}

contract STRNTest is STRNFixture {
    function testInitialization() public {
        assertEq(token.name(), "Saturn");
        assertEq(token.symbol(), "STRN");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(treasury), token.totalSupply() - 1000 ether);
        assertEq(token.seizureRecipient(), recipient);
        assertEq(token.defaultAdmin(), admin);
        assertEq(token.defaultAdminDelay(), 2 days);
        assertFalse(token.paused());
        assertEq(proxyAdmin.owner(), upgradeOwner);
        vm.expectRevert();
        token.initialize(alice, alice, alice, 0);
        vm.expectRevert();
        implementation.initialize(alice, alice, alice, 0);
        assertEq(implementation.totalSupply(), 0);
    }

    function testFuzzInvalidInitializer(uint8 which) public {
        address[3] memory a = [admin, treasury, recipient];
        a[which % 3] = address(0);
        vm.expectRevert(abi.encodeWithSelector(STRN.InvalidAddress.selector, address(0)));
        new TransparentUpgradeableProxy(
            address(implementation), upgradeOwner, abi.encodeCall(STRN.initialize, (a[0], a[1], a[2], uint48(0)))
        );
    }

    function testProxySelfInitializerRejected() public {
        // An empty proxy is only a negative fixture, never the deployment recipe.
        STRN empty = STRN(address(new TransparentUpgradeableProxy(address(implementation), upgradeOwner, "")));
        vm.expectRevert(abi.encodeWithSelector(STRN.InvalidAddress.selector, address(empty)));
        empty.initialize(admin, address(empty), recipient, 0);
        empty.initialize(admin, treasury, recipient, 0); // failed initializer rolled back its version
        assertEq(empty.totalSupply(), token.INITIAL_SUPPLY());
    }

    function testNoImplicitOperatorRoles() public {
        STRN fresh = STRN(
            address(
                new TransparentUpgradeableProxy(
                    address(implementation),
                    upgradeOwner,
                    abi.encodeCall(STRN.initialize, (admin, treasury, recipient, uint48(0)))
                )
            )
        );
        assertFalse(fresh.hasRole(fresh.SEIZER_ROLE(), admin));
        assertFalse(fresh.hasRole(fresh.UNPAUSER_ROLE(), admin));
        assertFalse(fresh.hasRole(fresh.PARAMETER_MANAGER_ROLE(), admin));
        vm.prank(admin);
        vm.expectRevert();
        fresh.pause();
    }

    function testFuzzDifferentialERC20(uint256 amount, uint256 approval, bool infinite) public {
        ReferenceToken ref = new ReferenceToken(alice);
        uint256 remaining = token.balanceOf(treasury);
        vm.prank(treasury);
        token.transfer(alice, remaining);
        amount = bound(amount, 0, token.totalSupply());
        approval = infinite ? type(uint256).max : bound(approval, amount, type(uint256).max - 1);
        vm.startPrank(alice);
        token.approve(spender, approval);
        ref.approve(spender, approval);
        vm.stopPrank();
        vm.startPrank(spender);
        assertTrue(token.transferFrom(alice, bob, amount));
        assertTrue(ref.transferFrom(alice, bob, amount));
        vm.stopPrank();
        assertEq(token.balanceOf(alice), ref.balanceOf(alice));
        assertEq(token.balanceOf(bob), ref.balanceOf(bob));
        assertEq(token.allowance(alice, spender), ref.allowance(alice, spender));
        assertEq(token.totalSupply(), ref.totalSupply());
    }

    function testFuzzRestrictedRoutes(uint8 who, bool infinite, bool paused_, bool zero) public {
        uint256 approval = infinite ? type(uint256).max : 10 ether;
        vm.prank(alice);
        token.approve(spender, approval);
        address blocked = who % 3 == 0 ? alice : who % 3 == 1 ? bob : spender;
        vm.startPrank(admin);
        token.setBlacklisted(blocked, true);
        if (paused_) token.pause();
        vm.stopPrank();
        vm.prank(spender);
        vm.expectRevert();
        token.transferFrom(alice, bob, zero ? 0 : 1 ether);
        assertEq(token.allowance(alice, spender), approval);
        assertEq(token.balanceOf(alice), 1000 ether);
        assertEq(token.balanceOf(bob), 0);
        vm.prank(alice);
        token.approve(spender, 0);
        assertEq(token.allowance(alice, spender), 0);
    }

    function testPauseAndApprovals() public {
        vm.prank(admin);
        token.pause();
        vm.startPrank(alice);
        vm.expectRevert();
        token.transfer(bob, 0);
        vm.expectRevert();
        token.transfer(alice, 0);
        token.approve(spender, 1);
        assertEq(token.allowance(alice, spender), 1);
        token.approve(spender, 0);
        vm.stopPrank();
        vm.prank(admin);
        token.unpause();
        vm.prank(alice);
        token.transfer(bob, 1);
    }

    function testBlacklistApprovalAndRestoration() public {
        vm.prank(alice);
        token.approve(spender, 10);
        vm.prank(admin);
        token.setBlacklisted(spender, true);
        vm.prank(alice);
        token.approve(spender, 20);
        vm.prank(alice); // unrelated allowance doesn't freeze direct transfers
        token.transfer(bob, 1);
        vm.prank(admin);
        token.setBlacklisted(spender, false);
        vm.prank(spender);
        token.transferFrom(alice, bob, 10);
        vm.prank(admin);
        token.setBlacklisted(alice, true);
        vm.prank(alice);
        token.approve(bob, 1);
        vm.prank(alice);
        token.approve(bob, 0);
    }

    function testFuzzSeize(uint256 amount, bool paused_) public {
        amount = bound(amount, 1, 1000 ether);
        vm.prank(alice);
        token.approve(spender, type(uint256).max);
        vm.startPrank(admin);
        token.setBlacklisted(alice, true);
        if (paused_) token.pause();
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(alice, recipient, amount);
        vm.expectEmit(true, true, true, true, address(token));
        emit Seized(admin, alice, recipient, amount);
        token.seize(alice, amount);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 1000 ether - amount);
        assertEq(token.balanceOf(recipient), amount);
        assertEq(token.allowance(alice, spender), type(uint256).max);
        assertTrue(token.isBlacklisted(alice));
        assertEq(token.totalSupply(), token.INITIAL_SUPPLY());
    }
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Seized(address indexed operator, address indexed from, address indexed recipient, uint256 amount);

    function testSeizureFailures() public {
        vm.startPrank(admin);
        vm.expectRevert();
        token.seize(alice, 1);
        token.setBlacklisted(alice, true);
        vm.expectRevert();
        token.seize(alice, 0);
        vm.expectRevert();
        token.seize(alice, 1001 ether);
        token.setBlacklisted(recipient, true);
        vm.expectRevert();
        token.seize(alice, 1);
        vm.expectRevert();
        token.seize(recipient, 1);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 1000 ether);
        assertEq(token.balanceOf(recipient), 0);
    }

    function testFuzzUnauthorized(address attacker) public {
        vm.assume(attacker != admin && attacker != address(proxyAdmin));
        bytes32 role = token.SEIZER_ROLE();
        vm.startPrank(attacker);
        vm.expectRevert();
        token.pause();
        vm.expectRevert();
        token.unpause();
        vm.expectRevert();
        token.setBlacklisted(alice, true);
        vm.expectRevert();
        token.seize(alice, 1);
        vm.expectRevert();
        token.grantRole(role, attacker);
        vm.expectRevert();
        token.revokeRole(role, admin);
        vm.expectRevert();
        token.beginDefaultAdminTransfer(attacker);
        vm.expectRevert();
        token.setSeizureRecipient(attacker);
        vm.expectRevert();
        token.setStakingCustodyProtection(address(implementation), true);
        vm.stopPrank();
        assertFalse(token.hasRole(role, attacker));
        assertFalse(token.isBlacklisted(alice));
    }

    function testAdminTransitionAndRoleRevocation() public {
        bytes32 role = token.PAUSER_ROLE();
        vm.startPrank(admin);
        token.beginDefaultAdminTransfer(bob);
        vm.expectRevert();
        token.grantRole(bytes32(0), bob);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert();
        token.acceptDefaultAdminTransfer();
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(bob);
        token.acceptDefaultAdminTransfer();
        assertEq(token.defaultAdmin(), bob);
        assertFalse(token.hasRole(bytes32(0), admin));
        vm.prank(admin);
        vm.expectRevert();
        token.grantRole(role, alice);
        vm.prank(bob);
        token.revokeRole(role, admin);
        vm.prank(admin);
        vm.expectRevert();
        token.pause();
        vm.prank(bob);
        token.grantRole(role, alice);
        vm.prank(alice);
        token.renounceRole(role, alice);
        vm.prank(alice);
        vm.expectRevert();
        token.pause();
    }

    function testUpgradePreservesState() public {
        address custody = address(new STRN());
        vm.prank(alice);
        token.approve(spender, 123);
        vm.startPrank(admin);
        token.setBlacklisted(alice, true);
        token.pause();
        token.beginDefaultAdminTransfer(bob);
        token.changeDefaultAdminDelay(3 days);
        token.setSeizureRecipient(spender);
        token.setStakingCustodyProtection(custody, true);
        vm.stopPrank();
        (address pending, uint48 schedule) = token.pendingDefaultAdmin();
        (uint48 delay, uint48 delaySchedule) = token.pendingDefaultAdminDelay();
        STRNV2 v2 = new STRNV2();
        vm.prank(admin);
        vm.expectRevert();
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(token)), address(v2), "");
        vm.prank(upgradeOwner);
        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(address(token)), address(v2), abi.encodeCall(STRNV2.initializeV2, (42))
        );
        STRNV2 upgraded = STRNV2(address(token));
        assertEq(upgraded.version(), 2);
        assertEq(upgraded.marker(), 42);
        bytes32 root = keccak256(abi.encode(uint256(keccak256("saturn.storage.STRNV2")) - 1)) & ~bytes32(uint256(255));
        assertEq(uint256(vm.load(address(token), root)), 42);
        vm.prank(alice);
        vm.expectRevert();
        upgraded.setMarker(100);
        vm.prank(admin);
        upgraded.setMarker(99);
        assertEq(upgraded.marker(), 99);
        assertEq(uint256(vm.load(address(token), root)), 99);
        vm.expectRevert();
        upgraded.initializeV2(100);
        vm.expectRevert();
        v2.initializeV2(100);
        assertEq(token.balanceOf(alice), 1000 ether);
        assertEq(token.allowance(alice, spender), 123);
        assertEq(token.seizureRecipient(), spender);
        assertTrue(token.isProtectedStakingCustody(custody));
        assertTrue(token.hasRole(token.UNPAUSER_ROLE(), admin));
        assertTrue(token.hasRole(token.PARAMETER_MANAGER_ROLE(), admin));
        assertEq(token.defaultAdmin(), admin);
        assertEq(token.defaultAdminDelay(), 2 days);
        assertTrue(token.hasRole(token.SEIZER_ROLE(), admin));
        assertTrue(token.isBlacklisted(alice));
        assertTrue(token.paused());
        (address p, uint48 s) = token.pendingDefaultAdmin();
        assertEq(p, pending);
        assertEq(s, schedule);
        (uint48 d, uint48 ds) = token.pendingDefaultAdminDelay();
        assertEq(d, delay);
        assertEq(ds, delaySchedule);
        vm.expectRevert();
        token.initialize(bob, bob, bob, 0);
        vm.prank(admin);
        token.seize(alice, 1);
        assertEq(token.balanceOf(spender), 1);
        assertEq(token.balanceOf(treasury), token.INITIAL_SUPPLY() - 1000 ether);
        assertEq(token.balanceOf(bob), 0);
        assertEq(upgraded.marker(), 99);
        assertEq(token.totalSupply(), token.INITIAL_SUPPLY());
    }

    function testNoMintBurnOrUUPS() public {
        bytes[4] memory calls = [
            abi.encodeWithSignature("mint(address,uint256)", alice, 1),
            abi.encodeWithSignature("burn(uint256)", 1),
            abi.encodeWithSignature("burnFrom(address,uint256)", alice, 1),
            abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(implementation), bytes(""))
        ];
        vm.startPrank(admin);
        for (uint256 i; i < calls.length; i++) {
            (bool ok,) = address(token).call(calls[i]);
            assertFalse(ok);
        }
        vm.stopPrank();
        assertEq(token.totalSupply(), token.INITIAL_SUPPLY());
    }

    function testZeroEndpointsAndSelfTransfer() public {
        vm.startPrank(alice);
        vm.expectRevert();
        token.transfer(address(0), 0);
        vm.expectRevert();
        token.approve(address(0), 0);
        token.transfer(alice, 1000 ether);
        assertEq(token.balanceOf(alice), 1000 ether);
        vm.stopPrank();
        vm.startPrank(admin);
        vm.expectRevert();
        token.setBlacklisted(address(0), true);
        vm.expectRevert();
        token.setBlacklisted(address(token), true);
        vm.stopPrank();
    }
}
