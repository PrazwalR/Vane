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
    /// @dev Carried in RAW squared flow units, not Q32.32. Squared flow is already a
    ///      large integer -- a 1 ether block at flowUnit = 1e12 is 1e12 squared units --
    ///      so spending 32 of a uint64's bits on a fraction leaves only 4.3e9 of range
    ///      and pins the estimator at its ceiling on the first realistic trade. Raw units
    ///      give 1.8e19 of range, which is 4,295 ether of block flow at that flowUnit.
    ///      The EWMA still weights with a Q32.32 lambda; the shift inside ewmaX32 divides
    ///      by the lambda scale, so the result stays in the input's units.
    /// @param flowVar Current E[y^2] in squared flow units.
    /// @param blockAccum Signed flow accumulated over the block, in flow units.
    /// @param lambdaX32 EWMA decay in Q32.32.
    function updateFlowVar(uint64 flowVar, int64 blockAccum, uint64 lambdaX32) internal pure returns (uint64) {
        uint256 magnitude = Q64x64.abs(int256(blockAccum));
        uint256 sample = magnitude * magnitude;

        uint256 next = Q64x64.ewmaX32(uint256(flowVar), sample, uint256(lambdaX32));

        // Saturate rather than revert, for the same reason as accumulate.
        return next > type(uint64).max ? type(uint64).max : uint64(next);
    }

    /// @notice Noise scale U = sqrt(E[y^2] / 2), per eq (3.2), in flow units.
    /// @dev Halving before the root is the whole content of Kyle's variance identity:
    ///      exactly half of observed flow variance is informed, so the noise scale is
    ///      the root of the other half.
    function noiseScale(uint64 flowVar) internal pure returns (uint256) {
        if (flowVar == 0) return 0;
        return Q64x64.sqrt(uint256(flowVar) / 2);
    }

    /// @notice Noise scale U on the Q64.64 scale, still in FLOW UNITS.
    /// @dev Deliberately not converted to wei. kappa compares sigma/(2U) against 2/D, so
    ///      U and D must share a denomination, and DepthLib converts depth into flow
    ///      units for the reason given there: in wei both lambda terms underflow Q64.64
    ///      and the open-loop kappa silently becomes zero. The belief update likewise
    ///      multiplies kappa by flow measured in these units, so all three agree.
    function noiseScaleX64(uint64 flowVar) internal pure returns (uint256) {
        return noiseScale(flowVar) * Q64x64.ONE_X64_U;
    }

    /// @notice Wash-trade resistance check, threat 3.
    /// @dev Inflating flow variance raises U, and kappa falls as U rises because
    ///      lambda* = sigma / (2U). So the attack shrinks the correction toward zero
    ///      rather than amplifying it. This helper exposes the monotone relationship
    ///      so a test can assert the direction rather than trusting the argument.
    function noiseScaleIsMonotone(uint64 lowerVar, uint64 higherVar) internal pure returns (bool) {
        return noiseScale(higherVar) >= noiseScale(lowerVar);
    }
}
