// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Every tunable the mechanism depends on. No literal in logic anywhere else.
/// @dev Scales are mixed deliberately and each field states its own; see Q64x64 for why
///      variance uses Q32.32 and the belief uses Q64.64.
struct VaneConfig {
    /// @notice Belief decay per block, Q64.64, strictly within (0, 1). Eq (2.7).
    /// @dev Must be derived from the target pool's observed arbitrage latency, per
    ///      section 12 Q4. Any value chosen before that data exists is a placeholder.
    uint64 thetaX64;
    /// @notice EWMA decay for both return variances, Q32.32, strictly within (0, 1).
    /// @dev Shared between varOne and varK on purpose: equal effective sample sizes make
    ///      the log-variance biases cancel exactly in the variance ratio.
    uint64 varLambdaX32;
    /// @notice EWMA decay for the flow variance, Q32.32, strictly within (0, 1).
    uint64 flowLambdaX32;
    /// @notice Variance-ratio horizon in blocks. Eq (3.5).
    uint16 horizonK;
    /// @notice Controller gain eta, Q32.32. Eq (3.6).
    uint64 controllerGainX32;
    /// @notice Controller leak rho toward the open-loop anchor, Q32.32, strictly positive.
    /// @dev Zero makes the controller a pure integrator, which saturates its own clamp on
    ///      noise alone. See docs/lessons/02-controller-stability.md.
    uint64 controllerLeakX32;
    /// @notice VR deviation below which the controller does not act, Q32.32.
    uint64 controllerDeadbandX32;
    /// @notice Upper clamp on kappa, Q64.64.
    uint64 kappaMaxX64;
    /// @notice Upper clamp on |delta|, Q64.64.
    uint64 deltaMaxX64;
    /// @notice Belief magnitude below which beforeSwap skips the offset entirely, Q64.64.
    uint64 deltaDustX64;
    /// @notice Absolute clamp on a per-block tick move. Invariant 8.
    int24 maxTickDelta;
    /// @notice Wei per flow unit. Flow is accumulated in these units so squaring it
    ///         cannot overflow the packed state field.
    uint64 flowUnit;
    /// @notice Default reserve at which the belief applies at full strength, in token
    ///         base units. Eq (5.1): R >= SAFETY_FACTOR * Q_max * delta_max.
    /// @dev An ABSOLUTE amount, not a ratio. An earlier draft carried a Q32.32 ratio here
    ///      and compared it against a raw token balance, which is dimensionally
    ///      meaningless and silently disabled the mechanism. Because it is absolute it is
    ///      also decimals-dependent, so a pool pairing a 6-decimal and an 18-decimal
    ///      token must override it per currency via setReserveTarget.
    uint128 reserveTargetDefault;
    /// @notice Solvency multiple over the worst-case payout, in basis points. Eq (5.1).
    uint16 safetyFactorBps;
}

/// @title VaneConfigLib
/// @notice Construction-time validation of every control parameter.
/// @dev Section 0.3 requires each parameter to carry its own error and a statement of
///      how its value was derived. Several of the bounds here are not cosmetic:
///
///        - controllerLeakX32 > 0 is a stability requirement, not a preference. A zero
///          leak makes eq (3.6) a pure integrator whose kappa random-walks into a clamp
///          on noise alone, and whose response to any persistent bias is unbounded.
///        - flowUnit has a two-sided bound. Too large and every trade truncates to zero
///          flow units, so E[y^2] stays zero, U is zero, kappa is zero, and VANE is
///          silently a no-op. Too small and the int64 accumulator saturates, capping the
///          variance estimate. Neither failure reverts.
///        - horizonK >= 2 because a variance ratio at k = 1 is identically 1 and carries
///          no information.
library VaneConfigLib {
    uint256 internal constant ONE_X32 = 1 << 32;
    uint256 internal constant ONE_X64 = 1 << 64;

    /// @dev Loosest defensible flow unit bounds. A pool whose median trade is smaller
    ///      than the flow unit records no flow at all, so the unit must sit well below
    ///      typical trade size; a unit below 1 gwei gives no headroom against the int64
    ///      accumulator for an ether-scale pool.
    uint64 internal constant MIN_FLOW_UNIT = 1e9;
    /// @dev One whole token per flow unit is the coarsest defensible setting: beyond it
    ///      even a large trade rounds to a handful of units and the variance estimate
    ///      loses all resolution. Also the largest round value that fits a uint64.
    uint64 internal constant MAX_FLOW_UNIT = 1e18;

    /// @dev A per-block move beyond this is not a price, it is a broken oracle or an
    ///      empty book. 8000 ticks is roughly a 2.2x move in one block.
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
    error Vane__DeltaDustNotBelowMax();
    error Vane__MaxTickDeltaOutOfRange();
    error Vane__FlowUnitOutOfRange();
    error Vane__ReserveTargetZero();
    error Vane__SafetyFactorTooLow();

    /// @notice Reverts unless every parameter is inside its documented range.
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
        // Bounded so eta * (VR - 1) cannot overflow the Q64.64 product in
        // VarianceRatio.step, and because a gain above 0.1 saturates the clamp on noise.
        if (uint256(c.controllerGainX32) > ONE_X32 / 10) revert Vane__ControllerGainTooLarge();

        if (c.controllerLeakX32 == 0) revert Vane__ControllerLeakZero();
        // A leak of 1.0 would snap kappa to the anchor every step, discarding the loop.
        if (uint256(c.controllerLeakX32) >= ONE_X32) revert Vane__ControllerLeakTooLarge();

        // A deadband at or above 1.0 would swallow every achievable VR deviation.
        if (uint256(c.controllerDeadbandX32) >= ONE_X32) revert Vane__DeadbandTooLarge();

        if (c.kappaMaxX64 == 0) revert Vane__KappaMaxZero();
        if (c.deltaMaxX64 == 0) revert Vane__DeltaMaxZero();
        if (c.deltaDustX64 >= c.deltaMaxX64) revert Vane__DeltaDustNotBelowMax();

        if (c.maxTickDelta <= 0 || c.maxTickDelta > MAX_ALLOWED_TICK_DELTA) {
            revert Vane__MaxTickDeltaOutOfRange();
        }

        if (c.flowUnit < MIN_FLOW_UNIT || c.flowUnit > MAX_FLOW_UNIT) {
            revert Vane__FlowUnitOutOfRange();
        }

        if (c.reserveTargetDefault == 0) revert Vane__ReserveTargetZero();
        if (c.safetyFactorBps < 10_000) revert Vane__SafetyFactorTooLow();
    }

    /// @notice The controller's steady-state loop gain eta/rho, Q32.32.
    /// @dev Surfaced from config because it, not eta alone, determines how far a
    ///      persistent VR error moves kappa. A deployer who has not looked at this
    ///      number has not chosen the controller's behaviour.
    function loopGainX32(VaneConfig memory c) internal pure returns (uint256) {
        return (uint256(c.controllerGainX32) << 32) / uint256(c.controllerLeakX32);
    }
}
