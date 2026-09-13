// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

struct VaneConfig {


    uint64 thetaX64;

    uint64 varLambdaX32;

    uint64 flowLambdaX32;

    uint16 horizonK;

    uint64 controllerGainX32;

    uint64 controllerLeakX32;

    uint64 controllerDeadbandX32;

    uint64 kappaMaxX64;

    uint64 deltaMaxX64;

    uint64 deltaDustX64;

    int24 maxTickDelta;

    uint64 flowUnit;

    uint128 reserveTargetDefault;

    uint64 maxEstimatorDivergenceX32;

    uint64 routeBZScore;
}

library VaneConfigLib {
    uint256 internal constant ONE_X32 = 1 << 32;
    uint256 internal constant ONE_X64 = 1 << 64;

    uint64 internal constant MIN_FLOW_UNIT = 1e9;

    uint64 internal constant MAX_FLOW_UNIT = 1e18;

    int24 internal constant MAX_ALLOWED_TICK_DELTA = 8000;

    error Vane__ThetaOutOfRange();
    error Vane__VarLambdaOutOfRange();
    error Vane__FlowLambdaOutOfRange();
    error Vane__HorizonTooShort();
    error Vane__ControllerGainZero();
    error Vane__ControllerGainTooLarge();
    error Vane__ControllerLeakZero();
    error Vane__ControllerLeakTooLarge();
    error Vane__DeadbandTooLarge();
    error Vane__KappaMaxZero();
    error Vane__DeltaMaxZero();
    error Vane__DeltaMaxTooLarge();
    error Vane__DeltaDustNotBelowMax();
    error Vane__MaxTickDeltaOutOfRange();
    error Vane__FlowUnitOutOfRange();
    error Vane__ReserveTargetZero();
    error Vane__MaxDivergenceZero();
    error Vane__RouteBZScoreTooLow();

    function validate(VaneConfig memory c) internal pure {
        if (c.thetaX64 == 0 || uint256(c.thetaX64) >= ONE_X64) revert Vane__ThetaOutOfRange();

        if (c.varLambdaX32 == 0 || uint256(c.varLambdaX32) >= ONE_X32) {
            revert Vane__VarLambdaOutOfRange();
        }
        if (c.flowLambdaX32 == 0 || uint256(c.flowLambdaX32) >= ONE_X32) {
            revert Vane__FlowLambdaOutOfRange();
        }

        if (c.horizonK < 2) revert Vane__HorizonTooShort();

        if (c.controllerGainX32 == 0) revert Vane__ControllerGainZero();

        if (uint256(c.controllerGainX32) > ONE_X32 / 10) revert Vane__ControllerGainTooLarge();

        if (c.controllerLeakX32 == 0) revert Vane__ControllerLeakZero();

        if (uint256(c.controllerLeakX32) >= ONE_X32) revert Vane__ControllerLeakTooLarge();

        if (uint256(c.controllerDeadbandX32) >= ONE_X32) revert Vane__DeadbandTooLarge();

        if (c.kappaMaxX64 == 0) revert Vane__KappaMaxZero();
        if (c.deltaMaxX64 == 0) revert Vane__DeltaMaxZero();
        if (c.deltaMaxX64 > uint64(type(int64).max)) revert Vane__DeltaMaxTooLarge();
        if (c.deltaDustX64 >= c.deltaMaxX64) revert Vane__DeltaDustNotBelowMax();

        if (c.maxTickDelta <= 0 || c.maxTickDelta > MAX_ALLOWED_TICK_DELTA) {
            revert Vane__MaxTickDeltaOutOfRange();
        }

        validateFlowUnit(c.flowUnit);

        if (c.reserveTargetDefault == 0) revert Vane__ReserveTargetZero();

        if (c.maxEstimatorDivergenceX32 == 0) revert Vane__MaxDivergenceZero();

        if (c.routeBZScore < 2) revert Vane__RouteBZScoreTooLow();
    }

    function validateFlowUnit(uint64 flowUnit) internal pure {
        if (flowUnit < MIN_FLOW_UNIT || flowUnit > MAX_FLOW_UNIT) {
            revert Vane__FlowUnitOutOfRange();
        }
    }

    function loopGainX32(VaneConfig memory c) internal pure returns (uint256) {
        return (uint256(c.controllerGainX32) << 32) / uint256(c.controllerLeakX32);
    }
}
