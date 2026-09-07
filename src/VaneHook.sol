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
import {CurrencySettler} from "v4-core-test/utils/CurrencySettler.sol";

import {OffsetDelta} from "./libraries/OffsetDelta.sol";
import {BeliefState} from "./libraries/BeliefState.sol";

/// @title VaneHook
/// @notice A Uniswap v4 hook that applies a signed belief offset to swap execution,
///         so the pool's total price impact matches the informationally efficient
///         impact rather than the curve's mechanical impact.
/// @dev Orchestration only. All arithmetic lives in the pure libraries under
///      src/libraries, so the math is unit-testable without a PoolManager.
contract VaneHook is IHooks {
    using PoolIdLibrary for PoolKey;
    using CurrencySettler for Currency;

    error Vane__NotPoolManager();
    error Vane__PoolNotAllowlisted();

    /// @notice Emitted when the belief offset is applied to a swap.
    event BeliefApplied(PoolId indexed poolId, int256 deltaX64, int128 hookDeltaSpecified);

    IPoolManager public immutable POOL_MANAGER;

    /// @notice Belief offset per pool, Q64.64 log-price units.
    mapping(PoolId => int256) public deltaX64;

    /// @notice Pools this hook will attach to.
    mapping(PoolId => bool) public allowlisted;

    modifier onlyPoolManager() {
        if (msg.sender != address(POOL_MANAGER)) revert Vane__NotPoolManager();
        _;
    }

    constructor(IPoolManager manager) {
        POOL_MANAGER = manager;
    }

    /// @notice Sets the belief offset for a pool.
    /// @dev Test/experiment surface for driving the belief directly. A production
    ///      build derives this from flow inside afterSwap; kept explicit here so the
    ///      sign convention can be proven in isolation.
    function setBelief(PoolKey calldata key, int256 newDeltaX64) external {
        deltaX64[key.toId()] = newDeltaX64;
    }

    function allowPool(PoolKey calldata key) external {
        allowlisted[key.toId()] = true;
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

    function afterInitialize(address, PoolKey calldata, uint160, int24)
        external
        pure
        override
        returns (bytes4)
    {
        return IHooks.afterInitialize.selector;
    }

    /// @notice Applies the belief offset as a signed adjustment to the specified amount.
    /// @dev Sign convention, verified against v4-core in test/SignConvention.t.sol:
    ///      PoolManager computes `amountToSwap += hookDeltaSpecified`. For exact input
    ///      (amountSpecified < 0), a POSITIVE hookDeltaSpecified shrinks the swap, which
    ///      means the hook has taken value. So positive == hook takes, matching
    ///      v4-core's own DeltaReturningHook, and opposite to a naive reading.
    ///
    ///      With delta > 0 the risky asset is believed underpriced by the curve, so a
    ///      buyer must pay more: the hook takes. s = +1 for a buy, so the hook's take is
    ///      positive when s * delta > 0.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        int256 d = deltaX64[key.toId()];
        if (d == 0) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        int128 hookDeltaSpecified = _computeOffset(params, d);
        if (hookDeltaSpecified == 0) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        _settleOrTake(_specifiedCurrency(key, params), hookDeltaSpecified);

        emit BeliefApplied(key.toId(), d, hookDeltaSpecified);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(hookDeltaSpecified, 0), 0);
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        pure
        override
        returns (bytes4, int128)
    {
        return (IHooks.afterSwap.selector, int128(0));
    }

    /// @dev Computes the signed specified-token adjustment for this swap.
    ///      Positive means the hook takes value, negative means it gives value.
    function _computeOffset(SwapParams calldata params, int256 d) internal pure returns (int128) {
        uint256 magnitude = params.amountSpecified < 0
            ? uint256(-params.amountSpecified)
            : uint256(params.amountSpecified);

        uint256 amount = OffsetDelta.offsetAmount(magnitude, d);
        if (amount == 0) return 0;

        // s = +1 when the swap buys the risky asset (currency0 treated as risky).
        // zeroForOne == true sells currency0, so it is a sell of the risky asset.
        bool hookTakes = params.zeroForOne ? (d < 0) : (d > 0);
        return hookTakes ? int128(int256(amount)) : -int128(int256(amount));
    }

    function _specifiedCurrency(PoolKey calldata key, SwapParams calldata params)
        internal
        pure
        returns (Currency specified)
    {
        specified = (params.zeroForOne == (params.amountSpecified < 0)) ? key.currency0 : key.currency1;
    }

    /// @dev Positive delta means the hook is owed value and takes it; negative means
    ///      the hook owes value and settles it.
    function _settleOrTake(Currency currency, int128 delta) internal {
        if (delta > 0) {
            currency.take(POOL_MANAGER, address(this), uint128(delta), false);
        } else if (delta < 0) {
            currency.settle(POOL_MANAGER, address(this), uint256(-int256(delta)), false);
        }
    }

    // Unused callbacks. The mined address must not enable these flags.

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

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
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
