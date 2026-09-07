// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title OffsetDelta
/// @notice Converts a belief offset (delta, in Q64.64 log-price units) into the
///         signed token amount a swap must be adjusted by, per spec section 4.
library OffsetDelta {
    /// @dev Q64.64 scaling factor.
    int256 internal constant ONE_X64 = int256(1) << 64;

    /// @notice Computes the offset amount A = N * (e^d - 1), using the second-order
    ///         Taylor expansion e^d - 1 ~= d + d^2/2 from eq (4.2).
    /// @dev Valid only for small |d|; the caller clamps d to deltaMax. The cubic
    ///      remainder is ~d^3/6, below one wei of a realistic trade at d = 0.01.
    /// @param notional The trade notional, in numeraire token units.
    /// @param deltaX64 The belief offset in Q64.64.
    /// @return amount The offset magnitude in the same units as `notional`.
    function offsetAmount(uint256 notional, int256 deltaX64) internal pure returns (uint256 amount) {
        // d + d^2/2 in Q64.64. d^2 needs a shift back down to Q64.64 after multiply.
        int256 dSquaredHalfX64 = (deltaX64 * deltaX64) / (2 * ONE_X64);
        int256 factorX64 = deltaX64 + dSquaredHalfX64;

        uint256 magnitudeX64 = factorX64 < 0 ? uint256(-factorX64) : uint256(factorX64);
        amount = (notional * magnitudeX64) >> 64;
    }

    /// @notice Returns the exact Taylor factor (d + d^2/2) in Q64.64, signed.
    /// @dev Exposed for differential testing against a high-precision reference.
    function taylorFactorX64(int256 deltaX64) internal pure returns (int256 factorX64) {
        int256 dSquaredHalfX64 = (deltaX64 * deltaX64) / (2 * ONE_X64);
        factorX64 = deltaX64 + dSquaredHalfX64;
    }
}
