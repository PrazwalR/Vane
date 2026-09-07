// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title KappaLib
/// @notice Open-loop impact gain kappa = lambda* - lambda_amm, per spec eq (2.5).
library KappaLib {
    uint256 internal constant ONE_X64 = 1 << 64;

    /// @notice lambda_amm = 2 / D, the pool's mechanical log-price impact, eq (2.1).
    /// @param depthX64 Depth D = L * sqrt(P) in Q64.64, denominated in the numeraire.
    function lambdaAmmX64(uint256 depthX64) internal pure returns (uint256) {
        if (depthX64 == 0) return type(uint256).max;
        return (2 * ONE_X64 * ONE_X64) / depthX64;
    }

    /// @notice lambda* = sigma / (2U), the informationally efficient impact, eq (2.2).
    /// @param sigmaX64 Per-block fundamental log-volatility in Q64.64.
    /// @param noiseX64 Per-block noise notional stdev U in Q64.64.
    function lambdaStarX64(uint256 sigmaX64, uint256 noiseX64) internal pure returns (uint256) {
        if (noiseX64 == 0) return 0;
        return (sigmaX64 * ONE_X64) / (2 * noiseX64);
    }

    /// @notice kappa = lambda* - lambda_amm, clamped to [0, kappaMax], eq (2.5).
    /// @dev Clamped at zero: a negative kappa would mean the curve already over-reacts,
    ///      in which case the correct action is to do nothing rather than to invert the
    ///      belief. An inverted belief subsidises flow trading against it (see the
    ///      sign-flip failure mode documented in docs/).
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
