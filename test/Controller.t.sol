// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {VarianceRatio, ControllerParams} from "../src/libraries/VarianceRatio.sol";
import {Q64x64} from "../src/libraries/Q64x64.sol";

/// @notice M5 controller stability. The properties asserted here were derived by
///         simulation before implementation; see docs/lessons/02-controller-stability.md.
///         The headline result is that the specification's pure-integrator control law
///         saturates its own clamp on noise alone, and that a leak toward the open-loop
///         anchor fixes it.
contract ControllerTest is Test {
    uint256 internal constant ONE_X32 = 1 << 32;
    uint256 internal constant ONE_X64 = 1 << 64;

    uint256 internal constant KAPPA_ANCHOR = ONE_X64; // 1.0 in Q64.64
    uint256 internal constant KAPPA_MAX = 4 * ONE_X64;

    uint256 internal constant ETA = ONE_X32 / 100; // 0.01
    uint256 internal constant RHO = ONE_X32 / 100; // 0.01
    uint256 internal constant NO_DEADBAND = 0;

    /// @dev Deterministic pseudo-random VR sequence centred on 1.0 with a controlled
    ///      spread. Not a security primitive; it drives a numerical stability test.
    function _vrSample(uint256 seed, uint256 spreadX32) internal pure returns (uint256) {
        uint256 h = uint256(keccak256(abi.encode(seed)));
        // Uniform in [-spread, +spread] around 1.0.
        int256 offset = int256(h % (2 * spreadX32 + 1)) - int256(spreadX32);
        int256 vr = int256(ONE_X32) + offset;
        return vr < 0 ? 0 : uint256(vr);
    }

    /// @notice A martingale pool must leave kappa near the anchor. With a pure
    ///         integrator (rho = 0) the noise random-walks kappa into a clamp; with a
    ///         leak it stays put. This is the core stability claim.
    function test_Controller_LeakPreventsClampSaturation() public pure {
        uint256 spread = ONE_X32 / 7; // ~0.14, the measured SD(VR) at lambda = 0.99

        uint256 kappaPure = KAPPA_ANCHOR;
        uint256 kappaLeaky = KAPPA_ANCHOR;

        for (uint256 i = 0; i < 4000; i++) {
            uint256 vr = _vrSample(i, spread);
            kappaPure = VarianceRatio.step(
                kappaPure, KAPPA_ANCHOR, KAPPA_ANCHOR, vr, ControllerParams(ETA, 0, NO_DEADBAND, KAPPA_MAX)
            );
            kappaLeaky = VarianceRatio.step(
                kappaLeaky, KAPPA_ANCHOR, KAPPA_ANCHOR, vr, ControllerParams(ETA, RHO, NO_DEADBAND, KAPPA_MAX)
            );
        }

        console2.log("pure integrator kappa (anchor = 1.0 in Q64.64):", kappaPure);
        console2.log("leaky controller kappa                       :", kappaLeaky);
        console2.log("anchor                                       :", KAPPA_ANCHOR);

        // The leaky controller must stay within a modest band of the anchor.
        uint256 lowerBand = KAPPA_ANCHOR / 2;
        uint256 upperBand = 2 * KAPPA_ANCHOR;
        assertGt(kappaLeaky, lowerBand, "leaky controller must not collapse");
        assertLt(kappaLeaky, upperBand, "leaky controller must not run away");
    }

    /// @notice A persistent bias must produce a BOUNDED offset under the leak, at the
    ///         predicted value eta*bias/rho. Under a pure integrator the same bias runs
    ///         to the clamp. This is the strongest argument for rho > 0.
    function test_Controller_BiasProducesBoundedOffset() public pure {
        // A VR permanently 10% above 1: a real, persistent signal.
        uint256 biasedVr = ONE_X32 + ONE_X32 / 10;

        uint256 kappaPure = KAPPA_ANCHOR;
        uint256 kappaLeaky = KAPPA_ANCHOR;
        for (uint256 i = 0; i < 20_000; i++) {
            kappaPure = VarianceRatio.step(
                kappaPure, KAPPA_ANCHOR, KAPPA_ANCHOR, biasedVr, ControllerParams(ETA, 0, NO_DEADBAND, KAPPA_MAX)
            );
            kappaLeaky = VarianceRatio.step(
                kappaLeaky, KAPPA_ANCHOR, KAPPA_ANCHOR, biasedVr, ControllerParams(ETA, RHO, NO_DEADBAND, KAPPA_MAX)
            );
        }

        console2.log("pure integrator, persistent 10% VR error:", kappaPure);
        console2.log("leaky controller, same input            :", kappaLeaky);

        assertEq(kappaPure, KAPPA_MAX, "pure integrator must saturate on a persistent error");
        assertLt(kappaLeaky, KAPPA_MAX, "leaky controller must not saturate");

        // Steady state solves eta*err = rho*(kappa - anchor), so the offset is
        // (eta/rho) * err = 1.0 * 0.10 = 0.10 above the anchor.
        uint256 expected = KAPPA_ANCHOR + ONE_X64 / 10;
        assertApproxEqRel(kappaLeaky, expected, 0.02e18, "offset must match eta*err/rho");
    }

    /// @notice The controller must still respond to a genuine signal: noise rejection
    ///         must not be bought with blindness.
    function test_Controller_RespondsToRealSignal() public pure {
        uint256 trendingVr = ONE_X32 + ONE_X32 / 4; // VR = 1.25, strongly trending

        uint256 kappa = KAPPA_ANCHOR;
        for (uint256 i = 0; i < 20_000; i++) {
            kappa = VarianceRatio.step(
                kappa, KAPPA_ANCHOR, KAPPA_ANCHOR, trendingVr, ControllerParams(ETA, RHO, NO_DEADBAND, KAPPA_MAX)
            );
        }

        console2.log("kappa after sustained VR = 1.25:", kappa);
        assertGt(kappa, KAPPA_ANCHOR, "a trending pool must raise kappa above the anchor");
    }

    /// @notice VR below 1 means the pool over-corrected, so kappa must fall.
    function test_Controller_MeanReversionLowersKappa() public pure {
        uint256 revertingVr = ONE_X32 / 2; // VR = 0.5

        uint256 kappa = KAPPA_ANCHOR;
        for (uint256 i = 0; i < 20_000; i++) {
            kappa = VarianceRatio.step(
                kappa, KAPPA_ANCHOR, KAPPA_ANCHOR, revertingVr, ControllerParams(ETA, RHO, NO_DEADBAND, KAPPA_MAX)
            );
        }

        console2.log("kappa after sustained VR = 0.5:", kappa);
        assertLt(kappa, KAPPA_ANCHOR, "a mean-reverting pool must lower kappa");
    }

    /// @notice The deadband must suppress updates inside the noise floor entirely.
    function test_Controller_DeadbandSuppressesSmallExcursions() public pure {
        uint256 deadband = ONE_X32 / 5; // 0.2
        uint256 smallVr = ONE_X32 + ONE_X32 / 10; // deviation 0.1, inside the band

        uint256 kappa = KAPPA_ANCHOR;
        for (uint256 i = 0; i < 100; i++) {
            kappa = VarianceRatio.step(
                kappa, KAPPA_ANCHOR, KAPPA_ANCHOR, smallVr, ControllerParams(ETA, RHO, deadband, KAPPA_MAX)
            );
        }

        assertEq(kappa, KAPPA_ANCHOR, "excursions inside the deadband must not move kappa");
    }

    /// @notice Beyond the deadband the controller must act normally.
    function test_Controller_DeadbandAllowsLargeExcursions() public pure {
        uint256 deadband = ONE_X32 / 10; // 0.1
        uint256 largeVr = ONE_X32 + ONE_X32 / 2; // deviation 0.5, well outside

        uint256 kappa = KAPPA_ANCHOR;
        for (uint256 i = 0; i < 1000; i++) {
            kappa = VarianceRatio.step(
                kappa, KAPPA_ANCHOR, KAPPA_ANCHOR, largeVr, ControllerParams(ETA, RHO, deadband, KAPPA_MAX)
            );
        }

        assertGt(kappa, KAPPA_ANCHOR, "excursions beyond the deadband must move kappa");
    }

    /// @notice The noise sigma closed form must match the derivation
    ///         SD = 2*sqrt((1-lambda)/(1+lambda)), verified against values computed
    ///         independently in the simulator.
    function test_NoiseSigma_MatchesClosedForm() public pure {
        // lambda = 0.99 -> 2*sqrt(0.01/1.99) = 0.14178
        uint256 lambda99 = (uint256(99) << 32) / 100;
        uint256 sigma99 = VarianceRatio.noiseSigmaX32(lambda99);
        console2.log("SD(VR) at lambda=0.99, Q32.32:", sigma99);
        assertApproxEqRel(sigma99, (uint256(14178) << 32) / 100_000, 0.01e18, "lambda=0.99 sigma");

        // lambda = 0.999 -> 2*sqrt(0.001/1.999) = 0.04474
        uint256 lambda999 = (uint256(999) << 32) / 1000;
        uint256 sigma999 = VarianceRatio.noiseSigmaX32(lambda999);
        console2.log("SD(VR) at lambda=0.999, Q32.32:", sigma999);
        assertApproxEqRel(sigma999, (uint256(4474) << 32) / 100_000, 0.02e18, "lambda=0.999 sigma");

        // Noise must fall as lambda rises: more averaging, less noise.
        assertLt(sigma999, sigma99, "a longer memory must reduce estimator noise");
    }

    /// @notice The loop gain eta/rho is the amplification of a persistent error and must
    ///         be computable by the deployer before deployment.
    function test_LoopGain_IsExplicit() public pure {
        uint256 gain = VarianceRatio.loopGainX32(ETA, RHO);
        assertEq(gain, ONE_X32, "equal eta and rho must give unit loop gain");

        uint256 gain10 = VarianceRatio.loopGainX32(ETA, RHO / 10);
        assertApproxEqRel(gain10, 10 * ONE_X32, 0.01e18, "a tenfold smaller leak gives tenfold gain");
    }

    /// @notice The controller must never leave the clamp, for any inputs including
    ///         adversarial ones. Invariant 9 and 10.
    function testFuzz_Controller_StaysWithinClamp(uint256 rawKappa, uint256 rawVr, uint64 rawEta, uint64 rawRho)
        public
        pure
    {
        uint256 kappa = bound(rawKappa, 0, KAPPA_MAX);
        uint256 vr = bound(rawVr, 0, 100 * ONE_X32);
        uint256 eta = bound(uint256(rawEta), 0, ONE_X32 / 10);
        uint256 rho = bound(uint256(rawRho), 0, ONE_X32);

        uint256 next = VarianceRatio.step(
            kappa, KAPPA_ANCHOR, KAPPA_ANCHOR, vr, ControllerParams(eta, rho, NO_DEADBAND, KAPPA_MAX)
        );

        assertLe(next, KAPPA_MAX, "kappa must never exceed its cap");
    }

    /// @notice Repeated stepping must never revert, so the controller cannot brick the
    ///         afterSwap path. Invariant 1 extended to the control loop.
    function testFuzz_Controller_NeverReverts(uint256 rawVr, uint64 rawEta, uint64 rawRho) public pure {
        uint256 vr = bound(rawVr, 0, 1000 * ONE_X32);
        uint256 eta = bound(uint256(rawEta), 0, ONE_X32);
        uint256 rho = bound(uint256(rawRho), 0, ONE_X32);

        uint256 kappa = KAPPA_ANCHOR;
        for (uint256 i = 0; i < 50; i++) {
            kappa = VarianceRatio.step(
                kappa, KAPPA_ANCHOR, KAPPA_ANCHOR, vr, ControllerParams(eta, rho, NO_DEADBAND, KAPPA_MAX)
            );
        }
        assertLe(kappa, KAPPA_MAX, "kappa must remain clamped after repeated steps");
    }
}
