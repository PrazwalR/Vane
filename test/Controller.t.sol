// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {VarianceRatio, ControllerParams} from "../src/libraries/VarianceRatio.sol";

contract ControllerTest is Test {
    uint256 internal constant ONE_X32 = 1 << 32;
    uint256 internal constant ONE_X64 = 1 << 64;

    uint256 internal constant KAPPA_ANCHOR = ONE_X64;
    uint256 internal constant KAPPA_MAX = 4 * ONE_X64;

    uint256 internal constant ETA = ONE_X32 / 100;
    uint256 internal constant RHO = ONE_X32 / 100;
    uint256 internal constant NO_DEADBAND = 0;

    function _vrSample(uint256 seed, uint256 spreadX32) internal pure returns (uint256) {
        uint256 h = uint256(keccak256(abi.encode(seed)));

        int256 offset = int256(h % (2 * spreadX32 + 1)) - int256(spreadX32);
        int256 vr = int256(ONE_X32) + offset;
        return vr < 0 ? 0 : uint256(vr);
    }

    function test_Controller_LeakPreventsClampSaturation() public pure {
        uint256 spread = ONE_X32 / 7;

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

        uint256 lowerBand = KAPPA_ANCHOR / 2;
        uint256 upperBand = 2 * KAPPA_ANCHOR;
        assertGt(kappaLeaky, lowerBand, "leaky controller must not collapse");
        assertLt(kappaLeaky, upperBand, "leaky controller must not run away");
    }

    function test_Controller_BiasProducesBoundedOffset() public pure {
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

        uint256 expected = KAPPA_ANCHOR + ONE_X64 / 10;
        assertApproxEqRel(kappaLeaky, expected, 0.02e18, "offset must match eta*err/rho");
    }

    function test_Controller_RespondsToRealSignal() public pure {
        uint256 trendingVr = ONE_X32 + ONE_X32 / 4;

        uint256 kappa = KAPPA_ANCHOR;
        for (uint256 i = 0; i < 20_000; i++) {
            kappa = VarianceRatio.step(
                kappa, KAPPA_ANCHOR, KAPPA_ANCHOR, trendingVr, ControllerParams(ETA, RHO, NO_DEADBAND, KAPPA_MAX)
            );
        }

        console2.log("kappa after sustained VR = 1.25:", kappa);
        assertGt(kappa, KAPPA_ANCHOR, "a trending pool must raise kappa above the anchor");
    }

    function test_Controller_MeanReversionLowersKappa() public pure {
        uint256 revertingVr = ONE_X32 / 2;

        uint256 kappa = KAPPA_ANCHOR;
        for (uint256 i = 0; i < 20_000; i++) {
            kappa = VarianceRatio.step(
                kappa, KAPPA_ANCHOR, KAPPA_ANCHOR, revertingVr, ControllerParams(ETA, RHO, NO_DEADBAND, KAPPA_MAX)
            );
        }

        console2.log("kappa after sustained VR = 0.5:", kappa);
        assertLt(kappa, KAPPA_ANCHOR, "a mean-reverting pool must lower kappa");
    }

    function test_Controller_DeadbandSuppressesSmallExcursions() public pure {
        uint256 deadband = ONE_X32 / 5;
        uint256 smallVr = ONE_X32 + ONE_X32 / 10;

        uint256 kappa = KAPPA_ANCHOR;
        for (uint256 i = 0; i < 100; i++) {
            kappa = VarianceRatio.step(
                kappa, KAPPA_ANCHOR, KAPPA_ANCHOR, smallVr, ControllerParams(ETA, RHO, deadband, KAPPA_MAX)
            );
        }

        assertEq(kappa, KAPPA_ANCHOR, "excursions inside the deadband must not move kappa");
    }

    function test_Controller_DeadbandAllowsLargeExcursions() public pure {
        uint256 deadband = ONE_X32 / 10;
        uint256 largeVr = ONE_X32 + ONE_X32 / 2;

        uint256 kappa = KAPPA_ANCHOR;
        for (uint256 i = 0; i < 1000; i++) {
            kappa = VarianceRatio.step(
                kappa, KAPPA_ANCHOR, KAPPA_ANCHOR, largeVr, ControllerParams(ETA, RHO, deadband, KAPPA_MAX)
            );
        }

        assertGt(kappa, KAPPA_ANCHOR, "excursions beyond the deadband must move kappa");
    }

    function test_NoiseSigma_MatchesClosedForm() public pure {
        uint256 lambda99 = (uint256(99) << 32) / 100;
        uint256 sigma99 = VarianceRatio.noiseSigmaX32(lambda99);
        console2.log("SD(VR) at lambda=0.99, Q32.32:", sigma99);
        assertApproxEqRel(sigma99, (uint256(14178) << 32) / 100_000, 0.01e18, "lambda=0.99 sigma");

        uint256 lambda999 = (uint256(999) << 32) / 1000;
        uint256 sigma999 = VarianceRatio.noiseSigmaX32(lambda999);
        console2.log("SD(VR) at lambda=0.999, Q32.32:", sigma999);
        assertApproxEqRel(sigma999, (uint256(4474) << 32) / 100_000, 0.02e18, "lambda=0.999 sigma");

        assertLt(sigma999, sigma99, "a longer memory must reduce estimator noise");
    }

    function test_LoopGain_IsExplicit() public pure {
        uint256 gain = VarianceRatio.loopGainX32(ETA, RHO);
        assertEq(gain, ONE_X32, "equal eta and rho must give unit loop gain");

        uint256 gain10 = VarianceRatio.loopGainX32(ETA, RHO / 10);
        assertApproxEqRel(gain10, 10 * ONE_X32, 0.01e18, "a tenfold smaller leak gives tenfold gain");
    }

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

    /// The controller cannot create a gain. It can only track and decay one that the
    /// open-loop estimate already produced.
    ///
    /// `driveX64 = (eta * err * kappaScaleX64) >> 64`, and `VaneHook._stepHorizon` passes
    /// the open-loop gain as BOTH the anchor and the scale. So when the open-loop gain is
    /// zero the drive term is identically zero for every variance ratio, and the leak can
    /// only pull kappa toward the zero anchor. No amount of measured inefficiency lifts it.
    ///
    /// This matters for the project's headline result. The replay simulator found kappa
    /// identically zero under volatility generated by the pool's own flow, because
    /// `lambda* = lambda_amm / 2` makes Route A's open-loop gain zero by construction.
    /// Route B only ever attenuates. And Route C — tested here — multiplies by that same
    /// zero. All three routes are therefore blocked by one cause, and the VR > 4 activation
    /// threshold is entirely Route A's doing; the controller merely follows it up.
    function test_Controller_CannotLiftAGainFromZero() public pure {
        uint256 kappa = 0;

        // Two hundred thousand blocks at a variance ratio a thousand times the efficient
        // value — far beyond anything a market produces.
        for (uint256 i = 0; i < 10_000; i++) {
            kappa = VarianceRatio.step(kappa, 0, 0, 1000 * ONE_X32, ControllerParams(ETA, RHO, NO_DEADBAND, KAPPA_MAX));
        }

        assertEq(kappa, 0, "a zero open-loop gain cannot be lifted by the controller at any variance ratio");
    }

    /// The same controller, given something to work from, reaches its cap — so the
    /// inertness above is specific to the zero anchor and not a broken control law.
    function test_Controller_DoesLiftAGainThatExists() public pure {
        uint256 anchor = KAPPA_MAX / 2;
        uint256 kappa = 0;

        for (uint256 i = 0; i < 200; i++) {
            kappa = VarianceRatio.step(
                kappa, anchor, anchor, 10 * ONE_X32, ControllerParams(ETA, RHO, NO_DEADBAND, KAPPA_MAX)
            );
        }

        assertGt(kappa, anchor, "a live open-loop gain must be amplified by a high variance ratio");
        assertLe(kappa, KAPPA_MAX, "and still respect the cap");
    }
}
