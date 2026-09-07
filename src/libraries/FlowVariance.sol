// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Q64x64} from "./Q64x64.sol";

/// @title FlowVariance
/// @notice Order-flow variance E[y^2] and the noise-scale estimate U, per eq (3.2).
/// @dev In Kyle equilibrium informed and noise flow contribute exactly equally to
///      order-flow variance, so Var(y) = 2 * sigma_u^2 and U = sqrt(E[y^2] / 2).
///      That identity is what lets the pool estimate the unobservable noise scale
///      from flow it can actually see.
///
///      Flow is accumulated in scaled units rather than wei. A pool trading in wei
///      would square to 1e36 and overflow the packed state field; the caller divides
///      by a deploy-time flow unit first, so the accumulator holds a number of order
///      1e6 for an ether-scale trade.
library FlowVariance {
    error FlowVariance__ZeroFlowUnit();

    /// @notice Converts a signed wei notional into scaled flow units.
    /// @dev Truncates toward zero. Dust trades below one flow unit contribute nothing,
    ///      which is intended: they carry no information worth pricing.
    /// @param signedNotional Signed notional in token base units; positive buys the risky asset.
    /// @param flowUnit Wei per flow unit, a deploy parameter.
    function toFlowUnits(int256 signedNotional, uint256 flowUnit) internal pure returns (int256) {
        if (flowUnit == 0) revert FlowVariance__ZeroFlowUnit();
        return signedNotional / int256(flowUnit);
    }

    /// @notice Adds this swap's signed flow to the running per-block accumulator.
    /// @dev Saturates rather than reverting. An accumulator overflow means a single
    ///      block saw more one-sided flow than int64 can express, which is a variance
    ///      estimate that has already lost meaning; saturating keeps beforeSwap
    ///      revert-free (invariant 1) while the clamp bounds the damage.
    function accumulate(int64 accum, int256 flowUnits) internal pure returns (int64) {
        int256 next = int256(accum) + flowUnits;
        if (next > type(int64).max) return type(int64).max;
        if (next < type(int64).min) return type(int64).min;
        return int64(next);
    }

    /// @notice Folds one block's accumulated flow into the E[y^2] EWMA.
    /// @param flowVarX32 Current E[y^2] in squared flow units, Q32.32.
    /// @param blockAccum Signed flow accumulated over the block, in flow units.
    /// @param lambdaX32 EWMA decay in Q32.32.
    function updateFlowVar(uint64 flowVarX32, int64 blockAccum, uint64 lambdaX32) internal pure returns (uint64) {
        uint256 magnitude = Q64x64.abs(int256(blockAccum));
        uint256 sample = magnitude * magnitude;

        uint256 next = Q64x64.ewmaX32(uint256(flowVarX32), sample << 32, uint256(lambdaX32));

        // Saturate rather than revert, for the same reason as accumulate.
        return next > type(uint64).max ? type(uint64).max : uint64(next);
    }

    /// @notice Noise scale U = sqrt(E[y^2] / 2), per eq (3.2), in Q32.32 flow units.
    /// @dev Halving before the root is the whole content of Kyle's variance identity:
    ///      exactly half of observed flow variance is informed, so the noise scale is
    ///      the root of the other half.
    function noiseScaleX32(uint64 flowVarX32) internal pure returns (uint256) {
        if (flowVarX32 == 0) return 0;
        return Q64x64.sqrtX32(uint256(flowVarX32) / 2);
    }

    /// @notice Wash-trade resistance check, threat 3.
    /// @dev Inflating flow variance raises U, and kappa falls as U rises because
    ///      lambda* = sigma / (2U). So the attack shrinks the correction toward zero
    ///      rather than amplifying it. This helper exposes the monotone relationship
    ///      so a test can assert the direction rather than trusting the argument.
    function noiseScaleIsMonotone(uint64 lowerVarX32, uint64 higherVarX32) internal pure returns (bool) {
        return noiseScaleX32(higherVarX32) >= noiseScaleX32(lowerVarX32);
    }
}
