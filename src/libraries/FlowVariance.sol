// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Q64x64} from "./Q64x64.sol";

library FlowVariance {
    error FlowVariance__ZeroFlowUnit();

    function toFlowUnits(int256 signedNotional, uint256 flowUnit) internal pure returns (int256) {
        if (flowUnit == 0) revert FlowVariance__ZeroFlowUnit();
        return signedNotional / int256(flowUnit);
    }

    function accumulate(int64 accum, int256 flowUnits) internal pure returns (int64) {
        int256 next = int256(accum) + flowUnits;
        if (next > type(int64).max) return type(int64).max;
        if (next < type(int64).min) return type(int64).min;
        return int64(next);
    }

    function updateFlowVar(uint64 flowVar, int64 blockAccum, uint64 lambdaX32) internal pure returns (uint64) {
        uint256 magnitude = Q64x64.abs(int256(blockAccum));
        uint256 sample = magnitude * magnitude;

        uint256 next = Q64x64.ewmaX32(uint256(flowVar), sample, uint256(lambdaX32));

        return next > type(uint64).max ? type(uint64).max : uint64(next);
    }

    function noiseScale(uint64 flowVar) internal pure returns (uint256) {
        if (flowVar == 0) return 0;
        return Q64x64.sqrt(uint256(flowVar) / 2);
    }

    function noiseScaleX64(uint64 flowVar) internal pure returns (uint256) {
        return noiseScale(flowVar) * Q64x64.ONE_X64_U;
    }

    function noiseScaleIsMonotone(uint64 lowerVar, uint64 higherVar) internal pure returns (bool) {
        return noiseScale(higherVar) >= noiseScale(lowerVar);
    }
}
