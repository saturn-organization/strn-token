// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;
import {StakedSTRNFixture} from "./StakedSTRN.t.sol";
import {Test} from "forge-std/Test.sol";
import {STRN} from "../src/STRN.sol";
import {StakedSTRN} from "../src/StakedSTRN.sol";

contract StakedSTRNHandler is Test {
    struct Claim {
        address owner;
        uint256 amount;
        uint256 expiry;
    }
    STRN public token;
    StakedSTRN public receipt;
    address public admin;
    address[4] public actors;
    mapping(uint256 => Claim) public claims;
    uint256[] public live;
    mapping(address => address) public delegate;
    mapping(address => bool) public chosen;
    uint256 public donations;
    uint256 public successes;

    constructor(STRN token_, StakedSTRN receipt_, address admin_, address[4] memory actors_) {
        token = token_;
        receipt = receipt_;
        admin = admin_;
        actors = actors_;
    }

    function step(uint256 seed, uint256 raw) external {
        address who = actors[(seed / 10) % 4];
        uint256 op = seed % 8;
        if (op == 0) {
            uint256 slots;
            for (uint256 i; i < live.length; ++i) {
                if (claims[live[i]].owner == who) ++slots;
            }
            uint256 funds = token.balanceOf(who);
            if (slots == 32 || funds == 0) return;
            uint256 amount = bound(raw, 1, funds);
            vm.prank(who);
            token.approve(address(receipt), amount);
            vm.prank(who);
            uint256 id = receipt.stake(amount);
            claims[id] = Claim(who, amount, vm.getBlockTimestamp() + receipt.lockDuration());
            live.push(id);
            if (!chosen[who]) {
                delegate[who] = who;
                chosen[who] = true;
            }
        } else if (op == 1 || op == 2 || op == 5) {
            if (live.length == 0) return;
            uint256 index = raw % live.length;
            uint256 id = live[index];
            Claim memory old = claims[id];
            if (op == 5) {
                if (old.owner == address(receipt)) return;
                vm.prank(admin);
                token.setBlacklisted(old.owner, true);
                vm.prank(admin);
                receipt.recoverPosition(id);
                vm.prank(admin);
                token.setBlacklisted(old.owner, false);
                claims[id].owner = address(receipt);
            } else {
                if (old.owner == address(receipt) || vm.getBlockTimestamp() < old.expiry) return;
                uint256 amount = bound(seed, 1, old.amount);
                if (op == 1) {
                    vm.prank(old.owner);
                    receipt.redeem(id, amount);
                    claims[id].amount -= amount;
                    if (claims[id].amount == 0) {
                        live[index] = live[live.length - 1];
                        live.pop();
                        delete claims[id];
                    }
                } else {
                    uint256 slots;
                    for (uint256 i; i < live.length; ++i) {
                        if (claims[live[i]].owner == old.owner) ++slots;
                    }
                    if (slots == 32 && amount != old.amount) return;
                    vm.prank(old.owner);
                    uint256 next = receipt.renew(id, amount);
                    if (amount == old.amount) {
                        claims[id].expiry = vm.getBlockTimestamp() + receipt.lockDuration();
                    } else {
                        claims[id].amount -= amount;
                        claims[next] = Claim(old.owner, amount, vm.getBlockTimestamp() + receipt.lockDuration());
                        live.push(next);
                    }
                }
            }
        } else if (op == 3) {
            address to = raw % 5 == 4 ? address(0) : actors[raw % 4];
            vm.prank(who);
            receipt.delegate(to);
            delegate[who] = to;
            chosen[who] = true;
        } else if (op == 4) {
            vm.warp(vm.getBlockTimestamp() + bound(raw, 0, 400 days));
        } else if (op == 7) {
            if (live.length == 0) return;
            uint256 index = raw % live.length;
            uint256 id = live[index];
            Claim memory old = claims[id];
            if (old.owner != address(receipt)) return;
            bool underlying = (seed / 8) % 2 == 0;
            if (underlying) {
                if (vm.getBlockTimestamp() < old.expiry) return;
            } else {
                uint256 slots;
                for (uint256 i; i < live.length; ++i) {
                    if (claims[live[i]].owner == who) ++slots;
                }
                if (slots == 32) return;
            }
            vm.prank(admin);
            receipt.releasePosition(id, who, underlying);
            if (underlying) {
                live[index] = live[live.length - 1];
                live.pop();
                delete claims[id];
            } else {
                claims[id].owner = who;
                if (!chosen[who]) {
                    delegate[who] = who;
                    chosen[who] = true;
                }
            }
        } else {
            uint256 funds = token.balanceOf(who);
            if (funds == 0) return;
            uint256 amount = bound(raw, 1, funds);
            vm.prank(who);
            token.transfer(address(receipt), amount);
            donations += amount;
        }
        ++successes;
        check();
    }

    function check() public view {
        uint256 total;
        uint256 recovered;
        uint256[4] memory balances;
        uint256[4] memory active;
        uint256[4] memory slots;
        uint256[4] memory votes;

        for (uint256 i; i < live.length; ++i) {
            Claim memory expected = claims[live[i]];
            total += expected.amount;
            if (expected.owner == address(receipt)) recovered += expected.amount;
            StakedSTRN.Position memory actual = receipt.position(live[i]);
            assertEq(actual.owner, expected.owner);
            assertEq(actual.principal, expected.amount);
            assertEq(actual.unlockAt, expected.expiry);
            for (uint256 j; j < 4; ++j) {
                if (expected.owner == actors[j]) {
                    balances[j] += expected.amount;
                    ++slots[j];
                    if (vm.getBlockTimestamp() < expected.expiry) active[j] += expected.amount;
                }
                if (delegate[expected.owner] == actors[j]) votes[j] += expected.amount;
            }
        }
        assertEq(total, receipt.totalSupply());
        assertEq(receipt.recoveredPrincipal(), recovered);
        assertEq(receipt.balanceOf(address(receipt)), recovered);
        assertEq(receipt.positionIds(address(receipt)).length, 0);
        assertEq(receipt.activeBalanceOf(address(receipt)), 0);
        assertEq(receipt.maturedBalanceOf(address(receipt)), 0);
        assertEq(receipt.getFeeDiscountBps(address(receipt)), 0);
        assertEq(token.balanceOf(address(receipt)), total + donations);
        assertEq(receipt.excessUnderlying(), donations);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        for (uint256 i; i < 4; ++i) {
            assertEq(receipt.balanceOf(actors[i]), balances[i]);
            assertEq(receipt.activeBalanceOf(actors[i]), active[i]);
            assertEq(receipt.maturedBalanceOf(actors[i]), balances[i] - active[i]);
            assertEq(receipt.getVotes(actors[i]), votes[i]);
            uint256[] memory ids = receipt.positionIds(actors[i]);
            assertEq(ids.length, slots[i]);
            for (uint256 j; j < ids.length; ++j) {
                assertEq(receipt.position(ids[j]).index, j);
                assertEq(claims[ids[j]].owner, actors[i]);
            }
            uint256 expected =
                active[i] < 5000 ether ? 0 : active[i] >= 100_000 ether ? 2500 : active[i] * 2500 / 100_000 ether;
            assertEq(receipt.getFeeDiscountBps(actors[i]), expected);
        }
        assertEq(receipt.getVotes(address(receipt)), 0);
    }
}

contract StakedSTRNInvariant is StakedSTRNFixture {
    StakedSTRNHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new StakedSTRNHandler(token, stakeToken, admin, [alice, bob, carol, recovery]);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = handler.step.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariantPrincipalActiveClaimsAndVotes() public view {
        handler.check();
    }
}
