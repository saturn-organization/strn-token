// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;
import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {STRN} from "../src/STRN.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @dev Independent finite-domain ledger: expected successes and failures checked after EVERY operation.
contract STRNHandler is Test {
    STRN public immutable token;
    address[5] public actors;
    uint256[5] public balances;
    uint256[5][5] public approvals;
    bool[5] public blocked;
    bool public paused;
    uint256 public recovery = 4;
    bool[5] public protectedCustody;
    uint256[5] public locked;
    address[5] public delegatees;
    uint256 public successes;
    uint256 public rejections;

    constructor(STRN token_) {
        token = token_;
        for (uint256 i; i < 5; i++) {
            actors[i] = address(uint160(0x100 + i));
        }
        balances[0] = 1_000_000_000 ether;
    }

    function transfer(uint8 a, uint8 b, uint256 raw, bool validAmount) external {
        uint256 i = a % 5;
        uint256 j = b % 5;
        uint256 n = validAmount ? bound(raw, 0, balances[i]) : raw;
        bool expected = !paused && !blocked[i] && !blocked[j] && n <= balances[i] - locked[i];
        vm.prank(actors[i]);
        (bool ok,) = address(token).call(abi.encodeCall(token.transfer, (actors[j], n)));
        _outcome(ok, expected);
        if (ok) {
            balances[i] -= n;
            balances[j] += n;
        }
        check();
    }

    function approve(uint8 a, uint8 b, uint256 raw, uint8 mode) external {
        uint256 i = a % 5;
        uint256 j = b % 5;
        uint256 n = mode % 3 == 0 ? 0 : mode % 3 == 1 ? type(uint256).max : raw;
        bool expected = true;
        vm.prank(actors[i]);
        (bool ok,) = address(token).call(abi.encodeCall(token.approve, (actors[j], n)));
        _outcome(ok, expected);
        if (ok) approvals[i][j] = n;
        check();
    }

    function spend(uint8 a, uint8 b, uint8 c, uint256 raw, bool validAmount) external {
        uint256 i = a % 5;
        uint256 j = b % 5;
        uint256 k = c % 5;
        uint256 limit = balances[i] < approvals[i][k] ? balances[i] : approvals[i][k];
        uint256 n = validAmount ? bound(raw, 0, limit) : raw;
        bool expected = !paused && !blocked[i] && !blocked[j] && !blocked[k] && n <= balances[i] - locked[i]
            && n <= approvals[i][k];
        vm.prank(actors[k]);
        (bool ok,) = address(token).call(abi.encodeCall(token.transferFrom, (actors[i], actors[j], n)));
        _outcome(ok, expected);
        if (ok) {
            balances[i] -= n;
            balances[j] += n;
            if (approvals[i][k] != type(uint256).max) approvals[i][k] -= n;
        }
        check();
    }

    function blacklist(uint8 a, bool status) external {
        uint256 i = a % 5;
        token.setBlacklisted(actors[i], status);
        blocked[i] = status;
        check();
    }

    function togglePause() external {
        if (paused) token.unpause();
        else token.pause();
        paused = !paused;
        check();
    }

    function seize(uint8 a, uint256 raw, bool validAmount) external {
        uint256 i = a % 5;
        uint256 n = validAmount ? bound(raw, 0, balances[i]) : raw;
        bool expected = blocked[i] && i != recovery && !blocked[recovery] && !protectedCustody[i] && n > 0
            && n <= balances[i] - locked[i];
        (bool ok,) = address(token).call(abi.encodeCall(token.seize, (actors[i], n)));
        _outcome(ok, expected);
        if (ok) {
            balances[i] -= n;
            balances[recovery] += n;
            locked[recovery] += n;
        }
        check();
    }

    function setRecovery(uint8 a) external {
        uint256 i = a % 5;
        (bool ok,) = address(token).call(abi.encodeCall(token.setSeizureRecipient, (actors[i])));
        _outcome(ok, !blocked[i] && !protectedCustody[i]);
        if (ok) recovery = i;
        check();
    }

    function protectCustody(uint8 a, bool status) external {
        uint256 i = a % 5;
        bool expected = status ? i != recovery && locked[i] == 0 : balances[i] == 0;
        (bool ok,) = address(token).call(abi.encodeCall(token.setStakingCustodyProtection, (actors[i], status)));
        _outcome(ok, expected);
        if (ok) {
            if (status && !protectedCustody[i]) delegatees[i] = address(0);
            protectedCustody[i] = status;
        }
        check();
    }

    function delegate(uint8 a, uint8 b) external {
        uint256 i = a % 5;
        uint256 j = b % 6;
        address to = j == 5 ? address(0) : actors[j];
        bool expected = !blocked[i] && !protectedCustody[i] && (j == 5 || !blocked[j]);
        vm.prank(actors[i]);
        (bool ok,) = address(token).call(abi.encodeCall(token.delegate, (to)));
        _outcome(ok, expected);
        if (ok) delegatees[i] = to;
        check();
    }

    function release(uint8 a, uint8 b, uint256 raw) external {
        uint256 i = a % 5;
        uint256 j = b % 5;
        uint256 n = bound(raw, 0, locked[i]);
        bool expected = i != j && n > 0 && !blocked[j] && !protectedCustody[j];
        (bool ok,) = address(token).call(abi.encodeCall(token.releaseRecovered, (actors[i], actors[j], n)));
        _outcome(ok, expected);
        if (ok) {
            locked[i] -= n;
            balances[i] -= n;
            balances[j] += n;
        }
        check();
    }

    function advanceTime() external {
        uint256 t = vm.getBlockTimestamp();
        uint256[5] memory votes;
        for (uint256 i; i < 5; ++i) {
            votes[i] = token.getVotes(actors[i]);
        }
        uint256 recovered = token.recoveredPrincipal();
        vm.warp(t + 1);
        for (uint256 i; i < 5; ++i) {
            assertEq(token.getPastVotes(actors[i], t), votes[i]);
        }
        assertEq(token.getPastRecoveredPrincipal(t), recovered);
        assertEq(token.getPastTotalSupply(t), token.INITIAL_SUPPLY());
        check();
    }

    function attack(uint8 a, uint8 kind) external {
        uint256 i = a % 5;
        bytes memory data;
        if (kind % 8 == 0) data = abi.encodeCall(token.grantRole, (token.SEIZER_ROLE(), actors[i]));
        else if (kind % 8 == 1) data = abi.encodeCall(token.pause, ());
        else if (kind % 8 == 2) data = abi.encodeCall(token.seize, (actors[0], 1));
        else if (kind % 8 == 3) data = abi.encodeCall(token.initialize, (actors[i], actors[i], actors[i], uint48(0)));
        else if (kind % 8 == 4) data = abi.encodeCall(token.setSeizureRecipient, (actors[i]));
        else if (kind % 8 == 5) data = abi.encodeCall(token.setStakingCustodyProtection, (actors[i], true));
        else if (kind % 8 == 6) data = abi.encodeCall(token.unpause, ());
        else data = abi.encodeWithSignature("mint(address,uint256)", actors[i], 1);
        vm.prank(actors[i]);
        (bool ok,) = address(token).call(data);
        _outcome(ok, false);
        check();
    }

    function _outcome(bool ok, bool expected) internal {
        assertEq(ok, expected, "model outcome");
        if (ok) successes++;
        else rejections++;
    }

    function check() public view {
        uint256 sum;
        for (uint256 i; i < 5; i++) {
            sum += balances[i];
            assertEq(token.balanceOf(actors[i]), balances[i], "balance model");
            assertEq(token.recoveredBalanceOf(actors[i]), locked[i], "locked model");
            assertEq(token.isBlacklisted(actors[i]), blocked[i], "blacklist model");
            assertEq(token.isProtectedStakingCustody(actors[i]), protectedCustody[i]);
            assertFalse(token.hasRole(token.SEIZER_ROLE(), actors[i]));
            assertFalse(token.hasRole(bytes32(0), actors[i]));
            for (uint256 j; j < 5; j++) {
                assertEq(token.allowance(actors[i], actors[j]), approvals[i][j], "allowance model");
            }
        }
        assertEq(sum, 1_000_000_000 ether);
        uint256 recovered;
        for (uint256 i; i < 5; ++i) {
            recovered += locked[i];
            uint256 votes;
            for (uint256 j; j < 5; ++j) {
                if (delegatees[j] == actors[i] && !protectedCustody[j]) votes += balances[j] - locked[j];
            }
            assertEq(token.getVotes(actors[i]), votes, "votes model");
            assertEq(token.delegates(actors[i]), delegatees[i], "delegate model");
        }
        assertEq(token.recoveredPrincipal(), recovered);
        assertEq(token.totalSupply(), sum);
        assertEq(token.paused(), paused);
        assertEq(token.seizureRecipient(), actors[recovery]);
    }
}

