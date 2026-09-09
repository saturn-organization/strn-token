// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {
    ERC20VotesUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {
    AccessControlDefaultAdminRulesUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {STRN} from "./STRN.sol";
import {ISTRNDiscount} from "./interfaces/ISTRNDiscount.sol";

/// @notice Nontransferable 1:1 principal receipt. Rewards are funded and settled separately.
/// @dev Transparent proxy; requires a chain supporting Cancun/EIP-1153. See docs/SSTRN_SPEC.md.
contract StakedSTRN is
    ERC20VotesUpgradeable,
    PausableUpgradeable,
    AccessControlDefaultAdminRulesUpgradeable,
    ReentrancyGuardTransient,
    ISTRNDiscount
{
    using SafeERC20 for IERC20;
    using Checkpoints for Checkpoints.Trace208;

    uint256 public constant MAX_POSITIONS = 32;
    uint48 public constant MIN_DURATION = 1 days;
    uint48 public constant MAX_DURATION = 365 days;
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant UNPAUSER_ROLE = keccak256("UNPAUSER_ROLE");
    bytes32 public constant PARAMETER_MANAGER_ROLE = keccak256("PARAMETER_MANAGER_ROLE");
    bytes32 public constant SEIZER_ROLE = keccak256("SEIZER_ROLE");
    bytes32 public constant RELEASER_ROLE = keccak256("RELEASER_ROLE");

    struct Position {
        address owner;
        uint8 index;
        uint208 principal;
        uint48 unlockAt;
    }

    /// @custom:storage-location erc7201:saturn.storage.StakedSTRN
    struct StakedSTRNStorage {
        STRN token;
        uint48 duration;
        uint256 nextId;
        mapping(uint256 id => Position) positions;
        mapping(address owner => uint256[]) owned;
        mapping(address owner => bool) delegationChosen;
        Checkpoints.Trace208 recoveryCheckpoints;
    }

    bytes32 private constant STORAGE_LOCATION = 0xd8100afb5b835a8f9c375e3fce4ebd36ec99db50f222b771c370f0b38e39b700;

    error InvalidAddress();
    error InvalidAmount();
    error InvalidDuration();
    error RestrictedAccount(address account);
    error CustodyNotProtected();
    error TooManyPositions();
    error NotPositionOwner();
    error PositionNotMature();
    error Nontransferable();
    error ReceiptMismatch();
    error InvalidRecovery();

    event Staked(uint256 indexed id, address indexed owner, uint256 amount, uint48 unlockAt);
    event Redeemed(uint256 indexed id, address indexed owner, uint256 amount);
    event Renewed(
        uint256 indexed previousId, uint256 indexed newId, address indexed owner, uint256 amount, uint48 unlockAt
    );
    event PositionRecovered(
        uint256 indexed id, address indexed previousOwner, address indexed newOwner, uint256 amount, uint48 unlockAt
    );
    event DurationUpdated(uint48 previousDuration, uint48 newDuration);
    event ExcessRecovered(address indexed recipient, uint256 amount);
    event PositionReleased(
        uint256 indexed id, address indexed recipient, uint256 amount, uint48 unlockAt, bool underlying
    );

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin, address token_, uint48 duration_, uint48 adminDelay) external initializer {
        if (admin == address(0) || admin == address(this) || token_ == address(this) || token_.code.length == 0) {
            revert InvalidAddress();
        }
        _validateDuration(duration_);
        __ERC20_init("Staked Saturn", "sSTRN");
        __EIP712_init("Staked Saturn", "1");
        __ERC20Votes_init();
        __Pausable_init();
        __AccessControlDefaultAdminRules_init(adminDelay, admin);
        StakedSTRNStorage storage s = _store();
        s.token = STRN(token_);
        s.duration = duration_;
    }

    function asset() public view returns (STRN) {
        return _store().token;
    }

    function lockDuration() public view returns (uint48) {
        return _store().duration;
    }

    function position(uint256 id) external view returns (Position memory) {
        return _store().positions[id];
    }

    function positionIds(address owner) external view returns (uint256[] memory) {
        return _store().owned[owner];
    }

    function principalLiability() external view returns (uint256) {
        return totalSupply();
    }

    function clock() public view override returns (uint48) {
        return SafeCast.toUint48(block.timestamp);
    }

    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }

    function _maxSupply() internal pure override returns (uint256) {
        return 1_000_000_000 ether;
    }

    function activeBalanceOf(address owner) public view returns (uint256 amount) {
        StakedSTRNStorage storage s = _store();
        uint256[] storage ids = s.owned[owner];
        for (uint256 i; i < ids.length; ++i) {
            Position storage p = s.positions[ids[i]];
            if (block.timestamp < p.unlockAt) amount += p.principal;
        }
    }

    function maturedBalanceOf(address owner) external view returns (uint256) {
        if (owner == address(this)) return 0;
        return balanceOf(owner) - activeBalanceOf(owner);
    }

    /// @notice Recovery receipts remain principal liabilities but cannot vote or provide utility.
    function recoveredPrincipal() public view returns (uint256) {
        return balanceOf(address(this));
    }

    function getPastRecoveredPrincipal(uint256 timepoint) external view returns (uint256) {
        return _store().recoveryCheckpoints.upperLookupRecent(_validateTimepoint(timepoint));
    }

    function getFeeDiscountBps(address owner) external view returns (uint256) {
        STRN token = asset();
        if (paused() || token.paused() || token.isBlacklisted(owner) || token.isBlacklisted(address(this))) return 0;
        uint256 active = activeBalanceOf(owner);
        if (active < 5000 ether) return 0;
        if (active >= 100_000 ether) return 2500;
        return active * 2500 / 100_000 ether;
    }

    function stake(uint256 amount) external nonReentrant whenNotPaused returns (uint256 id) {
        _requireEligible(msg.sender);
        _requireProtected();
        if (amount == 0 || amount > _maxSupply()) revert InvalidAmount();
        StakedSTRNStorage storage s = _store();
        if (s.owned[msg.sender].length == MAX_POSITIONS) revert TooManyPositions();
        STRN token = s.token;
        uint256 beforeBalance = token.balanceOf(address(this));
        IERC20(address(token)).safeTransferFrom(msg.sender, address(this), amount);
        if (token.balanceOf(address(this)) != beforeBalance + amount) revert ReceiptMismatch();
        uint48 expiry = SafeCast.toUint48(block.timestamp + s.duration);
        id = _newPosition(msg.sender, amount, expiry);
        _ensureDelegate(msg.sender);
        _mint(msg.sender, amount);
        emit Staked(id, msg.sender, amount, expiry);
    }

    function redeem(uint256 id, uint256 amount) external nonReentrant {
        _requireEligible(msg.sender);
        IERC20 token = IERC20(address(asset()));
        uint256 held = token.balanceOf(address(this));
        uint256 received = token.balanceOf(msg.sender);
        Position storage p = _ownedMaturePosition(id, amount);
        p.principal -= uint208(amount);
        if (p.principal == 0) _remove(id);
        _burn(msg.sender, amount);
        token.safeTransfer(msg.sender, amount);
        if (token.balanceOf(address(this)) + amount != held || token.balanceOf(msg.sender) != received + amount) {
            revert ReceiptMismatch();
        }
        emit Redeemed(id, msg.sender, amount);
    }

    function renew(uint256 id, uint256 amount) external nonReentrant whenNotPaused returns (uint256 newId) {
        _requireEligible(msg.sender);
        _requireProtected();
        Position storage p = _ownedMaturePosition(id, amount);
        uint48 expiry = SafeCast.toUint48(block.timestamp + lockDuration());
        if (amount == p.principal) {
            p.unlockAt = expiry;
            newId = id;
        } else {
            p.principal -= uint208(amount);
            newId = _newPosition(msg.sender, amount, expiry);
        }
        emit Renewed(id, newId, msg.sender, amount, expiry);
    }

    /// @notice Preserves principal backing, exact maturity and position ID.
    /// @dev External points policy distinguishes verified rescue from confirmed enforcement.
    function recoverPosition(uint256 id) external nonReentrant onlyRole(SEIZER_ROLE) {
        StakedSTRNStorage storage s = _store();
        Position memory p = s.positions[id];
        if (
            p.owner == address(0) || p.owner == address(this) || !s.token.isBlacklisted(p.owner)
                || hasRole(DEFAULT_ADMIN_ROLE, p.owner)
        ) {
            revert InvalidRecovery();
        }
        _remove(id);
        s.positions[id] = Position(address(this), 0, p.principal, p.unlockAt);
        // Custody can never delegate: OZ removes the old votes without burning supply.
        super._update(p.owner, address(this), p.principal);
        _checkpointRecovery();
        emit PositionRecovered(id, p.owner, address(this), p.principal, p.unlockAt);
    }

    /// @notice Immediate authorized release; neither seizure authority nor recovery-wallet ownership suffices.
    function releasePosition(uint256 id, address recipient, bool redeemUnderlying)
        external
        nonReentrant
        onlyRole(RELEASER_ROLE)
    {
        StakedSTRNStorage storage s = _store();
        Position memory p = s.positions[id];
        if (p.owner != address(this)) revert InvalidRecovery();
        _requireEligible(recipient);
        if (s.token.isProtectedStakingCustody(recipient)) revert InvalidRecovery();
        if (redeemUnderlying) {
            if (block.timestamp < p.unlockAt) revert PositionNotMature();
            uint256 held = s.token.balanceOf(address(this));
            uint256 received = s.token.balanceOf(recipient);
            delete s.positions[id];
            _burn(address(this), p.principal);
            _checkpointRecovery();
            IERC20(address(s.token)).safeTransfer(recipient, p.principal);
            if (
                s.token.balanceOf(address(this)) + p.principal != held
                    || s.token.balanceOf(recipient) != received + p.principal
            ) {
                revert ReceiptMismatch();
            }
        } else {
            uint256 length = s.owned[recipient].length;
            if (length == MAX_POSITIONS) revert TooManyPositions();
            s.positions[id] = Position(recipient, uint8(length), p.principal, p.unlockAt);
            s.owned[recipient].push(id);
            _ensureDelegate(recipient);
            super._update(address(this), recipient, p.principal);
            _checkpointRecovery();
        }
        emit PositionReleased(id, recipient, p.principal, p.unlockAt, redeemUnderlying);
    }

    function _checkpointRecovery() private {
        // push persists the checkpoint; its returned old/new values are informational, not success flags.
        _store().recoveryCheckpoints.push(clock(), SafeCast.toUint208(recoveredPrincipal()));
    }

    function excessUnderlying() public view returns (uint256) {
        uint256 held = asset().balanceOf(address(this));
        return held > totalSupply() ? held - totalSupply() : 0;
    }

    function recoverExcess(uint256 amount) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        if (amount == 0 || amount > excessUnderlying()) revert InvalidAmount();
        address to = _recoveryRecipient();
        IERC20(address(asset())).safeTransfer(to, amount);
        emit ExcessRecovered(to, amount);
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(UNPAUSER_ROLE) {
        _unpause();
    }

    function setLockDuration(uint48 duration) external onlyRole(PARAMETER_MANAGER_ROLE) {
        _validateDuration(duration);
        emit DurationUpdated(lockDuration(), duration);
        _store().duration = duration;
    }

    function acceptDefaultAdminTransfer() public override {
        _requireEligible(msg.sender);
        super.acceptDefaultAdminTransfer();
    }

    function approve(address, uint256) public pure override returns (bool) {
        revert Nontransferable();
    }

    function transfer(address, uint256) public pure override returns (bool) {
        revert Nontransferable();
    }

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        revert Nontransferable();
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) revert Nontransferable();
        super._update(from, to, value);
    }

    function _delegate(address account, address delegatee) internal override {
        _requireEligible(account);
        if (delegatee != address(0)) _requireEligible(delegatee);
        _store().delegationChosen[account] = true;
        super._delegate(account, delegatee);
    }

    function _ensureDelegate(address owner) private {
        if (!_store().delegationChosen[owner]) _delegate(owner, owner);
    }

    function _ownedMaturePosition(uint256 id, uint256 amount) private view returns (Position storage p) {
        p = _store().positions[id];
        if (p.owner != msg.sender) revert NotPositionOwner();
        if (block.timestamp < p.unlockAt) revert PositionNotMature();
        if (amount == 0 || amount > p.principal) revert InvalidAmount();
    }

    function _newPosition(address owner, uint256 amount, uint48 expiry) private returns (uint256 id) {
        StakedSTRNStorage storage s = _store();
        uint256 length = s.owned[owner].length;
        if (length == MAX_POSITIONS) revert TooManyPositions();
        id = ++s.nextId;
        s.positions[id] = Position(owner, uint8(length), SafeCast.toUint208(amount), expiry);
        s.owned[owner].push(id);
    }

    function _remove(uint256 id) private {
        StakedSTRNStorage storage s = _store();
        Position storage p = s.positions[id];
        uint256[] storage ids = s.owned[p.owner];
        uint256 last = ids[ids.length - 1];
        ids[p.index] = last;
        s.positions[last].index = p.index;
        ids.pop();
        delete s.positions[id];
    }

    function _requireEligible(address account) private view {
        if (account == address(0) || account == address(this)) revert InvalidAddress();
        if (asset().isBlacklisted(account)) revert RestrictedAccount(account);
    }

    function _requireProtected() private view {
        STRN token = asset();
        if (token.paused()) revert EnforcedPause();
        if (!token.isProtectedStakingCustody(address(this))) revert CustodyNotProtected();
        if (token.isBlacklisted(address(this))) revert RestrictedAccount(address(this));
    }

    function _recoveryRecipient() private view returns (address to) {
        STRN token = asset();
        to = token.seizureRecipient();
        _requireEligible(to);
        if (token.isProtectedStakingCustody(to)) revert InvalidRecovery();
    }

    function _validateDuration(uint48 duration) private pure {
        if (duration < MIN_DURATION || duration > MAX_DURATION) revert InvalidDuration();
    }

    function _store() private pure returns (StakedSTRNStorage storage s) {
        assembly ("memory-safe") { s.slot := STORAGE_LOCATION }
    }
}
