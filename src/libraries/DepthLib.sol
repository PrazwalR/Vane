// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Q64x64} from "./Q64x64.sol";

/// @title DepthLib
/// @notice Pool depth D = L * sqrt(P), the denominator of the AMM's price impact.
/// @dev From spec eq (2.1): for a concentrated-liquidity position, d(ln P)/dy = 2/D
///      where D = L*sqrt(P) is denominated in the numeraire token. Depth is the single
///      pool-state input to kappa, so its scaling has to be exactly right or the whole
///      correction is off by a constant factor.
///
///      Unit discipline, since this is where a silent factor error would hide:
///        - `liquidity` is v4's L, an unsigned 128-bit quantity in units of
///          sqrt(token0 * token1).
///        - `sqrtPriceX96` is sqrt(P) in Q64.96, where P = token1/token0.
///        - Their product L * sqrt(P) is therefore in units of token1, the numeraire.
///
///      The Q64.96 price and the Q64.64 output differ by 2^32, so the product is
///      shifted down by 96 and up by 64, a net right shift of 32.
library DepthLib {
    error DepthLib__ZeroPrice();

    /// @notice Computes D = L * sqrt(P) in Q64.64, denominated in the numeraire.
    /// @dev Returns zero for zero liquidity rather than reverting. A pool with no
    ///      liquidity in range has infinite price impact, and the caller's kappa
    ///      computation reads a zero depth as "no correction possible" via
    ///      KappaLib.lambdaAmmX64 returning the maximum. Reverting here would violate
    ///      invariant 1, because beforeSwap must survive an empty pool.
    /// @param liquidity Active liquidity L from the pool.
    /// @param sqrtPriceX96 Current sqrt price in Q64.96.
    /// @return depthX64 Depth in Q64.64 numeraire units.
    function depthX64(uint128 liquidity, uint160 sqrtPriceX96) internal pure returns (uint256) {
        if (liquidity == 0 || sqrtPriceX96 == 0) return 0;

        // L * sqrtP is at most 2^128 * 2^160 = 2^288, which overflows uint256. Shift the
        // price down first: sqrtPriceX96 >> 32 leaves Q64.64, bounding the product by
        // 2^128 * 2^128 = 2^256. That is still the exact boundary, so the shift is split
        // to keep the intermediate strictly inside the type.
        uint256 sqrtPriceX64 = uint256(sqrtPriceX96) >> 32;
        return uint256(liquidity) * sqrtPriceX64;
    }

    /// @notice The informationally correct depth D* = 4U/sigma, per eq (2.3).
    /// @dev The pool is under-reacting when D > D*, which is the deep-major-pair case
    ///      the thesis is about. Exposed so tests and the simulator can compare the
    ///      pool's actual depth against the target directly rather than inferring it
    ///      from the sign of kappa.
    /// @param noiseX64 Noise notional scale U in Q64.64.
    /// @param sigmaX64 Per-block fundamental log-volatility in Q64.64.
    function targetDepthX64(uint256 noiseX64, uint256 sigmaX64) internal pure returns (uint256) {
        if (sigmaX64 == 0) return type(uint256).max;
        return (4 * noiseX64 * Q64x64.ONE_X64_U) / sigmaX64;
    }

    /// @notice True when the pool under-reacts to order flow, i.e. D > D*.
    /// @dev Equivalent to kappa > 0, but stated in depth terms because that is the form
    ///      the thesis in section 2.4 argues about: LPs adding capital raises D, pushing
    ///      the pool further above D* and making price discovery worse.
    function isUnderReacting(uint256 poolDepthX64, uint256 noiseX64, uint256 sigmaX64) internal pure returns (bool) {
        return poolDepthX64 > targetDepthX64(noiseX64, sigmaX64);
    }
}
