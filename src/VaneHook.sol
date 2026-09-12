// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BeforeSwapDelta, toBeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {CurrencySettler} from "v4-core-test/utils/CurrencySettler.sol";

import {OffsetDelta} from "./libraries/OffsetDelta.sol";
import {BeliefState} from "./libraries/BeliefState.sol";
import {KappaLib} from "./libraries/KappaLib.sol";
import {DepthLib} from "./libraries/DepthLib.sol";
import {Q64x64} from "./libraries/Q64x64.sol";
import {HorizonVariance} from "./libraries/HorizonVariance.sol";
import {FlowVariance} from "./libraries/FlowVariance.sol";
import {VarianceRatio, ControllerParams} from "./libraries/VarianceRatio.sol";
import {PoolStateLib, PoolState, PoolStateAux} from "./libraries/PoolStateLib.sol";
import {FlowAutocovariance, FlowCovState} from "./libraries/FlowAutocovariance.sol";
import {VaneConfig, VaneConfigLib} from "./config/VaneConfig.sol";

/// @title VaneHook
/// @notice A Uniswap v4 hook that applies a signed belief offset to swap execution, so
///         the pool's total price impact matches the informationally efficient impact
///         rather than the curve's mechanical impact.
/// @dev Orchestration only. Every formula lives in a pure library under src/libraries,
///      so the math is unit-testable and fuzzable without a PoolManager.
///
///      Division of labour between the callbacks, per spec section 7:
///        beforeSwap  reads state, returns the offset delta, writes nothing
///        afterSwap   samples variance, steps the controller, writes state
contract VaneHook is IHooks, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencySettler for Currency;

    error Vane__NotPoolManager();
    error Vane__PoolNotAllowlisted();
    error Vane__NotOwner();
    error Vane__OwnerIsZero();

    /// @notice Emitted once per block when the belief or the control state changes.
    event BeliefUpdated(PoolId indexed poolId, int256 deltaX64, uint256 kappaX64, uint256 varianceRatioX32);

    /// @notice Emitted when Route A and Route B disagree beyond the configured bound.
    /// @dev A large divergence means the pool is not in the Kyle equilibrium Route A
    ///      assumes, so the open-loop kappa is being computed from a model that does not
    ///      describe this pool. kappa is shrunk toward zero rather than trusted.
    event EstimatorDivergence(PoolId indexed poolId, uint256 noiseA, uint256 noiseB, uint256 divergenceX32);

    /// @notice Emitted when the reserve is too thin to back the belief at full strength.
    event BeliefScaled(PoolId indexed poolId, uint256 scaleNumerator, uint256 scaleDenominator);

    IPoolManager public immutable POOL_MANAGER;
    address public immutable OWNER;

    // Config is held as immutables rather than a storage struct: the hot path reads
    // several of these per swap, and an immutable read is free where an SLOAD is not.
    uint64 private immutable THETA_X64;
    uint64 private immutable VAR_LAMBDA_X32;
    uint64 private immutable FLOW_LAMBDA_X32;
    uint16 private immutable HORIZON_K;
    uint64 private immutable CONTROLLER_GAIN_X32;
    uint64 private immutable CONTROLLER_LEAK_X32;
    uint64 private immutable CONTROLLER_DEADBAND_X32;
    uint64 private immutable KAPPA_MAX_X64;
    uint64 private immutable DELTA_MAX_X64;
    uint64 private immutable DELTA_DUST_X64;
    int24 private immutable MAX_TICK_DELTA;
    uint64 private immutable FLOW_UNIT;
    uint128 private immutable RESERVE_TARGET_DEFAULT;
    uint64 private immutable MAX_DIVERGENCE_X32;
    uint64 private immutable ROUTE_B_Z_SCORE;

    /// @notice Packed hot state, one slot per pool. See PoolStateLib for the bit budget.
    /// @dev Internal rather than private so a test harness can drive state directly.
    ///      There is deliberately no external setter: a belief that could be written
    ///      from outside would be an operator-controlled price, which is the trust
    ///      assumption the whole design exists to avoid.
    mapping(PoolId => bytes32) internal _state;
    /// @notice Packed control state, one slot per pool.
    mapping(PoolId => bytes32) internal _aux;
    /// @notice Route B autocovariance state, one slot per pool.
    /// @dev A third slot rather than a repack: the four signed fields need 256 bits and
    ///      the other two slots have 8 spare between them. Touched only at block
    ///      boundaries, so the per-swap dust path is unaffected.
    mapping(PoolId => FlowCovState) internal _flowCov;

    /// @notice Pools this hook will attach to.
    mapping(PoolId => bool) public allowlisted;

    /// @notice Per-currency reserve target overriding the configured default. Zero
    ///         means the default applies. Eq (5.1).
    /// @dev Needed because the target is an absolute token amount and therefore
    ///      decimals-dependent: a USDC/WETH pool cannot use one number for both sides.
    mapping(Currency => uint256) public reserveTargetOf;

    modifier onlyPoolManager() {
        if (msg.sender != address(POOL_MANAGER)) revert Vane__NotPoolManager();
        _;
    }

    /// @param manager The v4 PoolManager.
    /// @param config Validated at construction; see VaneConfigLib.
    /// @param owner The account permitted to allowlist pools and set reserve targets.
    /// @dev The owner is a parameter rather than msg.sender because a hook's address
    ///      encodes its permissions, so deployment goes through a CREATE2 factory to
    ///      reach a mined address. Taking msg.sender would make the FACTORY the owner,
    ///      and the factory cannot call allowPool -- the hook would deploy cleanly,
    ///      report the right flags, and then be permanently unable to accept a pool.
    ///      Caught by deploying through the real factory in test rather than with a
    ///      salted `new`, which would have hidden it.
    constructor(IPoolManager manager, VaneConfig memory config, address owner) {
        VaneConfigLib.validate(config);
        if (owner == address(0)) revert Vane__OwnerIsZero();

        POOL_MANAGER = manager;
        OWNER = owner;

        THETA_X64 = config.thetaX64;
        VAR_LAMBDA_X32 = config.varLambdaX32;
        FLOW_LAMBDA_X32 = config.flowLambdaX32;
        HORIZON_K = config.horizonK;
        CONTROLLER_GAIN_X32 = config.controllerGainX32;
        CONTROLLER_LEAK_X32 = config.controllerLeakX32;
        CONTROLLER_DEADBAND_X32 = config.controllerDeadbandX32;
        KAPPA_MAX_X64 = config.kappaMaxX64;
        DELTA_MAX_X64 = config.deltaMaxX64;
        DELTA_DUST_X64 = config.deltaDustX64;
        MAX_TICK_DELTA = config.maxTickDelta;
        FLOW_UNIT = config.flowUnit;
        RESERVE_TARGET_DEFAULT = config.reserveTargetDefault;
        MAX_DIVERGENCE_X32 = config.maxEstimatorDivergenceX32;
        ROUTE_B_Z_SCORE = config.routeBZScore;
    }

    // ------------------------------------------------------------------
    // Administration
    // ------------------------------------------------------------------

    /// @notice Allows a pool to attach this hook. Threat 8: without an allowlist an
    ///         attacker could attach the hook to their own pool.
    function allowPool(PoolKey calldata key) external {
        if (msg.sender != OWNER) revert Vane__NotOwner();
        allowlisted[key.toId()] = true;
    }

    /// @notice Seeds the reserve with ERC-6909 claims, pulling ERC20 from the caller.
    /// @dev The reserve is held as claims inside the PoolManager so the offset path can
    ///      settle without a token transfer. Seeding therefore has to convert: pull the
    ///      ERC20 in to clear the debt, then mint the equivalent claim. Both halves must
    ///      happen inside one unlock, which is why this routes through unlockCallback.
    /// @param currency Currency to fund.
    /// @param amount Amount in token base units. The caller must have approved this
    ///        contract for at least this much.
    function fundReserve(Currency currency, uint256 amount) external {
        POOL_MANAGER.unlock(abi.encode(msg.sender, currency, amount));
    }

    /// @notice PoolManager unlock callback, used only by fundReserve.
    /// @dev Not a general-purpose entry point: it decodes exactly the fundReserve
    ///      payload and does nothing else. The PoolManager check is what makes that safe,
    ///      since only an unlock this contract initiated can reach here.
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert Vane__NotPoolManager();

        (address payer, Currency currency, uint256 amount) = abi.decode(data, (address, Currency, uint256));

        currency.settle(POOL_MANAGER, payer, amount, false);
        currency.take(POOL_MANAGER, address(this), amount, true);

        return "";
    }

    /// @notice Sets the reserve target for one currency, overriding the default.
    function setReserveTarget(Currency currency, uint256 target) external {
        if (msg.sender != OWNER) revert Vane__NotOwner();
        reserveTargetOf[currency] = target;
    }

    /// @notice The reserve backing the belief in a currency, eq (5.1).
    /// @dev The reserve is held as ERC-6909 claims inside the PoolManager, not as ERC20
    ///      balances in this contract. Settling in claims avoids a real token transfer on
    ///      every offset, which measured 21,310 gas and was the single largest line item
    ///      in the hook's worst-case cost.
    ///
    ///      Reading the claim balance directly, rather than maintaining a counter beside
    ///      it, keeps one source of truth: the claim balance is what determines whether a
    ///      burn succeeds, so it is what the solvency check must consult.
    function reserveOf(Currency currency) public view returns (uint256) {
        return POOL_MANAGER.balanceOf(address(this), currency.toId());
    }

    /// @notice The reserve target in effect for a currency.
    function targetFor(Currency currency) public view returns (uint256) {
        uint256 override_ = reserveTargetOf[currency];
        return override_ == 0 ? uint256(RESERVE_TARGET_DEFAULT) : override_;
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function beliefOf(PoolId id) external view returns (int256) {
        return PoolStateLib.unpackState(_state[id]).deltaX64;
    }

    function kappaOf(PoolId id) external view returns (uint256) {
        return PoolStateLib.unpackAux(_aux[id]).kappaX64;
    }

    function poolState(PoolId id) external view returns (PoolState memory) {
        return PoolStateLib.unpackState(_state[id]);
    }

    function poolStateAux(PoolId id) external view returns (PoolStateAux memory) {
        return PoolStateLib.unpackAux(_aux[id]);
    }

    // ------------------------------------------------------------------
    // Initialization
    // ------------------------------------------------------------------

    function beforeInitialize(address, PoolKey calldata key, uint160)
        external
        view
        override
        onlyPoolManager
        returns (bytes4)
    {
        if (!allowlisted[key.toId()]) revert Vane__PoolNotAllowlisted();
        return IHooks.beforeInitialize.selector;
    }

    /// @notice Seeds the tick baselines so the first variance sample is a real move
    ///         rather than a jump from zero.
    function afterInitialize(address, PoolKey calldata key, uint160, int24 tick)
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        PoolId id = key.toId();

        PoolState memory s;
        s.lastTick = tick;
        s.lastBlock = uint32(block.number);
        _state[id] = PoolStateLib.packState(s);

        PoolStateAux memory a;
        a.checkpointTick = tick;
        a.checkpointBlock = uint32(block.number);
        _aux[id] = PoolStateLib.packAux(a);

        return IHooks.afterInitialize.selector;
    }

    // ------------------------------------------------------------------
    // Swap path
    // ------------------------------------------------------------------

    /// @notice Applies the belief offset as a signed adjustment to the specified amount.
    /// @dev Sign convention, verified against v4-core in test/SignConvention.t.sol:
    ///      PoolManager computes `amountToSwap += hookDeltaSpecified`, so for exact input
    ///      a POSITIVE delta shrinks the swap and the hook has taken value. Positive
    ///      means the hook takes, matching v4-core's own DeltaReturningHook and opposite
    ///      to a naive reading of the specification.
    ///
    ///      No storage writes here. All mutation happens in afterSwap.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        int256 d = PoolStateLib.unpackState(_state[id]).deltaX64;
        if (d == 0) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        Currency specified = _specifiedCurrency(key, params);

        // Graceful degradation, eq (5.2). Solvency only constrains the direction in
        // which the hook PAYS: when it takes, it owes nothing and the reserve is
        // irrelevant, so the balance read is skipped entirely on that path.
        bool hookTakes = params.zeroForOne ? (d < 0) : (d > 0);
        if (!hookTakes) d = _scaleForReserve(id, d, specified);

        if (d > int256(uint256(DELTA_MAX_X64))) d = int256(uint256(DELTA_MAX_X64));
        if (d < -int256(uint256(DELTA_MAX_X64))) d = -int256(uint256(DELTA_MAX_X64));

        // Most swaps take this path: below the dust threshold the offset is not worth
        // the arithmetic or the settlement.
        if (Q64x64.abs(d) < uint256(DELTA_DUST_X64)) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        int128 hookDeltaSpecified = _computeOffset(params, d);
        if (hookDeltaSpecified == 0) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        _settleOrTake(specified, hookDeltaSpecified);

        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(hookDeltaSpecified, 0), 0);
    }

    /// @notice Samples variance, steps the control loop, and updates the belief.
    /// @dev Sampling happens once per block, never per swap. Per-swap sampling would let
    ///      an attacker move the price within a block to inflate the variance estimate
    ///      and thereby set the pool's own kappa. Invariant 8.
    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, int128)
    {
        PoolId id = key.toId();
        PoolState memory s = PoolStateLib.unpackState(_state[id]);
        PoolStateAux memory a = PoolStateLib.unpackAux(_aux[id]);

        // Signed flow in numeraire terms, positive when buying the risky asset
        // (currency0). zeroForOne sells currency0, so it is a sell.
        int256 amount1 = int256(delta.amount1());
        int256 signedNotional = params.zeroForOne ? -_abs(amount1) : _abs(amount1);
        a.flowAccum = FlowVariance.accumulate(a.flowAccum, FlowVariance.toFlowUnits(signedNotional, FLOW_UNIT));

        if (uint32(block.number) != s.lastBlock) {
            // One getSlot0 for both the tick and the price: the checkpoint needs the
            // price and the per-block sample needs the tick, and a second call would
            // re-read the same slot.
            (uint160 sqrtPriceX96, int24 tickNow,,) = POOL_MANAGER.getSlot0(id);

            s.varOneX32 = HorizonVariance.updateVarOne(s.varOneX32, tickNow, s.lastTick, MAX_TICK_DELTA, VAR_LAMBDA_X32);
            s.flowVarX32 = FlowVariance.updateFlowVar(s.flowVarX32, a.flowAccum, FLOW_LAMBDA_X32);

            int64 blockFlow = a.flowAccum;
            a.flowAccum = 0;

            _flowCov[id] = FlowAutocovariance.update(_flowCov[id], blockFlow, FLOW_LAMBDA_X32);

            s.deltaX64 = int64(BeliefState.decay(s.deltaX64, THETA_X64));
            s.lastTick = tickNow;
            s.lastBlock = uint32(block.number);

            uint256 vrX32;
            if (uint32(block.number) - a.checkpointBlock >= HORIZON_K) {
                (s, a, vrX32) = _stepHorizon(id, s, a, tickNow, sqrtPriceX96);
            }

            // Belief update from this block's flow, eq (2.7).
            s.deltaX64 = int64(
                BeliefState.update(
                    s.deltaX64, int256(uint256(a.kappaX64)), int256(blockFlow), int256(uint256(DELTA_MAX_X64))
                )
            );

            emit BeliefUpdated(id, s.deltaX64, a.kappaX64, vrX32);
        }

        _state[id] = PoolStateLib.packState(s);
        _aux[id] = PoolStateLib.packAux(a);

        return (IHooks.afterSwap.selector, int128(0));
    }

    // ------------------------------------------------------------------
    // Internal mechanics
    // ------------------------------------------------------------------

    /// @dev Runs the horizon checkpoint: updates Var(r_k), recomputes the open-loop
    ///      kappa from eq (2.5), and steps the variance-ratio controller.
    function _stepHorizon(PoolId id, PoolState memory s, PoolStateAux memory a, int24 tickNow, uint160 sqrtPriceX96)
        private
        returns (PoolState memory, PoolStateAux memory, uint256 vrX32)
    {
        // The horizon is the number of blocks that ACTUALLY elapsed, not the configured
        // K. The checkpoint fires on the first swap at or past K blocks, so on a pool
        // with sparse flow the realised horizon can be far longer than K. Dividing a
        // 100-block return by K = 20 would overstate sigma by sqrt(5) and VR by 5, both
        // of which push kappa up -- an over-correction on precisely the illiquid pools
        // least able to absorb one.
        uint256 elapsed = uint256(uint32(block.number) - a.checkpointBlock);
        uint16 horizon = elapsed > type(uint16).max ? type(uint16).max : uint16(elapsed);

        a.varKX32 =
            HorizonVariance.updateVarK(a.varKX32, tickNow, a.checkpointTick, MAX_TICK_DELTA, horizon, VAR_LAMBDA_X32);
        a.checkpointTick = tickNow;
        a.checkpointBlock = uint32(block.number);

        // Open-loop kappa, eq (2.5). sigma comes from the HORIZON variance, never the
        // per-block variance: a pool that under-reacts shows a small short-horizon
        // volatility, and deriving sigma from it makes kappa too small and fails
        // silently in the direction of doing nothing. Section 3.1.
        uint256 sigmaX64 = HorizonVariance.sigmaX64(a.varKX32, horizon);
        uint256 noiseX64 = FlowVariance.noiseScaleX64(s.flowVarX32);

        uint256 depth = DepthLib.depthX64(POOL_MANAGER.getLiquidity(id), sqrtPriceX96, FLOW_UNIT);

        uint256 openLoop = KappaLib.kappaX64(depth, sigmaX64, noiseX64, KAPPA_MAX_X64);
        openLoop = _applyDivergenceCheck(id, s.flowVarX32, openLoop);

        // A zero per-block variance yields VR = 0 from HorizonVariance, which is
        // numerically indistinguishable from extreme mean reversion and would ratchet a
        // quiet pool's gain to zero. Treat it as no signal: hold kappa at the open-loop
        // anchor rather than stepping the controller.
        if (s.varOneX32 == 0) {
            a.kappaX64 = uint64(openLoop);
            return (s, a, 0);
        }

        vrX32 = HorizonVariance.varianceRatioX32(a.varKX32, s.varOneX32, horizon);

        a.kappaX64 = uint64(
            VarianceRatio.step(
                a.kappaX64,
                openLoop,
                openLoop,
                vrX32,
                ControllerParams({
                    etaX32: CONTROLLER_GAIN_X32,
                    rhoX32: CONTROLLER_LEAK_X32,
                    deadbandX32: CONTROLLER_DEADBAND_X32,
                    kappaMaxX64: KAPPA_MAX_X64
                })
            )
        );

        return (s, a, vrX32);
    }

    /// @dev Route B cross-check, section 3.2. Route A assumes Kyle equilibrium, in which
    ///      informed and noise flow contribute exactly equally to flow variance; Route B
    ///      assumes only that noise is serially uncorrelated. A large gap means the pool
    ///      is not in the equilibrium Route A's kappa was derived under, so kappa is
    ///      shrunk toward zero rather than acted on.
    ///
    ///      Route B returning zero means it could not identify rho from the flow it has
    ///      seen, which is "no second opinion" and not evidence of disagreement, so the
    ///      open-loop kappa passes through unchanged.
    function _applyDivergenceCheck(PoolId id, uint64 flowVar, uint256 openLoop) private returns (uint256) {
        uint256 minRatio = FlowAutocovariance.minCovRatioX32(FLOW_LAMBDA_X32, ROUTE_B_Z_SCORE);
        uint256 noiseB = FlowAutocovariance.noiseScale(_flowCov[id], flowVar, minRatio);
        if (noiseB == 0) return openLoop;

        uint256 noiseA = FlowVariance.noiseScale(flowVar);
        uint256 divergence = FlowAutocovariance.divergenceX32(noiseA, noiseB);
        if (divergence <= MAX_DIVERGENCE_X32) return openLoop;

        emit EstimatorDivergence(id, noiseA, noiseB, divergence);

        // Shrink in proportion to how far past the bound the estimators disagree, so the
        // response degrades smoothly rather than switching off at a threshold.
        return (openLoop * uint256(MAX_DIVERGENCE_X32)) / divergence;
    }

    /// @dev Scales the belief down when the reserve cannot back it, eq (5.2). Never
    ///      reverts: the mechanism turns itself off and the pool degrades to plain v4.
    function _scaleForReserve(PoolId id, int256 d, Currency payCurrency) private returns (int256) {
        uint256 reserve = reserveOf(payCurrency);
        uint256 target = targetFor(payCurrency);
        if (reserve >= target) return d;

        emit BeliefScaled(id, reserve, target);
        return BeliefState.scaleForReserve(d, reserve, target);
    }

    /// @dev Computes the signed specified-token adjustment. Positive means the hook
    ///      takes value, negative means it gives value.
    function _computeOffset(SwapParams calldata params, int256 d) private pure returns (int128) {
        uint256 magnitude =
            params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);

        uint256 amount = OffsetDelta.offsetAmount(magnitude, d);
        if (amount == 0) return 0;

        // s = +1 when the swap buys the risky asset (currency0). zeroForOne sells
        // currency0, so it is a sell of the risky asset.
        bool hookTakes = params.zeroForOne ? (d < 0) : (d > 0);
        return hookTakes ? int128(int256(amount)) : -int128(int256(amount));
    }

    function _specifiedCurrency(PoolKey calldata key, SwapParams calldata params) private pure returns (Currency) {
        return (params.zeroForOne == (params.amountSpecified < 0)) ? key.currency0 : key.currency1;
    }

    /// @dev Positive delta means the hook is owed value and takes it as a claim;
    ///      negative means the hook owes value and burns a claim to settle it. The
    ///      `true` argument selects ERC-6909 claims over ERC20 movement.
    function _settleOrTake(Currency currency, int128 delta) private {
        if (delta > 0) {
            currency.take(POOL_MANAGER, address(this), uint128(delta), true);
        } else if (delta < 0) {
            currency.settle(POOL_MANAGER, address(this), uint256(-int256(delta)), true);
        }
    }

    function _abs(int256 x) private pure returns (int256) {
        return x < 0 ? -x : x;
    }

    // ------------------------------------------------------------------
    // Unused callbacks. The mined address must not enable these flags.
    // ------------------------------------------------------------------

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IHooks.afterDonate.selector;
    }
}
