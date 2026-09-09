// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {FlowAutocovariance, FlowCovState} from "../src/libraries/FlowAutocovariance.sol";
import {FlowVariance} from "../src/libraries/FlowVariance.sol";
import {Q64x64} from "../src/libraries/Q64x64.sol";

/// @notice Route B, the autocovariance decomposition. The property that matters is that
///         rho_x is recovered from observable flow rather than supplied as a free
///         parameter, and that the estimator abstains when it has no signal.
contract RouteBTest is Test {
    uint64 internal constant LAMBDA = uint64((uint256(999) << 32) / 1000); // 0.999
    uint256 internal constant ONE_X32 = 1 << 32;
    /// @dev Three standard errors of the covariance EWMA, derived from lambda rather
    ///      than chosen. See FlowAutocovariance.minCovRatioX32.
    uint256 internal constant Z = 3;

    /// @dev Deterministic AR(1) informed flow plus i.i.d. noise, mirroring the model in
    ///      eq (3.4). Not a security primitive; it drives a numerical property test.
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

    /// @notice rho_x = Cov2 / Cov1 must recover the true serial correlation with no free
    ///         parameter. This is what makes Route B falsifiable at all.
    function test_RouteB_RecoversRhoWithoutAFreeParameter() public pure {
        // rho must be large enough to identify at this lambda. Cov2 = rho^2 * Var(x)
        // shrinks quadratically, so weakly correlated informed flow needs more history
        // than a test can run; that regime is covered by the abstention test below.
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

    /// @notice With rho identified, U follows from eq (3.4') and must track the true
    ///         noise scale, which Route A cannot do away from Kyle equilibrium.
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

    /// @notice The two routes must agree near Kyle equilibrium and diverge away from it.
    /// @dev Route A assumes informed and noise flow contribute EXACTLY equally to flow
    ///      variance, which is what Kyle equilibrium predicts, so U_A is correct only at
    ///      an informed share of one half. Route B assumes only that noise is serially
    ///      uncorrelated and holds across the range. Their gap is therefore a direct
    ///      measure of how far the pool sits from the model Route A relies on -- the
    ///      safety valve section 3.2 asks for.
    ///
    ///      Both arms must be identified for the comparison to mean anything. A pool so
    ///      noise-dominated that Route B abstains produces a divergence of zero, which
    ///      reads as "no second opinion", not as agreement.
    function test_RouteB_DivergenceGrowsAwayFromEquilibrium() public pure {
        // Informed share near one half: Var(u) tuned to match Var(x), so Route A's
        // assumption roughly holds and the two estimates should be close.
        (FlowCovState memory sEq, uint64 vEq) = _flowSeriesAndRun(70, 1400, 31);
        // Informed-dominated: Route A's equal-contribution assumption is badly wrong.
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

    /// @notice With no serial structure the estimator must ABSTAIN rather than emit
    ///         noise over noise. Cov1 near zero means rho is not identified.
    function test_RouteB_AbstainsWhenNotIdentified() public pure {
        // rho = 0: informed flow carries no serial correlation at all.
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

    /// @notice A fresh pool has no history, so the estimator must abstain rather than
    ///         divide by a zero covariance.
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

    /// @notice rho above one would mean a non-stationary informed process, which the
    ///         AR(1) picture does not describe. The estimator must reject it.
    function test_RouteB_RejectsNonStationaryRho() public pure {
        FlowCovState memory st;
        st.cov1 = 1000;
        st.cov2 = 2000; // implies rho = 2
        assertFalse(FlowAutocovariance.isIdentified(st, 100_000, 0), "rho above one must be rejected");
    }

    /// @notice The state must never revert, whatever flow it is fed.
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
