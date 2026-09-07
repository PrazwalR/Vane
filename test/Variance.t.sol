// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {Q64x64} from "../src/libraries/Q64x64.sol";
import {HorizonVariance} from "../src/libraries/HorizonVariance.sol";
import {FlowVariance} from "../src/libraries/FlowVariance.sol";
import {PoolStateLib, PoolState, PoolStateAux} from "../src/libraries/PoolStateLib.sol";
import {KappaLib} from "../src/libraries/KappaLib.sol";

/// @notice M1 coverage: fixed point, the two variance estimators, and state packing.
///         The tests that matter most here are the sigma identification trap from
///         section 3.1 and the manipulation bound from invariant 8.
contract VarianceTest is Test {
    uint64 internal constant LAMBDA_X32 = uint64((uint256(99) << 32) / 100); // 0.99
    int24 internal constant MAX_TICK_DELTA = 2000; // ~22% per block
    uint16 internal constant HORIZON_K = 20;

    // ------------------------------------------------------------------
    // Q64x64
    // ------------------------------------------------------------------

    function testFuzz_Sqrt_MatchesSquare(uint128 raw) public pure {
        uint256 x = bound(uint256(raw), 0, type(uint128).max);
        uint256 root = Q64x64.sqrt(x);

        assertLe(root * root, x, "root squared must not exceed the input");
        if (root < type(uint128).max) {
            assertGt((root + 1) * (root + 1), x, "root must be the floor");
        }
    }

    function test_Sqrt_KnownValues() public pure {
        assertEq(Q64x64.sqrt(0), 0);
        assertEq(Q64x64.sqrt(1), 1);
        // The 2 and 3 cases are the regression for the Babylonian seed defect: the
        // loop cannot run for x <= 3, so these must be special-cased.
        assertEq(Q64x64.sqrt(2), 1);
        assertEq(Q64x64.sqrt(3), 1);
        assertEq(Q64x64.sqrt(4), 2);
        assertEq(Q64x64.sqrt(5), 2);
        assertEq(Q64x64.sqrt(1e18), 1e9);
        assertEq(Q64x64.sqrt(type(uint128).max), 18446744073709551615);
    }

    /// @notice The EWMA must be a convex combination, so it can never leave the range
    ///         spanned by its own inputs.
    function testFuzz_Ewma_StaysWithinInputRange(uint64 oldV, uint64 sampleV, uint32 rawLambda) public pure {
        uint256 lambda = bound(uint256(rawLambda), 1, Q64x64.ONE_X32 - 1);
        uint256 result = Q64x64.ewmaX32(uint256(oldV), uint256(sampleV), lambda);

        uint256 lo = oldV < sampleV ? oldV : sampleV;
        uint256 hi = oldV < sampleV ? sampleV : oldV;

        // Allow one unit of truncation slack on each side.
        assertGe(result + 1, lo, "EWMA must not fall below both inputs");
        assertLe(result, hi + 1, "EWMA must not rise above both inputs");
    }

    /// @notice A repeated identical sample must converge to that sample.
    function test_Ewma_ConvergesToConstantInput() public pure {
        uint256 target = 5000 << 32;
        uint256 v = 0;
        for (uint256 i = 0; i < 3000; i++) {
            v = Q64x64.ewmaX32(v, target, LAMBDA_X32);
        }
        assertApproxEqRel(v, target, 0.01e18, "EWMA must converge to a constant input");
    }

    // ------------------------------------------------------------------
    // HorizonVariance
    // ------------------------------------------------------------------

    /// @notice Invariant 8: intra-block price movement cannot inflate variance beyond
    ///         the clamp. This is what makes the estimator manipulation-bounded.
    function testFuzz_ClampedSquare_IsBounded(int24 tickNow, int24 tickPrev) public pure {
        uint256 squared = HorizonVariance.clampedSquare(tickNow, tickPrev, MAX_TICK_DELTA);
        uint256 ceiling = uint256(uint24(MAX_TICK_DELTA)) * uint256(uint24(MAX_TICK_DELTA));
        assertLe(squared, ceiling, "clamped square must never exceed maxTickDelta^2");
    }

    /// @notice An attacker moving the tick to an extreme gains nothing beyond the clamp.
    function test_Exploit_ExtremeTickMoveIsClamped() public pure {
        uint256 honest = HorizonVariance.clampedSquare(2000, 0, MAX_TICK_DELTA);
        uint256 attack = HorizonVariance.clampedSquare(887272, 0, MAX_TICK_DELTA);
        assertEq(attack, honest, "an extreme move must be clamped to the honest ceiling");
    }

    /// @notice The identification trap, section 3.1. A pool that under-reacts shows a
    ///         small per-block variance but a large horizon variance, because arbitrage
    ///         drags it back to the fundamental over k blocks. Deriving sigma from
    ///         varOne would understate it and silently shrink kappa toward zero.
    ///
    ///         Construct exactly that: a trending price whose per-block moves are small
    ///         and whose k-block move is the sum of them. sigma from the horizon must
    ///         come out strictly larger than sigma from the per-block series.
    function test_SigmaIdentificationTrap_HorizonExceedsPerBlock() public pure {
        int24 perBlockMove = 10;

        // Per-block variance of a constant 10-tick drift.
        uint64 varOne = 0;
        for (uint256 i = 0; i < 2000; i++) {
            varOne = HorizonVariance.updateVarOne(varOne, perBlockMove, 0, MAX_TICK_DELTA, LAMBDA_X32);
        }

        // Horizon variance of the same series: the k-block return is k * perBlockMove.
        int24 horizonMove = int24(int256(uint256(HORIZON_K)) * int256(perBlockMove));
        uint64 varK = 0;
        for (uint256 i = 0; i < 2000; i++) {
            varK = HorizonVariance.updateVarK(varK, horizonMove, 0, MAX_TICK_DELTA, HORIZON_K, LAMBDA_X32);
        }

        uint256 sigmaFromHorizon = HorizonVariance.sigmaX64(varK, HORIZON_K);

        // What a naive implementation would compute: treat varOne as a one-block horizon.
        uint256 sigmaFromPerBlock = HorizonVariance.sigmaX64(varOne, 1);

        console2.log("varOne (Q32.32)        ", varOne);
        console2.log("varK   (Q32.32)        ", varK);
        console2.log("sigma from horizon X64 ", sigmaFromHorizon);
        console2.log("sigma from per-block X64", sigmaFromPerBlock);

        // A trending pool leaks information over the horizon, so the horizon estimate is
        // strictly larger. Using the per-block figure is the silent failure.
        assertGt(sigmaFromHorizon, sigmaFromPerBlock, "horizon sigma must exceed per-block sigma when trending");

        // Under a pure trend the horizon return is k times the per-block return, so its
        // variance is k^2 times larger; dividing by k leaves a factor of k, and sigma
        // carries the square root of that.
        assertApproxEqRel(
            sigmaFromHorizon,
            sigmaFromPerBlock * Q64x64.sqrt(uint256(HORIZON_K) << 64) / (uint256(1) << 32),
            0.05e18,
            "horizon sigma must exceed per-block sigma by sqrt(k) under a pure trend"
        );
    }

    /// @notice Under a martingale the variance ratio must sit at 1, so the controller
    ///         sees no error and leaves kappa alone. Eq (3.5).
    function test_VarianceRatio_IsOneForMartingale() public pure {
        // A martingale scales variance linearly: Var(r_k) = k * Var(r_1).
        uint64 varOne = uint64(uint256(100) << 32);
        uint64 varK = uint64(uint256(100) * HORIZON_K << 32);

        uint256 vr = HorizonVariance.varianceRatioX32(varK, varOne, HORIZON_K);
        assertApproxEqRel(vr, Q64x64.ONE_X32, 0.001e18, "martingale must give VR = 1");
    }

    /// @notice A trending series must give VR > 1, the under-reaction signal.
    function test_VarianceRatio_ExceedsOneWhenTrending() public pure {
        uint64 varOne = uint64(uint256(100) << 32);
        // Trending: the horizon return is k times the per-block, so variance is k^2.
        uint64 varK = uint64(uint256(100) * HORIZON_K * HORIZON_K << 32);

        uint256 vr = HorizonVariance.varianceRatioX32(varK, varOne, HORIZON_K);
        console2.log("VR trending (Q32.32)", vr);
        assertGt(vr, Q64x64.ONE_X32, "trending returns must give VR > 1");
    }

    /// @notice A mean-reverting series must give VR < 1, the over-correction signal.
    function test_VarianceRatio_FallsBelowOneWhenMeanReverting() public pure {
        uint64 varOne = uint64(uint256(100) << 32);
        // Mean reverting: the horizon return is smaller than linear scaling implies.
        uint64 varK = uint64(uint256(100) * (HORIZON_K / 4) << 32);

        uint256 vr = HorizonVariance.varianceRatioX32(varK, varOne, HORIZON_K);
        console2.log("VR mean-reverting (Q32.32)", vr);
        assertLt(vr, Q64x64.ONE_X32, "mean reverting returns must give VR < 1");
    }

    /// @notice sigma must never revert and never overflow across the whole legal domain.
    function testFuzz_Sigma_NeverRevertsOrOverflows(uint64 varK, uint16 k) public pure {
        uint16 horizon = uint16(bound(uint256(k), 1, 10000));
        uint256 sigma = HorizonVariance.sigmaX64(varK, horizon);
        assertLt(sigma, type(uint128).max, "sigma must stay far below the Q64.64 ceiling");
    }

    // ------------------------------------------------------------------
    // FlowVariance
    // ------------------------------------------------------------------

    /// @notice Eq (3.2): U = sqrt(E[y^2] / 2). Feeding a known constant flow must
    ///         recover a noise scale of that flow over root two.
    function test_NoiseScale_RecoversKyleIdentity() public pure {
        int64 flowPerBlock = 1000;

        uint64 flowVar = 0;
        for (uint256 i = 0; i < 3000; i++) {
            flowVar = FlowVariance.updateFlowVar(flowVar, flowPerBlock, LAMBDA_X32);
        }

        uint256 uX32 = FlowVariance.noiseScaleX32(flowVar);
        uint256 expected = (uint256(1000) * Q64x64.ONE_X32) / Q64x64.sqrt(2 << 64) * (uint256(1) << 32);

        console2.log("flowVar Q32.32", flowVar);
        console2.log("U       Q32.32", uX32);

        // U = 1000 / sqrt(2) = 707.1
        assertApproxEqRel(uX32, uint256(707) << 32, 0.01e18, "U must equal flow over root two");
        expected; // silence unused warning without weakening the assertion above
    }

    /// @notice Threat 3, wash trading. Inflating flow variance raises U, and kappa falls
    ///         as U rises, so the attack shrinks the correction rather than amplifying it.
    ///         The spec asserts this is self-defeating; this proves the direction.
    function test_Exploit_WashTradeLowersKappa() public pure {
        // The pool must be deeper than D* = 4U/sigma in BOTH arms, otherwise kappa
        // clamps to zero on each side and the comparison is vacuous. With U of 707 and
        // 7071 flow units, D* is 141k and 1.41m respectively, so 10m clears both.
        uint256 depth = uint256(Q64x64.ONE_X64_U) * 10_000_000;
        uint256 sigma = Q64x64.ONE_X64_U / 50;
        uint256 kappaMax = type(uint64).max;

        uint64 honestFlowVar = uint64(uint256(1_000_000) << 32);
        uint64 washedFlowVar = uint64(uint256(100_000_000) << 32); // attacker inflates E[y^2]

        uint256 uHonest = Q64x64.x32ToX64(FlowVariance.noiseScaleX32(honestFlowVar));
        uint256 uWashed = Q64x64.x32ToX64(FlowVariance.noiseScaleX32(washedFlowVar));

        assertGt(uWashed, uHonest, "wash trading must raise the noise scale");

        uint256 kappaHonest = KappaLib.kappaX64(depth, sigma, uHonest, kappaMax);
        uint256 kappaWashed = KappaLib.kappaX64(depth, sigma, uWashed, kappaMax);

        console2.log("U honest  ", uHonest);
        console2.log("U washed  ", uWashed);
        console2.log("kappa honest", kappaHonest);
        console2.log("kappa washed", kappaWashed);

        assertLt(kappaWashed, kappaHonest, "wash trading must lower kappa, not raise it");
    }

    /// @notice The noise scale must be monotone in flow variance, which is what makes
    ///         the wash-trade direction argument hold generally rather than at a point.
    function testFuzz_NoiseScale_IsMonotone(uint64 a, uint64 b) public pure {
        uint64 lo = a < b ? a : b;
        uint64 hi = a < b ? b : a;
        assertTrue(FlowVariance.noiseScaleIsMonotone(lo, hi), "noise scale must be monotone in flow variance");
    }

    /// @notice The accumulator must saturate rather than revert, so a single block of
    ///         extreme flow cannot brick beforeSwap (invariant 1).
    function testFuzz_Accumulate_SaturatesWithoutReverting(int64 start, int256 add) public pure {
        int256 addition = bound(add, type(int128).min, type(int128).max);
        int64 result = FlowVariance.accumulate(start, addition);
        assertTrue(result >= type(int64).min && result <= type(int64).max, "accumulator must stay in range");
    }

    function test_Accumulate_SaturatesAtMax() public pure {
        int64 result = FlowVariance.accumulate(type(int64).max, 1000);
        assertEq(result, type(int64).max, "must saturate rather than wrap");
    }

    function testFuzz_ToFlowUnits_Truncates(int128 notional, uint64 rawUnit) public pure {
        uint256 unit = bound(uint256(rawUnit), 1, 1e18);
        int256 units = FlowVariance.toFlowUnits(int256(notional), unit);
        assertLe(Q64x64.abs(units), Q64x64.abs(int256(notional)) / unit + 1, "scaling must not amplify");
    }

    // ------------------------------------------------------------------
    // Differential tests against a high-precision reference
    // ------------------------------------------------------------------

    /// @notice Section 0.5 requires the fixed-point math be checked against a
    ///         high-precision reference rather than against itself. These constants come
    ///         from an independent 60-digit decimal computation of the same quantities:
    ///
    ///           sigma_horizon  = sqrt(40000/20) * ln(1.0001) = 4.471912363108e-3
    ///           sigma_perblock = sqrt(100/1)    * ln(1.0001) = 9.999500033331e-4
    ///           U              = 1000 / sqrt(2)             = 707.106781
    ///
    ///         Tolerances are set by the EWMA's residual convergence error and Q32.32
    ///         truncation, not chosen to make the test pass.
    function test_Differential_SigmaMatchesReference() public pure {
        int24 perBlockMove = 10;

        uint64 varK = 0;
        int24 horizonMove = int24(int256(uint256(HORIZON_K)) * int256(perBlockMove));
        for (uint256 i = 0; i < 2000; i++) {
            varK = HorizonVariance.updateVarK(varK, horizonMove, 0, MAX_TICK_DELTA, HORIZON_K, LAMBDA_X32);
        }
        uint256 sigmaHorizon = HorizonVariance.sigmaX64(varK, HORIZON_K);

        // 4.471912363108e-3 in Q64.64.
        uint256 referenceHorizon = 82_492_222_882_307_872;
        assertApproxEqRel(sigmaHorizon, referenceHorizon, 0.0001e18, "sigma must match the reference to 1e-4");

        uint64 varOne = 0;
        for (uint256 i = 0; i < 2000; i++) {
            varOne = HorizonVariance.updateVarOne(varOne, perBlockMove, 0, MAX_TICK_DELTA, LAMBDA_X32);
        }
        uint256 sigmaPerBlock = HorizonVariance.sigmaX64(varOne, 1);

        // 9.999500033331e-4 in Q64.64.
        uint256 referencePerBlock = 18_445_821_797_990_404;
        assertApproxEqRel(sigmaPerBlock, referencePerBlock, 0.0001e18, "per-block sigma must match the reference");
    }

    /// @notice U = sqrt(E[y^2]/2) against the same independent reference. The Kyle
    ///         identity is the one estimate with no smoothing error once converged, so
    ///         the tolerance here is tight.
    function test_Differential_NoiseScaleMatchesReference() public pure {
        uint64 flowVar = 0;
        for (uint256 i = 0; i < 3000; i++) {
            flowVar = FlowVariance.updateFlowVar(flowVar, 1000, LAMBDA_X32);
        }
        uint256 uX32 = FlowVariance.noiseScaleX32(flowVar);

        // 707.106781 in Q32.32.
        uint256 referenceU = 3_037_000_499_976;
        assertApproxEqRel(uX32, referenceU, 0.000001e18, "U must match the reference to 1e-6");
    }

    /// @notice A pure trend has VR = k exactly, and a series whose horizon variance is a
    ///         quarter of linear scaling has VR = 0.25 exactly. Both are checked against
    ///         the closed form rather than a recomputation of the same code path.
    function test_Differential_VarianceRatioMatchesClosedForm() public pure {
        uint64 varOne = uint64(uint256(100) << 32);

        uint64 varKTrend = uint64(uint256(100) * HORIZON_K * HORIZON_K << 32);
        uint256 vrTrend = HorizonVariance.varianceRatioX32(varKTrend, varOne, HORIZON_K);
        assertApproxEqRel(vrTrend, uint256(HORIZON_K) * Q64x64.ONE_X32, 0.0001e18, "pure trend must give VR = k");

        uint64 varKRevert = uint64(uint256(100) * (HORIZON_K / 4) << 32);
        uint256 vrRevert = HorizonVariance.varianceRatioX32(varKRevert, varOne, HORIZON_K);
        assertApproxEqRel(vrRevert, Q64x64.ONE_X32 / 4, 0.0001e18, "quarter scaling must give VR = 0.25");
    }

    // ------------------------------------------------------------------
    // PoolStateLib
    // ------------------------------------------------------------------

    /// @notice Round trip over the full field domain, including negative ticks and
    ///         negative beliefs, which is where a hand-rolled packing usually breaks.
    function testFuzz_PoolState_RoundTrips(
        int24 lastTick,
        uint32 lastBlock,
        uint64 varOneX32,
        uint64 flowVarX32,
        int64 deltaX64
    ) public pure {
        PoolState memory original = PoolState(lastTick, lastBlock, varOneX32, flowVarX32, deltaX64);
        PoolState memory decoded = PoolStateLib.unpackState(PoolStateLib.packState(original));

        assertEq(decoded.lastTick, lastTick, "lastTick must survive");
        assertEq(decoded.lastBlock, lastBlock, "lastBlock must survive");
        assertEq(decoded.varOneX32, varOneX32, "varOne must survive");
        assertEq(decoded.flowVarX32, flowVarX32, "flowVar must survive");
        assertEq(decoded.deltaX64, deltaX64, "delta must survive, including the sign");
    }

    function testFuzz_PoolStateAux_RoundTrips(
        int24 checkpointTick,
        uint32 checkpointBlock,
        uint64 varKX32,
        uint64 kappaX64,
        int64 flowAccum
    ) public pure {
        PoolStateAux memory original = PoolStateAux(checkpointTick, checkpointBlock, varKX32, kappaX64, flowAccum);
        PoolStateAux memory decoded = PoolStateLib.unpackAux(PoolStateLib.packAux(original));

        assertEq(decoded.checkpointTick, checkpointTick, "checkpointTick must survive");
        assertEq(decoded.checkpointBlock, checkpointBlock, "checkpointBlock must survive");
        assertEq(decoded.varKX32, varKX32, "varK must survive");
        assertEq(decoded.kappaX64, kappaX64, "kappa must survive");
        assertEq(decoded.flowAccum, flowAccum, "flowAccum must survive, including the sign");
    }

    /// @notice The reserved bits must stay zero, so a future field can claim them
    ///         without a migration.
    function testFuzz_ReservedBitsStayZero(
        int24 lastTick,
        uint32 lastBlock,
        uint64 varOneX32,
        uint64 flowVarX32,
        int64 deltaX64
    ) public pure {
        PoolState memory s = PoolState(lastTick, lastBlock, varOneX32, flowVarX32, deltaX64);
        bytes32 packed = PoolStateLib.packState(s);
        assertEq(uint256(packed) >> 248, 0, "top 8 bits must remain reserved and zero");
    }

    /// @notice The belief must survive packing at the magnitude the mechanism actually
    ///         uses. This is the case the draft layout's int32 field would have lost.
    function test_PoolState_PreservesRealisticBelief() public pure {
        int64 deltaMax = int64(int256(Q64x64.ONE_X64) / 100); // 0.01 in Q64.64
        assertGt(deltaMax, int64(int256(type(int32).max)), "a realistic belief exceeds int32");

        PoolState memory s = PoolState(0, 0, 0, 0, deltaMax);
        PoolState memory decoded = PoolStateLib.unpackState(PoolStateLib.packState(s));
        assertEq(decoded.deltaX64, deltaMax, "delta_max must survive a round trip intact");

        PoolState memory negative = PoolState(0, 0, 0, 0, -deltaMax);
        PoolState memory decodedNeg = PoolStateLib.unpackState(PoolStateLib.packState(negative));
        assertEq(decodedNeg.deltaX64, -deltaMax, "a negative belief must survive intact");
    }
}