contract STRNInvariant is StdInvariant, Test {
    STRNHandler public handler;

    function setUp() public {
        STRN token = STRN(
            address(
                new TransparentUpgradeableProxy(
                    address(new STRN()),
                    address(0x999),
                    abi.encodeCall(STRN.initialize, (address(this), address(0x100), address(0x104), uint48(2 days)))
                )
            )
        );
        handler = new STRNHandler(token);
        token.grantRole(token.PAUSER_ROLE(), address(handler));
        token.grantRole(token.UNPAUSER_ROLE(), address(handler));
        token.grantRole(token.PARAMETER_MANAGER_ROLE(), address(handler));
        token.grantRole(token.BLACKLISTER_ROLE(), address(handler));
        token.grantRole(token.SEIZER_ROLE(), address(handler));
        token.grantRole(token.RELEASER_ROLE(), address(handler));
        // Model contract custody without introducing external calls into the token.
        for (uint256 i; i < 5; i++) {
            vm.etch(address(uint160(0x100 + i)), hex"00");
        }
        token.beginDefaultAdminTransfer(address(handler));
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(address(handler));
        token.acceptDefaultAdminTransfer();
        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.spend.selector;
        selectors[3] = handler.blacklist.selector;
        selectors[4] = handler.togglePause.selector;
        selectors[5] = handler.seize.selector;
        selectors[6] = handler.attack.selector;
        selectors[7] = handler.setRecovery.selector;
        selectors[8] = handler.protectCustody.selector;
        selectors[9] = handler.delegate.selector;
        selectors[10] = handler.release.selector;
        selectors[11] = handler.advanceTime.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariantAccountingAndRestrictions() public view {
        handler.check();
    }
}
