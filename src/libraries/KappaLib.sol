// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

library KappaLib {
    uint256 internal constant ONE_X64 = 1 << 64;

    function lambdaAmmX64(uint256 depthX64) internal pure returns (uint256) {
        if (depthX64 == 0) return type(uint256).max;
        return (2 * ONE_X64 * ONE_X64) / depthX64;
    }

    function lambdaStarX64(uint256 sigmaX64, uint256 noiseX64) internal pure returns (uint256) {
        if (noiseX64 == 0) return 0;
        return (sigmaX64 * ONE_X64) / (2 * noiseX64);
    }

    function kappaX64(uint256 depthX64, uint256 sigmaX64, uint256 noiseX64, uint256 kappaMaxX64)
        internal
        pure
        returns (uint256)
    {
        uint256 lamStar = lambdaStarX64(sigmaX64, noiseX64);
        uint256 lamAmm = lambdaAmmX64(depthX64);
        if (lamStar <= lamAmm) return 0;
        uint256 k = lamStar - lamAmm;
        return k > kappaMaxX64 ? kappaMaxX64 : k;
    }
}
