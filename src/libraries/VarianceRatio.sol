// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Q64x64} from "./Q64x64.sol";

struct ControllerParams {


    uint256 etaX32;

    uint256 rhoX32;

    uint256 deadbandX32;

    uint256 kappaMaxX64;
}

library VarianceRatio {
    uint256 internal constant ONE_X32 = 1 << 32;

    function step(
        uint256 kappaX64,
        uint256 kappaOpenLoopX64,
        uint256 kappaScaleX64,
        uint256 varianceRatioX32,
        ControllerParams memory p
    ) internal pure returns (uint256) {
        int256 errX32 = int256(varianceRatioX32) - int256(ONE_X32);

        uint256 absErr = errX32 < 0 ? uint256(-errX32) : uint256(errX32);
        if (absErr <= p.deadbandX32) {
            errX32 = 0;
        }

        int256 driveX64 = (int256(p.etaX32) * errX32 * int256(kappaScaleX64)) >> 64;

        int256 deviationX64 = int256(kappaX64) - int256(kappaOpenLoopX64);
        int256 leakX64 = (int256(p.rhoX32) * deviationX64) >> 32;

        int256 next = int256(kappaX64) + driveX64 - leakX64;

        if (next < 0) return 0;
        if (uint256(next) > p.kappaMaxX64) return p.kappaMaxX64;
        return uint256(next);
    }

    function noiseSigmaX32(uint256 lambdaX32) internal pure returns (uint256) {
        if (lambdaX32 >= ONE_X32) return 0;
        uint256 numerator = ONE_X32 - lambdaX32;
        uint256 denominator = ONE_X32 + lambdaX32;

        uint256 ratioX32 = (numerator << 32) / denominator;
        return 2 * Q64x64.sqrtX32(ratioX32);
    }

    function loopGainX32(uint256 etaX32, uint256 rhoX32) internal pure returns (uint256) {
        if (rhoX32 == 0) return type(uint256).max;
        return (etaX32 << 32) / rhoX32;
    }
}
