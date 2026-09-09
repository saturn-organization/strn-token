// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {StakedSTRNFixture} from "./StakedSTRN.t.sol";
import {Test} from "forge-std/Test.sol";
import {STRN} from "../src/STRN.sol";
import {StakedSTRN} from "../src/StakedSTRN.sol";

/// @dev Independent principal/delegation ledger. Expected history is never read from token checkpoints.
contract CombinedVotesHandler is Test {
    struct Claim {
        uint256 id;
        uint256 owner; // 4 denotes receipt recovery custody.
        uint256 amount;
        uint256 maturity;
    }

    struct Snapshot {
        uint256 time;
        uint256[4] liquidVotes;
        uint256[4] receiptVotes;
        uint256 liquidRecovery;
        uint256 receiptRecovery;
        uint256 receiptSupply;
    }

    STRN internal token;
    StakedSTRN internal receipt;
    address internal admin;
    address[4] internal actors;
    uint256[4] internal liquid;
    uint256[4] internal locked;
    address[4] internal liquidDelegate;
    address[4] internal receiptDelegate;
    bool[4] internal chosen;
    Claim[] internal claims;
    Snapshot[] internal history;
    uint256 internal donations;

    constructor(STRN t, StakedSTRN r, address a, address[4] memory people) {
        token = t;
        receipt = r;
        admin = a;
        actors = people;
        for (uint256 i; i < 3; ++i) {
            liquid[i] = 1_000_000 ether;
        }
    }

    function step(uint256 seed, uint256 raw) external {
        uint256 op = seed % 11;
        uint256 who = (seed / 11) % 4;
        uint256 to = (seed / 44) % 4;
        uint256 free = liquid[who] - locked[who];
        if (op == 0 && free != 0) {
            uint256 amount = bound(raw, 1, free);
            vm.prank(actors[who]);
            token.transfer(actors[to], amount);
            liquid[who] -= amount;
            liquid[to] += amount;
        } else if (op == 1 && free != 0 && _slots(who) < 32) {
            uint256 amount = bound(raw, 1, free);
            vm.startPrank(actors[who]);
            token.approve(address(receipt), amount);
            uint256 id = receipt.stake(amount);
            vm.stopPrank();
            liquid[who] -= amount;
            claims.push(Claim(id, who, amount, vm.getBlockTimestamp() + 120 days));
            _selfDelegate(who);
        } else if (op == 2 || op == 3) {
            address delegatee = raw % 5 == 4 ? address(0) : actors[raw % 4];
            vm.prank(actors[who]);
            if (op == 2) {
                token.delegate(delegatee);
                liquidDelegate[who] = delegatee;
            } else {
                receipt.delegate(delegatee);
                receiptDelegate[who] = delegatee;
                chosen[who] = true;
            }
        } else if (op == 4 && who != 3 && free != 0) {
            uint256 amount = bound(raw, 1, free);
            vm.startPrank(admin);
            token.setBlacklisted(actors[who], true);
            token.seize(actors[who], amount);
            token.setBlacklisted(actors[who], false);
            vm.stopPrank();
            liquid[who] -= amount;
            liquid[3] += amount;
            locked[3] += amount;
        } else if (op == 5 && to != 3 && locked[3] != 0) {
            uint256 amount = bound(raw, 1, locked[3]);
            vm.prank(admin);
            token.releaseRecovered(actors[3], actors[to], amount);
            locked[3] -= amount;
            liquid[3] -= amount;
            liquid[to] += amount;
        } else if ((op == 6 || op == 7 || op == 8) && claims.length != 0) {
            uint256 index = raw % claims.length;
            Claim storage p = claims[index];
            if (op == 6 && p.owner != 4) {
                vm.startPrank(admin);
                token.setBlacklisted(actors[p.owner], true);
                receipt.recoverPosition(p.id);
                token.setBlacklisted(actors[p.owner], false);
                vm.stopPrank();
                p.owner = 4;
            } else if (op == 7 && p.owner == 4) {
                bool underlying = (seed / 176) % 2 == 0;
                if (underlying && vm.getBlockTimestamp() >= p.maturity) {
                    vm.prank(admin);
                    receipt.releasePosition(p.id, actors[to], true);
                    liquid[to] += p.amount;
                    _remove(index);
                } else if (!underlying && _slots(to) < 32) {
                    vm.prank(admin);
                    receipt.releasePosition(p.id, actors[to], false);
                    p.owner = to;
                    _selfDelegate(to);
                }
            } else if (op == 8 && p.owner != 4 && vm.getBlockTimestamp() >= p.maturity) {
                uint256 amount = bound(seed, 1, p.amount);
                vm.prank(actors[p.owner]);
                receipt.redeem(p.id, amount);
                liquid[p.owner] += amount;
                p.amount -= amount;
                if (p.amount == 0) _remove(index);
            }
        } else if (op == 9) {
            history.push(_expected());
            vm.warp(vm.getBlockTimestamp() + bound(raw, 1, 150 days));
        } else if (op == 10 && free != 0) {
            uint256 amount = bound(raw, 1, free);
            vm.prank(actors[who]);
            token.transfer(address(receipt), amount);
            liquid[who] -= amount;
            donations += amount;
        }
        check();
        if (history.length != 0) {
            _checkPast(history[history.length - 1]);
            _checkPast(history[raw % history.length]);
        }
    }

    function _selfDelegate(uint256 who) private {
        if (!chosen[who]) {
            chosen[who] = true;
            receiptDelegate[who] = actors[who];
        }
    }

    function _slots(uint256 who) private view returns (uint256 n) {
        for (uint256 i; i < claims.length; ++i) {
            if (claims[i].owner == who) ++n;
        }
    }

    function _remove(uint256 index) private {
        claims[index] = claims[claims.length - 1];
        claims.pop();
    }

    function _expected() private view returns (Snapshot memory s) {
        s.time = vm.getBlockTimestamp();
        for (uint256 i; i < 4; ++i) {
            s.liquidRecovery += locked[i];
            for (uint256 j; j < 4; ++j) {
                if (liquidDelegate[i] == actors[j]) s.liquidVotes[j] += liquid[i] - locked[i];
            }
        }
        for (uint256 i; i < claims.length; ++i) {
            Claim memory p = claims[i];
            s.receiptSupply += p.amount;
            if (p.owner == 4) {
                s.receiptRecovery += p.amount;
            } else {
                for (uint256 j; j < 4; ++j) {
                    if (receiptDelegate[p.owner] == actors[j]) s.receiptVotes[j] += p.amount;
                }
            }
        }
    }

    function check() public view {
        Snapshot memory s = _expected();
        uint256 principal = s.receiptSupply + donations;
        for (uint256 i; i < 4; ++i) {
            principal += liquid[i];
            assertEq(token.balanceOf(actors[i]), liquid[i]);
            assertEq(token.recoveredBalanceOf(actors[i]), locked[i]);
            assertEq(token.getVotes(actors[i]), s.liquidVotes[i]);
            assertEq(receipt.getVotes(actors[i]), s.receiptVotes[i]);
        }
        assertEq(principal, 3_000_000 ether);
        assertEq(token.balanceOf(address(receipt)), s.receiptSupply + donations);
        assertEq(token.getVotes(address(receipt)), 0);
        assertEq(receipt.getVotes(address(receipt)), 0);
        assertEq(token.recoveredPrincipal(), s.liquidRecovery);
        assertEq(receipt.recoveredPrincipal(), s.receiptRecovery);
        assertEq(receipt.totalSupply(), s.receiptSupply);
    }

    function _checkPast(Snapshot storage s) private view {
        uint256 votes;
        for (uint256 i; i < 4; ++i) {
            uint256 actual = token.getPastVotes(actors[i], s.time) + receipt.getPastVotes(actors[i], s.time);
            assertEq(token.getPastVotes(actors[i], s.time), s.liquidVotes[i]);
            assertEq(receipt.getPastVotes(actors[i], s.time), s.receiptVotes[i]);
            assertEq(actual, s.liquidVotes[i] + s.receiptVotes[i]);
            votes += actual;
        }
        assertEq(token.getPastTotalSupply(s.time), 1_000_000_000 ether);
        assertEq(receipt.getPastTotalSupply(s.time), s.receiptSupply);
        assertEq(token.getPastRecoveredPrincipal(s.time), s.liquidRecovery);
        assertEq(receipt.getPastRecoveredPrincipal(s.time), s.receiptRecovery);
        assertLe(votes, 3_000_000 ether - s.liquidRecovery - s.receiptRecovery);
    }
}

contract CombinedSTRNVotesInvariant is StakedSTRNFixture {
    CombinedVotesHandler internal handler;

    function setUp() public override {
        super.setUp();
        vm.startPrank(admin);
        token.grantRole(token.RELEASER_ROLE(), admin);
        vm.stopPrank();
        handler = new CombinedVotesHandler(token, stakeToken, admin, [alice, bob, carol, recovery]);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = handler.step.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariantCombinedHistoricalVotesAndPrincipal() public view {
        handler.check();
    }
}
