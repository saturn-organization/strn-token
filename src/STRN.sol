// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {
    ERC20VotesUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {
    AccessControlDefaultAdminRulesUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";

/// @title STRN fixed-supply token
/// @notice Transparent-proxy implementation. Privileged seizure works during pause.
/// @dev Timestamp votes exclude staking backing and seized balances. No public mint/burn or UUPS surface.
contract STRN is ERC20VotesUpgradeable, PausableUpgradeable, AccessControlDefaultAdminRulesUpgradeable {
    using Checkpoints for Checkpoints.Trace208;

    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 ether;
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant UNPAUSER_ROLE = keccak256("UNPAUSER_ROLE");
    bytes32 public constant PARAMETER_MANAGER_ROLE = keccak256("PARAMETER_MANAGER_ROLE");
    bytes32 public constant BLACKLISTER_ROLE = keccak256("BLACKLISTER_ROLE");
    bytes32 public constant SEIZER_ROLE = keccak256("SEIZER_ROLE");

    bytes32 public constant RELEASER_ROLE = keccak256("RELEASER_ROLE");

    /// @custom:storage-location erc7201:saturn.storage.STRN
    struct STRNStorage {
        mapping(address account => bool) blacklisted;
        address seizureRecipient;
        mapping(address account => bool) protectedStakingCustody;
        mapping(address account => uint256) recovered;
        uint256 recoveredTotal;
        Checkpoints.Trace208 recoveryCheckpoints;
    }

    // keccak256(abi.encode(uint256(keccak256("saturn.storage.STRN")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STRN_STORAGE_LOCATION = 0x2dd628a7fdd4ad6308cb18fc5f9b9fe3a5231bcf5405fd68368c40d9da446600;

    error InvalidAddress(address account);
    error AccountBlacklisted(address account);
    error AccountNotBlacklisted(address account);
    error InvalidSeizure();
    error CannotBlacklistAdmin();
    error ProtectedStakingCustody(address account);
    error FundedStakingCustody(address account);

    error RecoveryBalanceLocked(address account);
    error InvalidRelease();
    error InvalidDelegate(address account);

    event RecoveryReleased(address indexed custodian, address indexed recipient, uint256 amount);
    event SeizureRecipientUpdated(address indexed previousRecipient, address indexed newRecipient);
    event StakingCustodyProtectionUpdated(address indexed account, bool protected);

    event BlacklistUpdated(address indexed account, bool status);
    event Seized(address indexed operator, address indexed from, address indexed recipient, uint256 amount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Must be encoded into the proxy constructor; addresses are explicit deployment inputs.
    function initialize(address admin, address initialRecipient, address seizureRecipient_, uint48 adminDelay)
        external
        initializer
    {
        _validateAddress(admin);
        _validateAddress(initialRecipient);
        _validateAddress(seizureRecipient_);
        __ERC20_init("Saturn", "STRN");
        __ERC20Votes_init();
        __EIP712_init("Saturn", "1");
        __Pausable_init();
        __AccessControlDefaultAdminRules_init(adminDelay, admin);
        _getSTRNStorage().seizureRecipient = seizureRecipient_;
        _mint(initialRecipient, INITIAL_SUPPLY);
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(UNPAUSER_ROLE) {
        _unpause();
    }

    function isBlacklisted(address account) public view returns (bool) {
        return _getSTRNStorage().blacklisted[account];
    }

    function seizureRecipient() public view returns (address) {
        return _getSTRNStorage().seizureRecipient;
    }

    function setBlacklisted(address account, bool status) external onlyRole(BLACKLISTER_ROLE) {
        _validateAddress(account);
        if (status && hasRole(DEFAULT_ADMIN_ROLE, account)) revert CannotBlacklistAdmin();
        STRNStorage storage $ = _getSTRNStorage();
        if ($.blacklisted[account] != status) {
            $.blacklisted[account] = status;
            emit BlacklistUpdated(account, status);
        }
    }

    /// @notice Confiscate a positive amount from a blacklisted source to the configured recipient.
    /// @dev Deliberate pause/source-blacklist bypass, with no external call or allowance modification.
    function seize(address from, uint256 amount) external onlyRole(SEIZER_ROLE) {
        if (isProtectedStakingCustody(from)) revert ProtectedStakingCustody(from);
        if (!isBlacklisted(from)) revert AccountNotBlacklisted(from);
        address recipient = seizureRecipient();
        if (from == recipient || amount == 0) revert InvalidSeizure();
        _requireNotBlacklisted(recipient);
        _requireAvailable(from, amount);
        STRNStorage storage $ = _getSTRNStorage();
        ERC20Upgradeable._update(from, recipient, amount);
        $.recovered[recipient] += amount;
        $.recoveredTotal += amount;
        _moveDelegateVotes(delegates(from), address(0), amount);
        _checkpointRecovery();
        emit Seized(_msgSender(), from, recipient, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        _requireNotPaused();
        _requireNotBlacklisted(_msgSender());
        _requireNotBlacklisted(from);
        _requireNotBlacklisted(to);
        if (from != address(0)) _requireAvailable(from, value);
        super._update(from, to, value);
    }

    /// @notice Release a specified seized balance immediately under separate authority, including during pause.
    function releaseRecovered(address custodian, address recipient, uint256 amount) external onlyRole(RELEASER_ROLE) {
        _validateAddress(recipient);
        _requireNotBlacklisted(recipient);
        if (isProtectedStakingCustody(recipient)) revert ProtectedStakingCustody(recipient);
        STRNStorage storage $ = _getSTRNStorage();
        if (amount == 0 || amount > $.recovered[custodian] || custodian == recipient) revert InvalidRelease();
        $.recovered[custodian] -= amount;
        $.recoveredTotal -= amount;
        ERC20Upgradeable._update(custodian, recipient, amount);
        _moveDelegateVotes(address(0), delegates(recipient), amount);
        _checkpointRecovery();
        emit RecoveryReleased(custodian, recipient, amount);
    }

    function recoveredBalanceOf(address account) public view returns (uint256) {
        return _getSTRNStorage().recovered[account];
    }

    function recoveredPrincipal() public view returns (uint256) {
        return _getSTRNStorage().recoveredTotal;
    }

    function getPastRecoveredPrincipal(uint256 timepoint) public view returns (uint256) {
        return _getSTRNStorage().recoveryCheckpoints.upperLookupRecent(_validateTimepoint(timepoint));
    }

    function clock() public view override returns (uint48) {
        return SafeCast.toUint48(block.timestamp);
    }

    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }

    function _checkpointRecovery() private {
        _getSTRNStorage().recoveryCheckpoints.push(clock(), SafeCast.toUint208(recoveredPrincipal()));
    }

    function _requireAvailable(address account, uint256 amount) private view {
        uint256 locked = recoveredBalanceOf(account);
        if (locked != 0 && amount > balanceOf(account) - locked) revert RecoveryBalanceLocked(account);
    }

    function _getVotingUnits(address account) internal view override returns (uint256) {
        return isProtectedStakingCustody(account) ? 0 : balanceOf(account) - recoveredBalanceOf(account);
    }

    function _delegate(address account, address delegatee) internal override {
        _requireNotBlacklisted(account);
        if (isProtectedStakingCustody(account)) revert InvalidDelegate(account);
        if (delegatee != address(0)) _requireNotBlacklisted(delegatee);
        super._delegate(account, delegatee);
    }

    /// @notice Only the parameter manager can redirect future seizures; existing balances do not move.
    function setSeizureRecipient(address newRecipient) external onlyRole(PARAMETER_MANAGER_ROLE) {
        _validateAddress(newRecipient);
        _requireNotBlacklisted(newRecipient);
        if (isProtectedStakingCustody(newRecipient)) revert ProtectedStakingCustody(newRecipient);
        STRNStorage storage $ = _getSTRNStorage();
        address previous = $.seizureRecipient;
        $.seizureRecipient = newRecipient;
        emit SeizureRecipientUpdated(previous, newRecipient);
    }

    function isProtectedStakingCustody(address account) public view returns (bool) {
        return _getSTRNStorage().protectedStakingCustody[account];
    }

    /// @notice Governance designates reviewed staking custody, not arbitrary holders.
    /// @dev Code presence is only a sanity check, not staking attestation. Funded protection cannot be removed.
    function setStakingCustodyProtection(address account, bool protected) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _validateAddress(account);
        if (protected) {
            if (account.code.length == 0 || account == seizureRecipient() || recoveredBalanceOf(account) != 0) {
                revert InvalidAddress(account);
            }
        } else if (balanceOf(account) != 0) {
            revert FundedStakingCustody(account);
        }
        STRNStorage storage $ = _getSTRNStorage();
        if ($.protectedStakingCustody[account] != protected) {
            // Clear this account's outgoing delegation BEFORE excluding its units.
            // Votes delegated here by other holders remain those holders' voting authority.
            if (protected) super._delegate(account, address(0));
            $.protectedStakingCustody[account] = protected;
            emit StakingCustodyProtectionUpdated(account, protected);
        }
    }

    /// @dev Do not admit an already-blacklisted account into the protected default-admin role.
    function acceptDefaultAdminTransfer() public override {
        _requireNotBlacklisted(_msgSender());
        super.acceptDefaultAdminTransfer();
    }

    function _requireNotBlacklisted(address account) private view {
        if (isBlacklisted(account)) revert AccountBlacklisted(account);
    }

    function _validateAddress(address account) private view {
        if (account == address(0) || account == address(this)) revert InvalidAddress(account);
    }

    function _getSTRNStorage() private pure returns (STRNStorage storage $) {
        assembly ("memory-safe") {
            $.slot := STRN_STORAGE_LOCATION
        }
    }
}
