// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;
import {StakedSTRN} from "../../src/StakedSTRN.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

/// @dev Upgrade-only fixture: v1 initializes inherited state; the reinitializer initializes only new state.
/// @custom:oz-upgrades-unsafe-allow missing-initializer
contract StakedSTRNV2 is StakedSTRN {
    /// @custom:storage-location erc7201:saturn.storage.StakedSTRNV2
    struct V2Storage {
        uint256 marker;
    }

    function initializeV2(uint256 value) external reinitializer(2) {
        require(msg.sender == ERC1967Utils.getAdmin(), "proxy admin only");
        _v2().marker = value;
    }

    function marker() external view returns (uint256) {
        return _v2().marker;
    }

    function _v2() private pure returns (V2Storage storage s) {
        bytes32 slot =
            keccak256(abi.encode(uint256(keccak256("saturn.storage.StakedSTRNV2")) - 1)) & ~bytes32(uint256(255));
        assembly ("memory-safe") { s.slot := slot }
    }
}
