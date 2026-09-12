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

    function updateVarOne(uint64 varOneX32, int24 tickNow, int24 tickPrev, int24 maxTickDelta, uint64 lambdaX32)
        internal
        pure
        returns (uint64)
    {
        uint256 sample = clampedSquare(tickNow, tickPrev, maxTickDelta);
        uint256 next = Q64x64.ewmaX32(uint256(varOneX32), sample << 32, uint256(lambdaX32));
        return next > type(uint64).max ? type(uint64).max : uint64(next);
    }

    function updateVarK(
        uint64 varKX32,
        int24 tickNow,
        int24 checkpointTick,
        int24 maxTickDelta,
        uint16 horizonK,
        uint64 lambdaX32
    ) internal pure returns (uint64) {
        int256 rK = int256(tickNow) - int256(checkpointTick);

        int256 horizonClamp = int256(maxTickDelta) * int256(uint256(horizonK));
        if (rK > horizonClamp) rK = horizonClamp;
        if (rK < -horizonClamp) rK = -horizonClamp;

        uint256 magnitude = Q64x64.abs(rK);
        uint256 sample = magnitude * magnitude;

        uint256 next = Q64x64.ewmaX32(uint256(varKX32), sample << 32, uint256(lambdaX32));
        return next > type(uint64).max ? type(uint64).max : uint64(next);
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
