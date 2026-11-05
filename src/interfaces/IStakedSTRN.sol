// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IERC6372} from "@openzeppelin/contracts/interfaces/IERC6372.sol";
import {ISTRNDiscount} from "./ISTRNDiscount.sol";

/// @notice Consumer interface for the nontransferable, 1:1 STRN principal receipt.
/// @dev ERC20 transfer/transferFrom/approve revert. Privileged administration is deliberately excluded.
/// ABI compatibility with StakedSTRN is enforced by scripts/check-staking-upgrade.cjs.
interface IStakedSTRN is IERC20Metadata, IVotes, IERC6372, ISTRNDiscount {
    struct Position {
        /// @dev The staking proxy itself denotes non-voting recovery custody.
        address owner;
        /// @dev Index in the ordinary owner's bounded list; not meaningful during recovery.
        uint8 index;
        uint208 principal;
        uint48 unlockAt;
    }

    event Staked(uint256 indexed id, address indexed owner, uint256 amount, uint48 unlockAt);
    event Redeemed(uint256 indexed id, address indexed owner, uint256 amount);
    event Renewed(
        uint256 indexed previousId, uint256 indexed newId, address indexed owner, uint256 amount, uint48 unlockAt
    );
    event PositionRecovered(
        uint256 indexed id, address indexed previousOwner, address indexed newOwner, uint256 amount, uint48 unlockAt
    );
    event PositionReleased(
        uint256 indexed id, address indexed recipient, uint256 amount, uint48 unlockAt, bool underlying
    );
    event DurationUpdated(uint48 previousDuration, uint48 newDuration);

    function asset() external view returns (address);
    function lockDuration() external view returns (uint48);
    function position(uint256 id) external view returns (Position memory);
    /// @notice Ordinary positions only; recovery custody has no enumerated list.
    function positionIds(address owner) external view returns (uint256[] memory);
    function activeBalanceOf(address owner) external view returns (uint256);
    /// @notice Mature ordinary claims only; excludes recovery custody.
    function maturedBalanceOf(address owner) external view returns (uint256);
    function principalLiability() external view returns (uint256);
    function recoveredPrincipal() external view returns (uint256);
    /// @notice Same timestamp clock as getPastVotes/getPastTotalSupply; timepoint must be in the past.
    function getPastRecoveredPrincipal(uint256 timepoint) external view returns (uint256);

    /// @notice Stake caller-owned principal; mints the same amount of receipts.
    function stake(uint256 amount) external returns (uint256 id);
    /// @notice Redeem caller-owned matured principal, including partial redemption.
    function redeem(uint256 id, uint256 amount) external;
    /// @notice Explicitly renew matured principal using the current duration.
    function renew(uint256 id, uint256 amount) external returns (uint256 newId);
}
