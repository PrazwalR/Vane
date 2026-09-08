// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "v4-core/libraries/FullMath.sol";

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

    /// @notice Computes D = L * sqrt(P) in Q64.64, denominated in FLOW UNITS.
    /// @dev Denominating in flow units rather than in wei is what makes the whole
    ///      correction representable. lambda is a log price per unit of notional, so with
    ///      notional in wei a realistic pool gives lambda_amm = 2/5e21 = 4e-22, while
    ///      Q64.64 resolves only to 5.4e-20. Both lambda terms truncate to zero, kappa
    ///      comes out zero, and the entire Kyle-matching core of eq (2.5) silently
    ///      contributes nothing -- leaving the variance-ratio controller running against
    ///      a zero anchor and pinning itself near its cap.
    ///
    ///      In flow units the same pool gives D = 5e9, lambda_amm = 4e-10, and a kappa
    ///      of order 1e-9 that produces a belief of about 50 bps on a 5 ether block.
    ///      U is already accumulated in flow units, and the belief update multiplies
    ///      kappa by flow in those units, so this is the one place the conversion has to
    ///      happen for the three to agree.
    /// @dev Returns zero for zero liquidity rather than reverting. A pool with no
    ///      liquidity in range has infinite price impact, and the caller's kappa
    ///      computation reads a zero depth as "no correction possible" via
    ///      KappaLib.lambdaAmmX64 returning the maximum. Reverting here would violate
    ///      invariant 1, because beforeSwap must survive an empty pool.
    /// @param liquidity Active liquidity L from the pool.
    /// @param sqrtPriceX96 Current sqrt price in Q64.96.
    /// @param flowUnit Wei per flow unit, the scale flow and U are accumulated in.
    /// @return Depth in Q64.64, denominated in flow units.
    function depthX64(uint128 liquidity, uint160 sqrtPriceX96, uint64 flowUnit) internal pure returns (uint256) {
        if (liquidity == 0 || sqrtPriceX96 == 0 || flowUnit == 0) return 0;

        // sqrtPriceX96 >> 32 puts the price on the Q64.64 scale. The product with
        // liquidity reaches 2^128 * 2^128 at the extremes of the tick range, exactly the
        // uint256 boundary, so the division by flowUnit is folded into a 512-bit mulDiv
        // rather than applied afterwards. Dividing liquidity first instead would
        // truncate small positions to nothing.
        uint256 sqrtPriceX64 = uint256(sqrtPriceX96) >> 32;
        return FullMath.mulDiv(uint256(liquidity), sqrtPriceX64, uint256(flowUnit));
    }

    /// @notice The informationally correct depth D* = 4U/sigma, per eq (2.3).
    /// @dev The pool is under-reacting when D > D*, which is the deep-major-pair case
    ///      the thesis is about. Exposed so tests and the simulator can compare the
    ///      pool's actual depth against the target directly rather than inferring it
    ///      from the sign of kappa.
    /// @param noiseX64 Noise notional scale U in Q64.64 flow units.
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
