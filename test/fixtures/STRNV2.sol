// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {STRN} from "../../src/STRN.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

/// @dev Test-only migration fixture, shared by runtime and compiler-backed upgrade checks.
///      Upgrade-only: v1 has already initialized every parent. initializeV2 initializes only new state.
///      The v1 initializer is validated separately and must never be rerun during migration.
/// @custom:oz-upgrades-unsafe-allow missing-initializer
contract STRNV2 is STRN {
    /// @custom:storage-location erc7201:saturn.storage.STRNV2
    struct V2Storage {
        uint256 marker;
    }

    error UnauthorizedMigration();

    // Derived ERC-7201 namespace; tests independently read the derived slot.
    function _getV2Storage() private pure returns (V2Storage storage $) {
        bytes32 slot = keccak256(abi.encode(uint256(keccak256("saturn.storage.STRNV2")) - 1)) & ~bytes32(uint256(255));
        assembly ("memory-safe") {
            $.slot := slot
        }
    }

    /// @dev Run atomically via ProxyAdmin.upgradeAndCall, not as a public post-upgrade transaction.
    function initializeV2(uint256 marker_) external reinitializer(2) {
        if (msg.sender != ERC1967Utils.getAdmin()) revert UnauthorizedMigration();
        _getV2Storage().marker = marker_;
    }

    function setMarker(uint256 marker_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _getV2Storage().marker = marker_;
    }

    function marker() external view returns (uint256) {
        return _getV2Storage().marker;
    }

    function version() external pure returns (uint256) {
        return 2;
    }
}
