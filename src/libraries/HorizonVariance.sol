// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Q64x64} from "./Q64x64.sol";

library HorizonVariance {
    function clampedSquare(int24 tickNow, int24 tickPrev, int24 maxTickDelta) internal pure returns (uint256 squared) {
        int256 delta = int256(tickNow) - int256(tickPrev);
        if (delta > int256(maxTickDelta)) delta = int256(maxTickDelta);
        if (delta < -int256(maxTickDelta)) delta = -int256(maxTickDelta);

        uint256 magnitude = Q64x64.abs(delta);
        squared = magnitude * magnitude;
    }

    /// A clamped variance is not a small variance, it is an unknown one, and the two feed
    /// `sigmaX64` identically — a pinned varK inflates sigma by about 4,300x, which pins
    /// the gain at its cap. So saturation is reported rather than swallowed, the same way
    /// FlowVariance reports it, and the caller is expected to stop trusting the estimate.
    function updateVarOne(uint64 varOneX32, int24 tickNow, int24 tickPrev, int24 maxTickDelta, uint64 lambdaX32)
        internal
        pure
        returns (uint64 value, bool saturated)
    {
        uint256 sample = clampedSquare(tickNow, tickPrev, maxTickDelta);
        uint256 next = Q64x64.ewmaX32(uint256(varOneX32), sample << 32, uint256(lambdaX32));
        if (next >= type(uint64).max) return (type(uint64).max, true);
        return (uint64(next), false);
    }

    function updateVarK(
        uint64 varKX32,
        int24 tickNow,
        int24 checkpointTick,
        int24 maxTickDelta,
        uint16 horizonK,
        uint64 lambdaX32
    ) internal pure returns (uint64 value, bool saturated) {
        int256 rK = int256(tickNow) - int256(checkpointTick);

        // The clamp scales with the elapsed horizon, so it grows without bound while the
        // accumulator's ceiling does not. With the shipped parameters a gap of 328 blocks
        // is enough for a single step to saturate varK from zero.
        int256 horizonClamp = int256(maxTickDelta) * int256(uint256(horizonK));
        if (rK > horizonClamp) rK = horizonClamp;
        if (rK < -horizonClamp) rK = -horizonClamp;

        uint256 magnitude = Q64x64.abs(rK);
        uint256 sample = magnitude * magnitude;

        uint256 next = Q64x64.ewmaX32(uint256(varKX32), sample << 32, uint256(lambdaX32));
        if (next >= type(uint64).max) return (type(uint64).max, true);
        return (uint64(next), false);
    }

    function isSaturated(uint64 varX32) internal pure returns (bool) {
        return varX32 == type(uint64).max;
    }

    function sigmaX64(uint64 varKX32, uint16 horizonK) internal pure returns (uint256) {
        if (horizonK == 0 || varKX32 == 0) return 0;

        uint256 perBlockVarX32 = uint256(varKX32) / uint256(horizonK);

        uint256 sigmaTicksX32 = Q64x64.sqrtX32(perBlockVarX32);
        return (sigmaTicksX32 * uint256(Q64x64.TICK_LN_X64)) >> 32;
    }

    function varianceRatioX32(uint64 varKX32, uint64 varOneX32, uint16 horizonK) internal pure returns (uint256) {
        if (varOneX32 == 0 || horizonK == 0) return 0;
        uint256 denominator = uint256(varOneX32) * uint256(horizonK);
        return (uint256(varKX32) << 32) / denominator;
    }
}
