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

contract VaneHook is IHooks, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencySettler for Currency;

    error Vane__NotPoolManager();
    error Vane__PoolNotAllowlisted();
    error Vane__NotOwner();
    error Vane__OwnerIsZero();
    error Vane__UnexpectedCallbackReturn();

    event BeliefUpdated(PoolId indexed poolId, int256 deltaX64, uint256 kappaX64, uint256 varianceRatioX32);

    event EstimatorDivergence(PoolId indexed poolId, uint256 noiseA, uint256 noiseB, uint256 divergenceX32);

    event BeliefScaled(PoolId indexed poolId, uint256 scaleNumerator, uint256 scaleDenominator);

    IPoolManager public immutable POOL_MANAGER;
    address public immutable OWNER;

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

    mapping(PoolId => bytes32) internal _state;

    mapping(PoolId => bytes32) internal _aux;

    mapping(PoolId => FlowCovState) internal _flowCov;

    mapping(PoolId => bool) public allowlisted;

    mapping(Currency => uint256) public reserveTargetOf;

    modifier onlyPoolManager() {
        if (msg.sender != address(POOL_MANAGER)) revert Vane__NotPoolManager();
        _;
    }

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

    function allowPool(PoolKey calldata key) external {
        if (msg.sender != OWNER) revert Vane__NotOwner();
        allowlisted[key.toId()] = true;
    }

    function fundReserve(Currency currency, uint256 amount) external {
        bytes memory result = POOL_MANAGER.unlock(abi.encode(msg.sender, currency, amount));
        if (result.length != 0) revert Vane__UnexpectedCallbackReturn();
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert Vane__NotPoolManager();

        (address payer, Currency currency, uint256 amount) = abi.decode(data, (address, Currency, uint256));

        currency.settle(POOL_MANAGER, payer, amount, false);
        currency.take(POOL_MANAGER, address(this), amount, true);

        return "";
    }

    function setReserveTarget(Currency currency, uint256 target) external {
        if (msg.sender != OWNER) revert Vane__NotOwner();
        reserveTargetOf[currency] = target;
    }

    function reserveOf(Currency currency) public view returns (uint256) {
        return POOL_MANAGER.balanceOf(address(this), currency.toId());
    }

    function targetFor(Currency currency) public view returns (uint256) {
        uint256 override_ = reserveTargetOf[currency];
        return override_ == 0 ? uint256(RESERVE_TARGET_DEFAULT) : override_;
    }

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

        bool hookTakes = params.zeroForOne ? (d < 0) : (d > 0);
        if (!hookTakes) d = _scaleForReserve(id, d, specified);

        if (d > int256(uint256(DELTA_MAX_X64))) d = int256(uint256(DELTA_MAX_X64));
        if (d < -int256(uint256(DELTA_MAX_X64))) d = -int256(uint256(DELTA_MAX_X64));

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

    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, int128)
    {
        PoolId id = key.toId();
        PoolState memory s = PoolStateLib.unpackState(_state[id]);
        PoolStateAux memory a = PoolStateLib.unpackAux(_aux[id]);

        int256 amount1 = int256(delta.amount1());
        int256 signedNotional = params.zeroForOne ? -_abs(amount1) : _abs(amount1);
        a.flowAccum = FlowVariance.accumulate(a.flowAccum, FlowVariance.toFlowUnits(signedNotional, FLOW_UNIT));

        if (uint32(block.number) != s.lastBlock) {
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

    function _stepHorizon(PoolId id, PoolState memory s, PoolStateAux memory a, int24 tickNow, uint160 sqrtPriceX96)
        private
        returns (PoolState memory, PoolStateAux memory, uint256 vrX32)
    {
        uint256 elapsed = uint256(uint32(block.number) - a.checkpointBlock);
        uint16 horizon = elapsed > type(uint16).max ? type(uint16).max : uint16(elapsed);

        a.varKX32 =
            HorizonVariance.updateVarK(a.varKX32, tickNow, a.checkpointTick, MAX_TICK_DELTA, horizon, VAR_LAMBDA_X32);
        a.checkpointTick = tickNow;
        a.checkpointBlock = uint32(block.number);

        uint256 sigmaX64 = HorizonVariance.sigmaX64(a.varKX32, horizon);
        uint256 noiseX64 = FlowVariance.noiseScaleX64(s.flowVarX32);

        uint256 depth = DepthLib.depthX64(POOL_MANAGER.getLiquidity(id), sqrtPriceX96, FLOW_UNIT);

        uint256 openLoop = KappaLib.kappaX64(depth, sigmaX64, noiseX64, KAPPA_MAX_X64);
        openLoop = _applyDivergenceCheck(id, s.flowVarX32, openLoop);

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

    function _applyDivergenceCheck(PoolId id, uint64 flowVar, uint256 openLoop) private returns (uint256) {
        uint256 minRatio = FlowAutocovariance.minCovRatioX32(FLOW_LAMBDA_X32, ROUTE_B_Z_SCORE);
        uint256 noiseB = FlowAutocovariance.noiseScale(_flowCov[id], flowVar, minRatio);
        if (noiseB == 0) return openLoop;

        uint256 noiseA = FlowVariance.noiseScale(flowVar);
        uint256 divergence = FlowAutocovariance.divergenceX32(noiseA, noiseB);
        if (divergence <= MAX_DIVERGENCE_X32) return openLoop;

        emit EstimatorDivergence(id, noiseA, noiseB, divergence);

        return (openLoop * uint256(MAX_DIVERGENCE_X32)) / divergence;
    }

    function _scaleForReserve(PoolId id, int256 d, Currency payCurrency) private returns (int256) {
        uint256 reserve = reserveOf(payCurrency);
        uint256 target = targetFor(payCurrency);
        if (reserve >= target) return d;

        emit BeliefScaled(id, reserve, target);
        return BeliefState.scaleForReserve(d, reserve, target);
    }

    function _computeOffset(SwapParams calldata params, int256 d) private pure returns (int128) {
        uint256 magnitude =
            params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);

        uint256 amount = OffsetDelta.offsetAmount(magnitude, d);
        if (amount == 0) return 0;

        bool hookTakes = params.zeroForOne ? (d < 0) : (d > 0);
        return hookTakes ? int128(int256(amount)) : -int128(int256(amount));
    }

    function _specifiedCurrency(PoolKey calldata key, SwapParams calldata params) private pure returns (Currency) {
        return (params.zeroForOne == (params.amountSpecified < 0)) ? key.currency0 : key.currency1;
    }

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
