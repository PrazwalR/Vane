// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "v4-core/libraries/FullMath.sol";

import {Q64x64} from "./Q64x64.sol";

library DepthLib {
    error DepthLib__ZeroPrice();

    function depthX64(uint128 liquidity, uint160 sqrtPriceX96, uint64 flowUnit) internal pure returns (uint256) {
        if (liquidity == 0 || sqrtPriceX96 == 0 || flowUnit == 0) return 0;

        uint256 sqrtPriceX64 = uint256(sqrtPriceX96) >> 32;
        return FullMath.mulDiv(uint256(liquidity), sqrtPriceX64, uint256(flowUnit));
    }

    function targetDepthX64(uint256 noiseX64, uint256 sigmaX64) internal pure returns (uint256) {
        if (sigmaX64 == 0) return type(uint256).max;
        return (4 * noiseX64 * Q64x64.ONE_X64_U) / sigmaX64;
    }

    function isUnderReacting(uint256 poolDepthX64, uint256 noiseX64, uint256 sigmaX64) internal pure returns (bool) {
        return poolDepthX64 > targetDepthX64(noiseX64, sigmaX64);
    }
}
