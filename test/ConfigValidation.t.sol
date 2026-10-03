// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {VaneConfig, VaneConfigLib} from "../src/config/VaneConfig.sol";
import {VaneParameters} from "../script/VaneParameters.sol";

contract ConfigHarness {
    function validate(VaneConfig memory c) external pure {
        VaneConfigLib.validate(c);
    }
}

contract ConfigValidationTest is Test {
    uint256 internal constant ONE_X32 = 1 << 32;
    uint256 internal constant ONE_X64 = 1 << 64;

    ConfigHarness internal harness;

    function setUp() public {
        harness = new ConfigHarness();
    }

    function _cfg() internal pure returns (VaneConfig memory) {
        return VaneParameters.config();
    }

    /// An unidentifiable Route B must attenuate the gain, which it only does when the
    /// penalty it stands in for exceeds the divergence the hook already tolerates.
    /// Otherwise an unavailable cross-check would scale kappa by one and the guard that
    /// exists to distrust it would be inert.
    function test_Reverts_UnidentifiedPenaltyBelowTolerance() public {
        VaneConfig memory c = _cfg();
        c.unidentifiedPenaltyX32 = c.maxEstimatorDivergenceX32;
        vm.expectRevert(VaneConfigLib.Vane__UnidentifiedPenaltyTooLow.selector);
        harness.validate(c);
    }

    function test_Reverts_UnidentifiedPenaltyZero() public {
        VaneConfig memory c = _cfg();
        c.unidentifiedPenaltyX32 = 0;
        vm.expectRevert(VaneConfigLib.Vane__UnidentifiedPenaltyTooLow.selector);
        harness.validate(c);
    }

    function test_Accepts_UnidentifiedPenaltyJustAboveTolerance() public view {
        VaneConfig memory c = _cfg();
        c.unidentifiedPenaltyX32 = c.maxEstimatorDivergenceX32 + 1;
        harness.validate(c);
    }

    function test_Reverts_VarLambdaZero() public {
        VaneConfig memory c = _cfg();
        c.varLambdaX32 = 0;
        vm.expectRevert(VaneConfigLib.Vane__VarLambdaOutOfRange.selector);
        harness.validate(c);
    }

    function test_Reverts_VarLambdaAtUnity() public {
        VaneConfig memory c = _cfg();
        c.varLambdaX32 = uint64(ONE_X32);
        vm.expectRevert(VaneConfigLib.Vane__VarLambdaOutOfRange.selector);
        harness.validate(c);
    }

    function test_Reverts_FlowLambdaZero() public {
        VaneConfig memory c = _cfg();
        c.flowLambdaX32 = 0;
        vm.expectRevert(VaneConfigLib.Vane__FlowLambdaOutOfRange.selector);
        harness.validate(c);
    }

    function test_Reverts_FlowLambdaAtUnity() public {
        VaneConfig memory c = _cfg();
        c.flowLambdaX32 = uint64(ONE_X32);
        vm.expectRevert(VaneConfigLib.Vane__FlowLambdaOutOfRange.selector);
        harness.validate(c);
    }

    function test_Reverts_ControllerGainZero() public {
        VaneConfig memory c = _cfg();
        c.controllerGainX32 = 0;
        vm.expectRevert(VaneConfigLib.Vane__ControllerGainZero.selector);
        harness.validate(c);
    }

    function test_Reverts_ControllerLeakAtUnity() public {
        VaneConfig memory c = _cfg();
        c.controllerLeakX32 = uint64(ONE_X32);
        vm.expectRevert(VaneConfigLib.Vane__ControllerLeakTooLarge.selector);
        harness.validate(c);
    }

    function test_Reverts_DeadbandAtUnity() public {
        VaneConfig memory c = _cfg();
        c.controllerDeadbandX32 = uint64(ONE_X32);
        vm.expectRevert(VaneConfigLib.Vane__DeadbandTooLarge.selector);
        harness.validate(c);
    }

    function test_Reverts_KappaMaxZero() public {
        VaneConfig memory c = _cfg();
        c.kappaMaxX64 = 0;
        vm.expectRevert(VaneConfigLib.Vane__KappaMaxZero.selector);
        harness.validate(c);
    }

    function test_Reverts_DeltaMaxZero() public {
        VaneConfig memory c = _cfg();
        c.deltaMaxX64 = 0;
        c.deltaDustX64 = 0;
        vm.expectRevert(VaneConfigLib.Vane__DeltaMaxZero.selector);
        harness.validate(c);
    }

    function test_Reverts_ReserveTargetZero() public {
        VaneConfig memory c = _cfg();
        c.reserveTargetDefault = 0;
        vm.expectRevert(VaneConfigLib.Vane__ReserveTargetZero.selector);
        harness.validate(c);
    }

    function test_Reverts_MaxDivergenceZero() public {
        VaneConfig memory c = _cfg();
        c.maxEstimatorDivergenceX32 = 0;
        vm.expectRevert(VaneConfigLib.Vane__MaxDivergenceZero.selector);
        harness.validate(c);
    }

    function test_Reverts_RouteBZScoreTooLow() public {
        VaneConfig memory c = _cfg();
        c.routeBZScore = 1;
        vm.expectRevert(VaneConfigLib.Vane__RouteBZScoreTooLow.selector);
        harness.validate(c);
    }

    function test_Reverts_ThetaAtUnity() public {
        VaneConfig memory c = _cfg();
        c.thetaX64 = type(uint64).max;
        harness.validate(c);
    }

    function testFuzz_NeverAcceptsOutOfRangeLambda(uint64 raw) public {
        VaneConfig memory c = _cfg();
        c.varLambdaX32 = raw;
        if (raw == 0 || uint256(raw) >= ONE_X32) {
            vm.expectRevert(VaneConfigLib.Vane__VarLambdaOutOfRange.selector);
            harness.validate(c);
        } else {
            harness.validate(c);
        }
    }
}
