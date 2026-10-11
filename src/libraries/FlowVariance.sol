// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Q64x64} from "./Q64x64.sol";

library FlowVariance {
    uint64 internal constant MIN_FLOW_UNIT = 1e9;

    uint64 internal constant MAX_FLOW_UNIT = 1e18;

    error FlowVariance__ZeroFlowUnit();

    function toFlowUnits(int256 signedNotional, uint256 flowUnit) internal pure returns (int256) {
        if (flowUnit == 0) revert FlowVariance__ZeroFlowUnit();
        return signedNotional / int256(flowUnit);
    }

    /// The clamp keeps the swap path alive, but a clamped accumulator is no longer a
    /// measurement of anything. The second return value says so, and the caller is
    /// expected to stop trusting the estimate rather than act on a saturated one.
    function accumulateChecked(int64 accum, int256 flowUnits) internal pure returns (int64 value, bool saturated) {
        int256 next = int256(accum) + flowUnits;
        if (next > type(int64).max) return (type(int64).max, true);
        if (next < type(int64).min) return (type(int64).min, true);
        return (int64(next), false);
    }

    function updateFlowVarChecked(uint64 flowVar, int64 blockAccum, uint64 lambdaX32)
        internal
        pure
        returns (uint64 value, bool saturated)
    {
        uint256 magnitude = Q64x64.abs(int256(blockAccum));
        uint256 sample = magnitude * magnitude;

        uint256 next = Q64x64.ewmaX32(uint256(flowVar), sample, uint256(lambdaX32));

        if (next >= type(uint64).max) return (type(uint64).max, true);
        return (uint64(next), false);
    }

    function isSaturated(uint64 flowVar) internal pure returns (bool) {
        return flowVar == type(uint64).max;
    }

    /// A flow unit sized to a currency's decimals, for an operator choosing one.
    ///
    /// `flowUnit` is wei per flow unit, so its correct magnitude depends entirely on the
    /// currency's decimals — and nothing in the contract knows them. At the shipped
    /// default of 1e12 a six-decimal quote token like USDC needs a swap of one million
    /// tokens before `toFlowUnits` returns anything but zero, which leaves the estimator
    /// permanently at zero and the gain permanently off.
    ///
    /// This returns one ten-thousandth of a whole token, clamped into the validated range:
    /// small enough that ordinary swaps register, large enough that the squared
    /// accumulator has room before it saturates. It is a starting point for calibration,
    /// not a substitute for it.
    function recommendedFlowUnit(uint8 currencyDecimals) internal pure returns (uint64) {
        if (currencyDecimals > 36) return MAX_FLOW_UNIT;

        uint256 unit = 10 ** uint256(currencyDecimals);
        unit = unit / 10_000;

        if (unit < MIN_FLOW_UNIT) return MIN_FLOW_UNIT;
        if (unit > MAX_FLOW_UNIT) return MAX_FLOW_UNIT;
        return uint64(unit);
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
