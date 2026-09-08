// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Q64x64} from "./Q64x64.sol";

/// @title HorizonVariance
/// @notice Per-block and k-block return variance, per spec sections 3.1 and 3.4.
/// @dev Both EWMAs SATURATE at the type bound rather than reverting. The horizon clamp
///      is maxTickDelta * horizon and the horizon is the blocks that actually elapsed, so
///      a pool that sits idle and then moves hard can produce an r_k above 65,535 ticks,
///      whose square shifted to Q32.32 exceeds a uint64. Reverting there would revert
///      afterSwap, and a pool whose afterSwap always reverts cannot be swapped at all.
///      A saturated variance is an estimate that has lost resolution at the top of its
///      range, which the kappa and delta clamps already bound; a bricked pool is
///      unrecoverable. Regression: test_VarK_SaturatesRatherThanRevertingOnExtremeReturn.
///
///      Ticks are log prices. A tick difference is a log return up to the constant
///      ln(1.0001), so every estimate here is integer arithmetic with no ln or exp
///      and no precision loss. Variance is carried in squared ticks at Q32.32 and
///      converted to log-price units only at the boundary, in sigmaX64.
///
///      The single most dangerous error this library exists to avoid is the
///      identification trap in section 3.1: short-horizon pool volatility understates
///      the fundamental volatility sigma, because the pool under-reacts. Using
///      varOne to derive sigma makes kappa too small and fails silently in the
///      direction of doing nothing. sigmaX64 therefore reads varK over the horizon,
///      never varOne.
library HorizonVariance {
    /// @notice Clamps a tick delta and returns its square, in raw squared ticks.
    /// @dev The clamp is what makes variance manipulation-bounded (invariant 8). An
    ///      attacker who moves the price violently in one block cannot inflate the
    ///      estimate beyond maxTickDelta^2.
    /// @param tickNow Current pool tick.
    /// @param tickPrev Tick at the previous sample.
    /// @param maxTickDelta Absolute clamp on the per-block tick move.
    function clampedSquare(int24 tickNow, int24 tickPrev, int24 maxTickDelta) internal pure returns (uint256 squared) {
        int256 delta = int256(tickNow) - int256(tickPrev);
        if (delta > int256(maxTickDelta)) delta = int256(maxTickDelta);
        if (delta < -int256(maxTickDelta)) delta = -int256(maxTickDelta);

        uint256 magnitude = Q64x64.abs(delta);
        squared = magnitude * magnitude;
    }

    /// @notice Folds one per-block observation into the r_1 variance EWMA.
    /// @param varOneX32 Current Var(r_1) in squared ticks, Q32.32.
    /// @param tickNow Current pool tick.
    /// @param tickPrev Tick at the previous block sample.
    /// @param maxTickDelta Absolute clamp on the per-block tick move.
    /// @param lambdaX32 EWMA decay in Q32.32.
    function updateVarOne(uint64 varOneX32, int24 tickNow, int24 tickPrev, int24 maxTickDelta, uint64 lambdaX32)
        internal
        pure
        returns (uint64)
    {
        uint256 sample = clampedSquare(tickNow, tickPrev, maxTickDelta);
        uint256 next = Q64x64.ewmaX32(uint256(varOneX32), sample << 32, uint256(lambdaX32));
        return next > type(uint64).max ? type(uint64).max : uint64(next);
    }

    /// @notice Folds one k-block observation into the r_k variance EWMA.
    /// @dev Called only when horizonK blocks have elapsed since the checkpoint, so the
    ///      cost amortises to near zero per swap. The k-block return is not clamped by
    ///      maxTickDelta directly; it is bounded by k times that clamp, which is the
    ///      correct scaling for a horizon return.
    /// @param varKX32 Current Var(r_k) in squared ticks, Q32.32.
    /// @param tickNow Current pool tick.
    /// @param checkpointTick Tick recorded at the last checkpoint.
    /// @param maxTickDelta Per-block clamp; the horizon clamp is this times horizonK.
    /// @param horizonK Number of blocks in the horizon.
    /// @param lambdaX32 EWMA decay in Q32.32.
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

    /// @notice Fundamental log-volatility sigma, per eq (3.3): sigma^2 = Var(r_k) / k.
    /// @dev Reads the horizon variance, never the per-block variance. Over k blocks
    ///      arbitrage drags the pool back toward the fundamental, so long-horizon pool
    ///      returns do capture sigma while short-horizon ones do not.
    /// @param varKX32 Var(r_k) in squared ticks, Q32.32.
    /// @param horizonK Number of blocks in the horizon.
    /// @return sigmaX64 Per-block fundamental log-volatility in Q64.64.
    function sigmaX64(uint64 varKX32, uint16 horizonK) internal pure returns (uint256) {
        if (horizonK == 0 || varKX32 == 0) return 0;

        // Per-block variance in squared ticks, Q32.32.
        uint256 perBlockVarX32 = uint256(varKX32) / uint256(horizonK);

        // Take the root in TICK space, then scale by ln(1.0001) once.
        //
        // The obvious order is the wrong one. Converting to log-price variance first
        // means multiplying by ln(1.0001)^2 = 1e-8 while still at Q32.32, whose smallest
        // representable value is 2.3e-10: any per-block volatility below about 1.5e-5
        // truncates the variance to zero, so sigma comes out zero, kappa comes out zero,
        // and the mechanism silently does nothing on precisely the low-volatility pools
        // it is aimed at. Rooting first keeps the quantity in a range Q32.32 can hold and
        // applies the small constant once, at full Q64.64 precision.
        //
        // sqrtX32 returns ticks in Q32.32; multiplying by the Q64.64 constant gives
        // Q96.96, and shifting down by 32 lands on Q64.64.
        uint256 sigmaTicksX32 = Q64x64.sqrtX32(perBlockVarX32);
        return (sigmaTicksX32 * uint256(Q64x64.TICK_LN_X64)) >> 32;
    }

    /// @notice Variance ratio VR(k) = Var(r_k) / (k * Var(r_1)), per eq (3.5), in Q32.32.
    /// @dev VR > 1 means returns trend, so the pool under-reacted. VR = 1 is a
    ///      martingale. VR < 1 means mean reversion, so the correction overshot.
    ///      Returns zero when varOne is zero, which the caller must read as "no
    ///      signal" rather than as mean reversion.
    function varianceRatioX32(uint64 varKX32, uint64 varOneX32, uint16 horizonK) internal pure returns (uint256) {
        if (varOneX32 == 0 || horizonK == 0) return 0;
        uint256 denominator = uint256(varOneX32) * uint256(horizonK);
        return (uint256(varKX32) << 32) / denominator;
    }
}
