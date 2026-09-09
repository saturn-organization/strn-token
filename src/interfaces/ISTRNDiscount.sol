// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @notice Percentage only; a product must separately enforce any cumulative fee budget.
interface ISTRNDiscount {
    /// @return Basis-point reduction of the entire nominal fee (0..2500).
    function getFeeDiscountBps(address owner) external view returns (uint256);
}
