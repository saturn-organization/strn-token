// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;
import {STRN} from "../../src/STRN.sol";

/// @dev TEST ONLY: executable integration requirements, not an sSTRN implementation or rewards/governance design.
contract StakingBoundary {
    struct Position {
        address owner;
        uint256 principal;
        uint256 unlockAt;
        uint256 rewardRecord;
    }
    STRN public immutable token;
    address public immutable enforcer;
    mapping(uint256 => Position) public positions;
    mapping(address => uint256) public claimWeight;
    uint256 public principalLiability;
    uint256 public nextId;

    constructor(STRN token_, address enforcer_) {
        token = token_;
        enforcer = enforcer_;
    }

    function stake(uint256 amount, uint256 unlockAt) external returns (uint256 id) {
        require(token.isProtectedStakingCustody(address(this)), "custody not protected");
        require(amount > 0 && unlockAt > block.timestamp, "invalid position");
        uint256 beforeBalance = token.balanceOf(address(this));
        token.transferFrom(msg.sender, address(this), amount);
        require(token.balanceOf(address(this)) - beforeBalance == amount, "receipt mismatch");
        id = ++nextId;
        positions[id] = Position(msg.sender, amount, unlockAt, 0);
        principalLiability += amount;
        claimWeight[msg.sender] += amount;
    }

    // Synthetic record solely to demonstrate preserving associated state; no reward economics or payout.
    function recordReward(uint256 id, uint256 value) external {
        require(msg.sender == enforcer, "enforcer only");
        positions[id].rewardRecord = value;
    }

    function recoverPosition(uint256 id) external {
        require(msg.sender == enforcer, "enforcer only");
        Position storage p = positions[id];
        require(p.principal > 0 && token.isBlacklisted(p.owner), "restricted position only");
        address to = token.seizureRecipient();
        require(!token.isBlacklisted(to) && !token.isProtectedStakingCustody(to), "invalid recovery");
        claimWeight[p.owner] -= p.principal;
        claimWeight[to] += p.principal;
        p.owner = to;
    }

    function redeem(uint256 id) external {
        Position memory p = positions[id];
        require(p.owner == msg.sender && block.timestamp >= p.unlockAt, "owner and maturity required");
        delete positions[id];
        principalLiability -= p.principal;
        claimWeight[msg.sender] -= p.principal;
        token.transfer(msg.sender, p.principal); // Failure MUST roll back the claim changes above.
    }
}
