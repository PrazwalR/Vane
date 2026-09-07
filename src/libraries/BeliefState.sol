// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title BeliefState
/// @notice Belief offset update and decay, per spec eq (2.7).
library BeliefState {
    int256 internal constant ONE_X64 = int256(1) << 64;

    /// @notice Applies one block of decay: d <- (1 - theta) * d.
    /// @param deltaX64 Current belief in Q64.64.
    /// @param thetaX64 Decay rate per block in Q64.64, strictly within (0, 1).
    function decay(int256 deltaX64, uint256 thetaX64) internal pure returns (int256) {
        int256 retained = ONE_X64 - int256(thetaX64);
        return (deltaX64 * retained) / ONE_X64;
    }

    /// @notice Applies flow to the belief and clamps: d <- clamp(d + kappa * dq, +-deltaMax).
    /// @param deltaX64 Current belief in Q64.64.
    /// @param kappaX64 Impact gain in Q64.64 per unit notional.
    /// @param signedFlow Signed notional this block; positive buys the risky asset.
    /// @param deltaMaxX64 Absolute clamp on the resulting belief.
    function update(int256 deltaX64, int256 kappaX64, int256 signedFlow, int256 deltaMaxX64)
        internal
        pure
        returns (int256)
    {
        int256 next = deltaX64 + (kappaX64 * signedFlow) / ONE_X64;
        if (next > deltaMaxX64) return deltaMaxX64;
        if (next < -deltaMaxX64) return -deltaMaxX64;
        return next;
    }

    /// @notice Scales the belief by reserve adequacy, per eq (5.2).
    /// @dev Graceful degradation: as the reserve drains the mechanism turns itself
    ///      off rather than reverting, so the pool degrades to a plain v4 pool.
    function scaleForReserve(int256 deltaX64, uint256 reserve, uint256 reserveTarget)
        internal
        pure
        returns (int256)
    {
        if (reserveTarget == 0 || reserve >= reserveTarget) return deltaX64;
        return (deltaX64 * int256(reserve)) / int256(reserveTarget);
    }
}
