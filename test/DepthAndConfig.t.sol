// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {DepthLib} from "../src/libraries/DepthLib.sol";
import {KappaLib} from "../src/libraries/KappaLib.sol";
import {Q64x64} from "../src/libraries/Q64x64.sol";
import {VaneConfig, VaneConfigLib} from "../src/config/VaneConfig.sol";

/// @notice Wraps the internal validator behind an external call.
/// @dev vm.expectRevert requires the revert to happen at a lower call depth than the
///      cheatcode itself. VaneConfigLib.validate is an internal library function and
///      gets inlined into the caller, so calling it directly from a test reverts at the
///      same depth and the cheatcode cannot observe it.
contract ConfigHarness {
    function validate(VaneConfig memory c) external pure {
        VaneConfigLib.validate(c);
    }
}

/// @notice M2: depth from real pool state, and the config validator that lesson 02
///         flagged as the missing safety argument for the controller's arithmetic.
contract DepthAndConfigTest is Test {
    ConfigHarness internal harness;

    function setUp() public {
        harness = new ConfigHarness();
    }

    uint256 internal constant ONE_X32 = 1 << 32;
    uint256 internal constant ONE_X64 = 1 << 64;
    /// @dev A flow unit of 1 leaves depth in raw token units, so the scaling assertions
    ///      below test the L*sqrt(P) relationship itself rather than the denomination.
    uint64 internal constant UNIT_FLOW = 1;

    function _validConfig() internal pure returns (VaneConfig memory c) {
        c = VaneConfig({
            thetaX64: uint64(ONE_X64 / 20), // 0.05 per block
            varLambdaX32: uint64((uint256(99) * ONE_X32) / 100), // 0.99
            flowLambdaX32: uint64((uint256(99) * ONE_X32) / 100),
            horizonK: 20,
            controllerGainX32: uint64(ONE_X32 / 100), // eta = 0.01
            controllerLeakX32: uint64(ONE_X32 / 100), // rho = 0.01
            controllerDeadbandX32: 0,
            kappaMaxX64: uint64(ONE_X64 / 1000),
            deltaMaxX64: uint64(ONE_X64 / 100), // 100 bps
            deltaDustX64: uint64(ONE_X64 / 100_000),
            maxTickDelta: 2000,
            flowUnit: 1e12,
            reserveTargetDefault: 100 ether,
            safetyFactorBps: 20_000
        });
    }

    // ------------------------------------------------------------------
    // DepthLib
    // ------------------------------------------------------------------

    /// @notice At price 1, sqrt(P) = 1, so depth must equal liquidity exactly. This is
    ///         the scaling check that catches a factor-of-2^32 error in the shift.
    function test_Depth_AtUnitPriceEqualsLiquidity() public pure {
        uint160 sqrtPrice1 = uint160(1) << 96; // 1.0 in Q64.96
        uint128 liquidity = 1_000_000;

        uint256 d = DepthLib.depthX64(liquidity, sqrtPrice1, UNIT_FLOW);

        console2.log("depth at P=1 (Q64.64):", d);
        assertEq(d, uint256(liquidity) << 64, "depth must equal L at unit price");
    }

    /// @notice Depth scales linearly with liquidity, which is the property the thesis in
    ///         section 2.4 depends on: more LP capital means more depth means a larger
    ///         gap from D*.
    function testFuzz_Depth_LinearInLiquidity(uint96 rawL, uint8 mult) public pure {
        uint128 l = uint128(bound(uint256(rawL), 1, type(uint96).max));
        uint256 m = bound(uint256(mult), 2, 10);
        uint160 sqrtPrice = uint160(1) << 96;

        uint256 d1 = DepthLib.depthX64(l, sqrtPrice, UNIT_FLOW);
        uint256 dm = DepthLib.depthX64(uint128(l * m), sqrtPrice, UNIT_FLOW);

        assertEq(dm, d1 * m, "depth must scale linearly with liquidity");
    }

    /// @notice Depth scales with sqrt(P), so a 4x price is a 2x depth.
    function test_Depth_ScalesWithSqrtPrice() public pure {
        uint128 l = 1_000_000;
        uint160 sqrtP1 = uint160(1) << 96; // P = 1
        uint160 sqrtP4 = uint160(2) << 96; // sqrt(P) = 2, so P = 4

        uint256 d1 = DepthLib.depthX64(l, sqrtP1, UNIT_FLOW);
        uint256 d4 = DepthLib.depthX64(l, sqrtP4, UNIT_FLOW);

        assertEq(d4, 2 * d1, "quadrupling price must double depth");
    }

    /// @notice An empty pool must return zero depth, not revert. Invariant 1: beforeSwap
    ///         has to survive a pool with no liquidity in range.
    function test_Depth_ZeroLiquidityReturnsZeroNotRevert() public pure {
        assertEq(DepthLib.depthX64(0, uint160(1) << 96, UNIT_FLOW), 0, "zero liquidity gives zero depth");
        assertEq(DepthLib.depthX64(1000, 0, UNIT_FLOW), 0, "zero price gives zero depth");
    }

    /// @notice Must not overflow at the extremes of the v4 price range.
    function testFuzz_Depth_NeverOverflows(uint128 liquidity, uint160 rawSqrtPrice) public pure {
        uint160 sqrtPrice = uint160(bound(uint256(rawSqrtPrice), TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE));
        uint256 d = DepthLib.depthX64(liquidity, sqrtPrice, UNIT_FLOW);
        // Reaching this line without reverting is the assertion.
        assertGe(d, 0);
    }

    /// @notice D* = 4U/sigma, eq (2.3), and the under-reaction test derived from it.
    function test_TargetDepth_MatchesClosedForm() public pure {
        uint256 U = 5 * ONE_X64;
        uint256 sigma = ONE_X64 / 50; // 0.02

        uint256 dStar = DepthLib.targetDepthX64(U, sigma);

        // 4 * 5 / 0.02 = 1000
        assertApproxEqRel(dStar, 1000 * ONE_X64, 0.001e18, "D* must equal 4U/sigma");
    }

    /// @notice A pool deeper than D* under-reacts; a shallower one does not. This is the
    ///         thesis of section 2.4 stated as an executable predicate.
    function test_UnderReaction_MatchesKappaSign() public pure {
        uint256 U = 5 * ONE_X64;
        uint256 sigma = ONE_X64 / 50;
        uint256 dStar = DepthLib.targetDepthX64(U, sigma);

        uint256 deep = dStar * 2;
        uint256 shallow = dStar / 2;

        assertTrue(DepthLib.isUnderReacting(deep, U, sigma), "a deep pool under-reacts");
        assertFalse(DepthLib.isUnderReacting(shallow, U, sigma), "a shallow pool does not");

        // The predicate must agree with the sign of kappa, since both derive from eq (2.5).
        uint256 kappaDeep = KappaLib.kappaX64(deep, sigma, U, type(uint64).max);
        uint256 kappaShallow = KappaLib.kappaX64(shallow, sigma, U, type(uint64).max);

        assertGt(kappaDeep, 0, "under-reacting pool must have positive kappa");
        assertEq(kappaShallow, 0, "over-reacting pool must have kappa clamped to zero");
    }

    // ------------------------------------------------------------------
    // VaneConfig
    // ------------------------------------------------------------------

    function test_Config_ValidConfigPasses() public pure {
        VaneConfigLib.validate(_validConfig());
    }

    /// @notice The leak must be strictly positive. This is the stability requirement
    ///         from lesson 02, enforced rather than documented.
    function test_Config_RevertsOnZeroLeak() public {
        VaneConfig memory c = _validConfig();
        c.controllerLeakX32 = 0;
        vm.expectRevert(VaneConfigLib.Vane__ControllerLeakZero.selector);
        harness.validate(c);
    }

    /// @notice The gain bound is what makes the overflow argument in VarianceRatio.step
    ///         sound. Lesson 02 Q5 flagged that this validator did not exist.
    function test_Config_RevertsOnExcessiveGain() public {
        VaneConfig memory c = _validConfig();
        c.controllerGainX32 = uint64(ONE_X32 / 2);
        vm.expectRevert(VaneConfigLib.Vane__ControllerGainTooLarge.selector);
        harness.validate(c);
    }

    /// @notice Both directions of the flow-unit trap from lesson 01 Q5.
    function test_Config_RevertsOnFlowUnitOutOfRange() public {
        VaneConfig memory c = _validConfig();

        c.flowUnit = 1; // too small: the accumulator saturates
        vm.expectRevert(VaneConfigLib.Vane__FlowUnitOutOfRange.selector);
        harness.validate(c);

        c.flowUnit = 1e19; // too large: every trade truncates to zero flow
        vm.expectRevert(VaneConfigLib.Vane__FlowUnitOutOfRange.selector);
        harness.validate(c);
    }

    function test_Config_RevertsOnShortHorizon() public {
        VaneConfig memory c = _validConfig();
        c.horizonK = 1; // VR at k=1 is identically 1 and carries no information
        vm.expectRevert(VaneConfigLib.Vane__HorizonTooShort.selector);
        harness.validate(c);
    }

    function test_Config_RevertsOnThetaOutOfRange() public {
        VaneConfig memory c = _validConfig();
        c.thetaX64 = 0;
        vm.expectRevert(VaneConfigLib.Vane__ThetaOutOfRange.selector);
        harness.validate(c);
    }

    function test_Config_RevertsOnDustAboveMax() public {
        VaneConfig memory c = _validConfig();
        c.deltaDustX64 = c.deltaMaxX64;
        vm.expectRevert(VaneConfigLib.Vane__DeltaDustNotBelowMax.selector);
        harness.validate(c);
    }

    function test_Config_RevertsOnTickDeltaOutOfRange() public {
        VaneConfig memory c = _validConfig();
        c.maxTickDelta = 0;
        vm.expectRevert(VaneConfigLib.Vane__MaxTickDeltaOutOfRange.selector);
        harness.validate(c);

        c.maxTickDelta = 9000;
        vm.expectRevert(VaneConfigLib.Vane__MaxTickDeltaOutOfRange.selector);
        harness.validate(c);
    }

    function test_Config_RevertsOnLowSafetyFactor() public {
        VaneConfig memory c = _validConfig();
        c.safetyFactorBps = 9_999;
        vm.expectRevert(VaneConfigLib.Vane__SafetyFactorTooLow.selector);
        harness.validate(c);
    }

    /// @notice Every Q64.64 config field must be able to hold the value the mechanism
    ///         actually uses. This guards a defect class that has now appeared twice:
    ///         1.0 in Q64.64 is 2^64, which overflows a uint64 by exactly one bit and
    ///         truncates to zero silently. It zeroed the belief in the draft packed
    ///         state, and it zeroed the reserve ratio here, both of which disable the
    ///         mechanism without reverting.
    function test_Config_NoFieldSilentlyTruncatesToZero() public pure {
        VaneConfig memory c = _validConfig();

        assertGt(c.thetaX64, 0, "theta must survive its cast");
        assertGt(c.varLambdaX32, 0, "var lambda must survive its cast");
        assertGt(c.flowLambdaX32, 0, "flow lambda must survive its cast");
        assertGt(c.kappaMaxX64, 0, "kappa max must survive its cast");
        assertGt(c.deltaMaxX64, 0, "delta max must survive its cast");
        assertGt(c.reserveTargetDefault, 0, "reserve target must survive its cast");

        // The boundary itself: 1.0 in Q64.64 does not fit, 1.0 in Q32.32 does.
        assertEq(uint64(ONE_X64), 0, "1.0 in Q64.64 truncates to zero in a uint64");
        assertGt(uint64(ONE_X32), 0, "1.0 in Q32.32 fits a uint64");
    }

    /// @notice The loop gain must be computable from config, so a deployer sees the
    ///         number that actually governs the controller's behaviour.
    function test_Config_LoopGainIsVisible() public pure {
        VaneConfig memory c = _validConfig();
        assertEq(VaneConfigLib.loopGainX32(c), ONE_X32, "equal eta and rho give unit gain");

        c.controllerLeakX32 = uint64(ONE_X32 / 1000);
        assertApproxEqRel(VaneConfigLib.loopGainX32(c), 10 * ONE_X32, 0.01e18, "smaller leak means larger gain");
    }

    /// @notice A valid config must never revert, whatever the fuzzer picks inside the
    ///         documented ranges.
    function testFuzz_Config_ValidRangesAlwaysPass(
        uint64 rawTheta,
        uint64 rawVarLambda,
        uint16 rawK,
        uint64 rawGain,
        uint64 rawLeak
    ) public pure {
        VaneConfig memory c = _validConfig();
        c.thetaX64 = uint64(bound(uint256(rawTheta), 1, ONE_X64 - 1));
        c.varLambdaX32 = uint64(bound(uint256(rawVarLambda), 1, ONE_X32 - 1));
        c.horizonK = uint16(bound(uint256(rawK), 2, type(uint16).max));
        c.controllerGainX32 = uint64(bound(uint256(rawGain), 1, ONE_X32 / 10));
        c.controllerLeakX32 = uint64(bound(uint256(rawLeak), 1, ONE_X32 - 1));

        VaneConfigLib.validate(c);
    }
}
