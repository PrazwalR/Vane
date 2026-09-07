// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Q64x64} from "./Q64x64.sol";

/// @title VarianceRatio
/// @notice The variance-ratio control loop, per spec section 3.3, with the stability
///         correction derived in docs/lessons/02-controller-stability.md.
/// @dev The specification's control law is
///
///          kappa <- clamp(kappa + eta*(VR - 1)*kappa_scale, 0, kappa_max)
///
///      which is a PURE INTEGRATOR. It has no restoring force, and that is a defect
///      rather than a simplification:
///
///        1. Any bias in the error signal, however small, accumulates without bound as
///           eta*bias*n. A 2% bias at eta = 0.01 drives kappa to its clamp within a few
///           thousand control steps, at which point the pool reports maximum confidence
///           in a belief it has no evidence for.
///        2. Even with zero bias the noise alone is a random walk whose spread grows as
///           sqrt(n), so kappa reaches a clamp eventually, and a random walk with
///           reflecting bounds concentrates AT the bounds. Simulation shows kappa pinned
///           at 0 or kappa_max 10 to 22 percent of the time at the gains a reader would
///           naturally choose.
///
///      Both failures are silent: a pool whose kappa is pinned at zero is a plain v4
///      pool that believes it is running a control loop.
///
///      The fix is to leak toward the open-loop kappa from eq (2.5), which section 3.3
///      already designates as the anchor:
///
///          kappa <- clamp(kappa + eta*(VR - 1)*kappa_scale
///                               - rho*(kappa - kappa_openLoop), 0, kappa_max)
///
///      This is an Ornstein-Uhlenbeck process rather than a random walk. Its noise
///      spread is bounded instead of growing, and a persistent bias produces a bounded
///      offset eta*bias/rho instead of unbounded drift. The cost is that the
///      steady-state loop gain becomes eta/rho, so a real signal moves kappa by
///      eta*error/rho rather than running to the clamp. Choosing rho is choosing that
///      gain deliberately, which the original formulation left undefined.
library VarianceRatio {
    /// @notice Q32.32 unit, the scale VR and the controller parameters are carried in.
    uint256 internal constant ONE_X32 = 1 << 32;

    /// @notice Steps the controller one control period.
    /// @dev Caller must only invoke this when a horizon checkpoint has elapsed AND the
    ///      per-block variance is nonzero. A zero varOne yields VR = 0 from
    ///      HorizonVariance, which is numerically indistinguishable from extreme mean
    ///      reversion and would ratchet kappa to zero on a quiet pool; the guard belongs
    ///      at the call site because only the caller knows whether a sample was taken.
    /// @param kappaX64 Current impact gain, Q64.64.
    /// @param kappaOpenLoopX64 Open-loop kappa from eq (2.5), the anchor.
    /// @param varianceRatioX32 Measured VR in Q32.32, from HorizonVariance.
    /// @param etaX32 Controller gain in Q32.32.
    /// @param rhoX32 Leak rate toward the anchor in Q32.32, strictly positive.
    /// @param deadbandX32 Absolute VR deviation below which no update is made, Q32.32.
    /// @param kappaMaxX64 Upper clamp on kappa.
    /// @return Next kappa, Q64.64.
    function step(
        uint256 kappaX64,
        uint256 kappaOpenLoopX64,
        uint256 varianceRatioX32,
        uint256 etaX32,
        uint256 rhoX32,
        uint256 deadbandX32,
        uint256 kappaMaxX64
    ) internal pure returns (uint256) {
        // Error term (VR - 1) in Q32.32, signed.
        int256 errX32 = int256(varianceRatioX32) - int256(ONE_X32);

        // The deadband rejects excursions inside the estimator's own noise floor. It is
        // sized from SD(VR), not chosen: see the lesson for the closed form.
        uint256 absErr = errX32 < 0 ? uint256(-errX32) : uint256(errX32);
        if (absErr <= deadbandX32) {
            errX32 = 0;
        }

        // Proportional term: eta * (VR - 1), carried at Q64.64 to match kappa's scale.
        // etaX32 and errX32 are both Q32.32, so their product is Q64.64 directly.
        int256 driveX64 = (int256(etaX32) * errX32) / 1;

        // Leak term: -rho * (kappa - anchor), in Q64.64.
        int256 deviationX64 = int256(kappaX64) - int256(kappaOpenLoopX64);
        int256 leakX64 = (int256(rhoX32) * deviationX64) >> 32;

        int256 next = int256(kappaX64) + driveX64 - leakX64;

        if (next < 0) return 0;
        if (uint256(next) > kappaMaxX64) return kappaMaxX64;
        return uint256(next);
    }

    /// @notice Standard deviation of the VR estimator under the martingale null, Q32.32.
    /// @dev Closed form for VANE's estimator, NOT the Lo-MacKinlay phi(q). Lo-MacKinlay
    ///      describes a fixed rectangular window with overlapping returns and overstates
    ///      this estimator's noise by up to 5x. For two EWMAs sharing a decay lambda,
    ///      each behaves as a chi-square estimate with N = (1+lambda)/(1-lambda)
    ///      effective observations, so
    ///
    ///          Var(ln VR) = 2/N_k + 2/N_1  =>  SD = 2*sqrt((1-lambda)/(1+lambda))
    ///
    ///      Independent of the horizon k, which simulation confirms. Use this to size
    ///      the deadband: a z-sigma deadband is z times this value.
    /// @param lambdaX32 The shared EWMA decay in Q32.32.
    function noiseSigmaX32(uint256 lambdaX32) internal pure returns (uint256) {
        if (lambdaX32 >= ONE_X32) return 0;
        uint256 numerator = ONE_X32 - lambdaX32;
        uint256 denominator = ONE_X32 + lambdaX32;

        // sqrt of a Q32.32 ratio, then doubled.
        uint256 ratioX32 = (numerator << 32) / denominator;
        return 2 * Q64x64.sqrtX32(ratioX32);
    }

    /// @notice Steady-state loop gain eta/rho, Q32.32.
    /// @dev The factor by which a persistent VR error is amplified into a kappa offset.
    ///      Exposed so the deployer sizes it explicitly rather than discovering it.
    function loopGainX32(uint256 etaX32, uint256 rhoX32) internal pure returns (uint256) {
        if (rhoX32 == 0) return type(uint256).max;
        return (etaX32 << 32) / rhoX32;
    }
}
