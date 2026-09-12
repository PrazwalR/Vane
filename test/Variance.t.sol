// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {Q64x64} from "../src/libraries/Q64x64.sol";
import {HorizonVariance} from "../src/libraries/HorizonVariance.sol";
import {FlowVariance} from "../src/libraries/FlowVariance.sol";
import {PoolStateLib, PoolState, PoolStateAux} from "../src/libraries/PoolStateLib.sol";
import {KappaLib} from "../src/libraries/KappaLib.sol";

contract VarianceTest is Test {
    uint64 internal constant LAMBDA_X32 = uint64((uint256(99) << 32) / 100);
    int24 internal constant MAX_TICK_DELTA = 2000;
    uint16 internal constant HORIZON_K = 20;

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

        assertEq(Q64x64.sqrt(2), 1);
        assertEq(Q64x64.sqrt(3), 1);
        assertEq(Q64x64.sqrt(4), 2);
        assertEq(Q64x64.sqrt(5), 2);
        assertEq(Q64x64.sqrt(1e18), 1e9);
        assertEq(Q64x64.sqrt(type(uint128).max), 18446744073709551615);
    }

    function testFuzz_Ewma_StaysWithinInputRange(uint64 oldV, uint64 sampleV, uint32 rawLambda) public pure {
        uint256 lambda = bound(uint256(rawLambda), 1, Q64x64.ONE_X32 - 1);
        uint256 result = Q64x64.ewmaX32(uint256(oldV), uint256(sampleV), lambda);

        uint256 lo = oldV < sampleV ? oldV : sampleV;
        uint256 hi = oldV < sampleV ? sampleV : oldV;

        assertGe(result + 1, lo, "EWMA must not fall below both inputs");
        assertLe(result, hi + 1, "EWMA must not rise above both inputs");
    }

    function test_Ewma_ConvergesToConstantInput() public pure {
        uint256 target = 5000 << 32;
        uint256 v = 0;
        for (uint256 i = 0; i < 3000; i++) {
            v = Q64x64.ewmaX32(v, target, LAMBDA_X32);
        }
        assertApproxEqRel(v, target, 0.01e18, "EWMA must converge to a constant input");
    }

    function testFuzz_ClampedSquare_IsBounded(int24 tickNow, int24 tickPrev) public pure {
        uint256 squared = HorizonVariance.clampedSquare(tickNow, tickPrev, MAX_TICK_DELTA);
        uint256 ceiling = uint256(uint24(MAX_TICK_DELTA)) * uint256(uint24(MAX_TICK_DELTA));
        assertLe(squared, ceiling, "clamped square must never exceed maxTickDelta^2");
    }

    function test_Exploit_ExtremeTickMoveIsClamped() public pure {
        uint256 honest = HorizonVariance.clampedSquare(2000, 0, MAX_TICK_DELTA);
        uint256 attack = HorizonVariance.clampedSquare(887272, 0, MAX_TICK_DELTA);
        assertEq(attack, honest, "an extreme move must be clamped to the honest ceiling");
    }

    function test_SigmaIdentificationTrap_HorizonExceedsPerBlock() public pure {
        int24 perBlockMove = 10;

        uint64 varOne = 0;
        for (uint256 i = 0; i < 2000; i++) {
            varOne = HorizonVariance.updateVarOne(varOne, perBlockMove, 0, MAX_TICK_DELTA, LAMBDA_X32);
        }

        int24 horizonMove = int24(int256(uint256(HORIZON_K)) * int256(perBlockMove));
        uint64 varK = 0;
        for (uint256 i = 0; i < 2000; i++) {
            varK = HorizonVariance.updateVarK(varK, horizonMove, 0, MAX_TICK_DELTA, HORIZON_K, LAMBDA_X32);
        }

        uint256 sigmaFromHorizon = HorizonVariance.sigmaX64(varK, HORIZON_K);

        uint256 sigmaFromPerBlock = HorizonVariance.sigmaX64(varOne, 1);

        console2.log("varOne (Q32.32)        ", varOne);
        console2.log("varK   (Q32.32)        ", varK);
        console2.log("sigma from horizon X64 ", sigmaFromHorizon);
        console2.log("sigma from per-block X64", sigmaFromPerBlock);

        assertGt(sigmaFromHorizon, sigmaFromPerBlock, "horizon sigma must exceed per-block sigma when trending");

        assertApproxEqRel(
            sigmaFromHorizon,
            sigmaFromPerBlock * Q64x64.sqrt(uint256(HORIZON_K) << 64) / (uint256(1) << 32),
            0.05e18,
            "horizon sigma must exceed per-block sigma by sqrt(k) under a pure trend"
        );
    }

    function test_VarianceRatio_IsOneForMartingale() public pure {
        uint64 varOne = uint64(uint256(100) << 32);
        uint64 varK = uint64(uint256(100) * HORIZON_K << 32);

        uint256 vr = HorizonVariance.varianceRatioX32(varK, varOne, HORIZON_K);
        assertApproxEqRel(vr, Q64x64.ONE_X32, 0.001e18, "martingale must give VR = 1");
    }

    function test_VarianceRatio_ExceedsOneWhenTrending() public pure {
        uint64 varOne = uint64(uint256(100) << 32);

        uint64 varK = uint64(uint256(100) * HORIZON_K * HORIZON_K << 32);

        uint256 vr = HorizonVariance.varianceRatioX32(varK, varOne, HORIZON_K);
        console2.log("VR trending (Q32.32)", vr);
        assertGt(vr, Q64x64.ONE_X32, "trending returns must give VR > 1");
    }

    function test_VarianceRatio_FallsBelowOneWhenMeanReverting() public pure {
        uint64 varOne = uint64(uint256(100) << 32);

        uint64 varK = uint64(uint256(100) * (HORIZON_K / 4) << 32);

        uint256 vr = HorizonVariance.varianceRatioX32(varK, varOne, HORIZON_K);
        console2.log("VR mean-reverting (Q32.32)", vr);
        assertLt(vr, Q64x64.ONE_X32, "mean reverting returns must give VR < 1");
    }

    function test_VarK_SaturatesRatherThanRevertingOnExtremeReturn() public pure {
        uint64 result = HorizonVariance.updateVarK(0, 40_000, -40_000, MAX_TICK_DELTA, 100, LAMBDA_X32);
        assertGt(result, 0, "an extreme move must still register");
    }

    function testFuzz_VarK_NeverReverts(int24 tickNow, int24 checkpointTick, uint16 horizon) public pure {
        uint16 h = uint16(bound(uint256(horizon), 1, type(uint16).max));
        uint64 result =
            HorizonVariance.updateVarK(type(uint64).max / 2, tickNow, checkpointTick, MAX_TICK_DELTA, h, LAMBDA_X32);
        assertLe(result, type(uint64).max, "varK must stay in range without reverting");
    }

    function testFuzz_Sigma_NeverRevertsOrOverflows(uint64 varK, uint16 k) public pure {
        uint16 horizon = uint16(bound(uint256(k), 1, 10000));
        uint256 sigma = HorizonVariance.sigmaX64(varK, horizon);
        assertLt(sigma, type(uint128).max, "sigma must stay far below the Q64.64 ceiling");
    }

    function test_NoiseScale_RecoversKyleIdentity() public pure {
        int64 flowPerBlock = 1000;

        uint64 flowVar = 0;
        for (uint256 i = 0; i < 3000; i++) {
            flowVar = FlowVariance.updateFlowVar(flowVar, flowPerBlock, LAMBDA_X32);
        }

        uint256 u = FlowVariance.noiseScale(flowVar);

        console2.log("flowVar, raw squared flow units", flowVar);
        console2.log("U, flow units", u);

        assertApproxEqRel(u, 707, 0.01e18, "U must equal flow over root two");
    }

    function test_FlowVar_DoesNotSaturateOnRealisticFlow() public pure {
        int64 oneEtherInUnits = 1e6;

        uint64 flowVar = 0;
        for (uint256 i = 0; i < 2000; i++) {
            flowVar = FlowVariance.updateFlowVar(flowVar, oneEtherInUnits, LAMBDA_X32);
        }

        assertLt(flowVar, type(uint64).max, "a 1 ether block must not saturate the estimator");

        uint256 u = FlowVariance.noiseScale(flowVar);
        console2.log("flowVar after 1 ether blocks:", flowVar);
        console2.log("U in flow units:", u);
        assertApproxEqRel(u, 707_106, 0.01e18, "U must equal flow over root two");
    }

    function test_FlowVar_HandlesLargeBlockFlow() public pure {
        int64 hundredEther = 1e8;
        uint64 flowVar = 0;
        for (uint256 i = 0; i < 3000; i++) {
            flowVar = FlowVariance.updateFlowVar(flowVar, hundredEther, LAMBDA_X32);
        }
        assertLt(flowVar, type(uint64).max, "100 ether of block flow must not saturate");
        assertApproxEqRel(FlowVariance.noiseScale(flowVar), 70_710_678, 0.01e18, "U scales linearly");
    }

    function test_Exploit_WashTradeLowersKappa() public pure {
        uint256 depth = uint256(Q64x64.ONE_X64_U) * 10_000_000;
        uint256 sigma = Q64x64.ONE_X64_U / 50;
        uint256 kappaMax = type(uint64).max;

        uint64 honestFlowVar = uint64(uint256(1_000_000) << 32);
        uint64 washedFlowVar = uint64(uint256(100_000_000) << 32);

        uint256 uHonest = Q64x64.x32ToX64(FlowVariance.noiseScale(honestFlowVar));
        uint256 uWashed = Q64x64.x32ToX64(FlowVariance.noiseScale(washedFlowVar));

        assertGt(uWashed, uHonest, "wash trading must raise the noise scale");

        uint256 kappaHonest = KappaLib.kappaX64(depth, sigma, uHonest, kappaMax);
        uint256 kappaWashed = KappaLib.kappaX64(depth, sigma, uWashed, kappaMax);

        console2.log("U honest  ", uHonest);
        console2.log("U washed  ", uWashed);
        console2.log("kappa honest", kappaHonest);
        console2.log("kappa washed", kappaWashed);

        assertLt(kappaWashed, kappaHonest, "wash trading must lower kappa, not raise it");
    }

    function testFuzz_NoiseScale_IsMonotone(uint64 a, uint64 b) public pure {
        uint64 lo = a < b ? a : b;
        uint64 hi = a < b ? b : a;
        assertTrue(FlowVariance.noiseScaleIsMonotone(lo, hi), "noise scale must be monotone in flow variance");
    }

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

    function test_Differential_SigmaMatchesReference() public pure {
        int24 perBlockMove = 10;

        uint64 varK = 0;
        int24 horizonMove = int24(int256(uint256(HORIZON_K)) * int256(perBlockMove));
        for (uint256 i = 0; i < 2000; i++) {
            varK = HorizonVariance.updateVarK(varK, horizonMove, 0, MAX_TICK_DELTA, HORIZON_K, LAMBDA_X32);
        }
        uint256 sigmaHorizon = HorizonVariance.sigmaX64(varK, HORIZON_K);

        uint256 referenceHorizon = 82_492_222_882_307_872;
        assertApproxEqRel(sigmaHorizon, referenceHorizon, 0.0001e18, "sigma must match the reference to 1e-4");

        uint64 varOne = 0;
        for (uint256 i = 0; i < 2000; i++) {
            varOne = HorizonVariance.updateVarOne(varOne, perBlockMove, 0, MAX_TICK_DELTA, LAMBDA_X32);
        }
        uint256 sigmaPerBlock = HorizonVariance.sigmaX64(varOne, 1);

        uint256 referencePerBlock = 18_445_821_797_990_404;
        assertApproxEqRel(sigmaPerBlock, referencePerBlock, 0.0001e18, "per-block sigma must match the reference");
    }

    function test_Differential_NoiseScaleMatchesReference() public pure {
        uint64 flowVar = 0;
        for (uint256 i = 0; i < 3000; i++) {
            flowVar = FlowVariance.updateFlowVar(flowVar, 1000, LAMBDA_X32);
        }
        uint256 u = FlowVariance.noiseScale(flowVar);

        assertApproxEqRel(u, 707, 0.002e18, "U must match the reference");
    }

    function test_Differential_VarianceRatioMatchesClosedForm() public pure {
        uint64 varOne = uint64(uint256(100) << 32);

        uint64 varKTrend = uint64(uint256(100) * HORIZON_K * HORIZON_K << 32);
        uint256 vrTrend = HorizonVariance.varianceRatioX32(varKTrend, varOne, HORIZON_K);
        assertApproxEqRel(vrTrend, uint256(HORIZON_K) * Q64x64.ONE_X32, 0.0001e18, "pure trend must give VR = k");

        uint64 varKRevert = uint64(uint256(100) * (HORIZON_K / 4) << 32);
        uint256 vrRevert = HorizonVariance.varianceRatioX32(varKRevert, varOne, HORIZON_K);
        assertApproxEqRel(vrRevert, Q64x64.ONE_X32 / 4, 0.0001e18, "quarter scaling must give VR = 0.25");
    }

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

    function test_PoolState_PreservesRealisticBelief() public pure {
        int64 deltaMax = int64(int256(Q64x64.ONE_X64) / 100);
        assertGt(deltaMax, int64(int256(type(int32).max)), "a realistic belief exceeds int32");

        PoolState memory s = PoolState(0, 0, 0, 0, deltaMax);
        PoolState memory decoded = PoolStateLib.unpackState(PoolStateLib.packState(s));
        assertEq(decoded.deltaX64, deltaMax, "delta_max must survive a round trip intact");

        PoolState memory negative = PoolState(0, 0, 0, 0, -deltaMax);
        PoolState memory decodedNeg = PoolStateLib.unpackState(PoolStateLib.packState(negative));
        assertEq(decodedNeg.deltaX64, -deltaMax, "a negative belief must survive intact");
    }
}
