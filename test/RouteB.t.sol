// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {FlowAutocovariance, FlowCovState} from "../src/libraries/FlowAutocovariance.sol";
import {FlowVariance} from "../src/libraries/FlowVariance.sol";
import {Q64x64} from "../src/libraries/Q64x64.sol";

contract RouteBTest is Test {
    uint64 internal constant LAMBDA = uint64((uint256(999) << 32) / 1000);
    uint256 internal constant ONE_X32 = 1 << 32;

    uint256 internal constant Z = 3;

    function _flowSeries(uint256 n, int256 rhoPct, int256 noiseScale, uint256 seed)
        internal
        pure
        returns (int64[] memory y)
    {
        y = new int64[](n);
        int256 x;
        for (uint256 i = 0; i < n; i++) {
            uint256 h = uint256(keccak256(abi.encode(seed, i)));
            int256 innov = int256(h % 2001) - 1000;
            int256 noise = int256((h >> 128) % (2 * uint256(noiseScale) + 1)) - noiseScale;
            x = (x * rhoPct) / 100 + innov;
            y[i] = int64(x + noise);
        }
    }

    function _run(int64[] memory series) internal pure returns (FlowCovState memory st, uint64 flowVar) {
        for (uint256 i = 0; i < series.length; i++) {
            st = FlowAutocovariance.update(st, series[i], LAMBDA);
            flowVar = FlowVariance.updateFlowVar(flowVar, series[i], LAMBDA);
        }
    }

    function test_RouteB_RecoversRhoWithoutAFreeParameter() public pure {
        int256[2] memory rhos = [int256(60), 75];
        for (uint256 j = 0; j < rhos.length; j++) {
            (FlowCovState memory st,) = _run(_flowSeries(8000, rhos[j], 600, 11 + j));
            uint256 rho = FlowAutocovariance.rhoX32(st);
            uint256 rhoPct = (rho * 100) >> 32;

            console2.log("true rho (pct)", uint256(rhos[j]));
            console2.log("est  rho (pct)", rhoPct);

            assertApproxEqAbs(rhoPct, uint256(rhos[j]), 15, "rho must be recovered from lags 1 and 2");
        }
    }

    function test_RouteB_RecoversNoiseScale() public pure {
        (FlowCovState memory st, uint64 flowVar) = _flowSeriesAndRun(50, 800, 21);

        uint256 uB = FlowAutocovariance.noiseScale(st, flowVar, FlowAutocovariance.minCovRatioX32(LAMBDA, Z));
        uint256 uA = FlowVariance.noiseScale(flowVar);

        console2.log("Route A U:", uA);
        console2.log("Route B U:", uB);
        console2.log("divergence (Q32.32):", FlowAutocovariance.divergenceX32(uA, uB));

        assertGt(uB, 0, "Route B must produce an estimate when identified");
    }

    function _flowSeriesAndRun(int256 rhoPct, int256 noise, uint256 seed)
        internal
        pure
        returns (FlowCovState memory, uint64)
    {
        return _run(_flowSeries(6000, rhoPct, noise, seed));
    }

    function test_RouteB_DivergenceGrowsAwayFromEquilibrium() public pure {
        (FlowCovState memory sEq, uint64 vEq) = _flowSeriesAndRun(70, 1400, 31);

        (FlowCovState memory sFar, uint64 vFar) = _flowSeriesAndRun(70, 300, 32);

        uint256 uBeq = FlowAutocovariance.noiseScale(sEq, vEq, FlowAutocovariance.minCovRatioX32(LAMBDA, Z));
        uint256 uBfar = FlowAutocovariance.noiseScale(sFar, vFar, FlowAutocovariance.minCovRatioX32(LAMBDA, Z));
        assertGt(uBeq, 0, "equilibrium arm must be identified");
        assertGt(uBfar, 0, "informed-dominated arm must be identified");

        uint256 dEq = FlowAutocovariance.divergenceX32(FlowVariance.noiseScale(vEq), uBeq);
        uint256 dFar = FlowAutocovariance.divergenceX32(FlowVariance.noiseScale(vFar), uBfar);

        console2.log("divergence near equilibrium  (Q32.32):", dEq);
        console2.log("divergence informed-dominated(Q32.32):", dFar);

        assertGt(dFar, dEq, "divergence must grow as the pool leaves equilibrium");
    }

    function test_RouteB_AbstainsWhenNotIdentified() public pure {
        (FlowCovState memory st, uint64 flowVar) = _flowSeriesAndRun(0, 2000, 41);

        console2.log("cov1:", st.cov1);
        console2.log("cov2:", st.cov2);

        assertFalse(
            FlowAutocovariance.isIdentified(st, flowVar, FlowAutocovariance.minCovRatioX32(LAMBDA, Z)),
            "an unidentified estimator must not claim a result"
        );
        assertEq(
            FlowAutocovariance.noiseScale(st, flowVar, FlowAutocovariance.minCovRatioX32(LAMBDA, Z)),
            0,
            "abstain returns zero"
        );
    }

    function test_RouteB_AbstainsOnEmptyState() public pure {
        FlowCovState memory st;
        assertFalse(
            FlowAutocovariance.isIdentified(st, 0, FlowAutocovariance.minCovRatioX32(LAMBDA, Z)),
            "empty state is not identified"
        );
        assertEq(FlowAutocovariance.rhoX32(st), 0, "rho is zero on empty state");
        assertEq(
            FlowAutocovariance.noiseScale(st, 1000, FlowAutocovariance.minCovRatioX32(LAMBDA, Z)),
            0,
            "no estimate on empty state"
        );
    }

    function test_RouteB_RejectsNonStationaryRho() public pure {
        FlowCovState memory st;
        st.cov1 = 1000;
        st.cov2 = 2000;
        assertFalse(FlowAutocovariance.isIdentified(st, 100_000, 0), "rho above one must be rejected");
    }

    function testFuzz_RouteB_NeverReverts(int64 f1, int64 f2, int64 f3, uint64 flowVar) public pure {
        FlowCovState memory st;
        st = FlowAutocovariance.update(st, f1, LAMBDA);
        st = FlowAutocovariance.update(st, f2, LAMBDA);
        st = FlowAutocovariance.update(st, f3, LAMBDA);

        FlowAutocovariance.rhoX32(st);
        FlowAutocovariance.noiseScale(st, flowVar, FlowAutocovariance.minCovRatioX32(LAMBDA, Z));
        assertTrue(true);
    }
}
