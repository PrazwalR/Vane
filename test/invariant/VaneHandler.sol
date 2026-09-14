// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {VaneHookHarness} from "../utils/VaneHookHarness.sol";

/// Drives the hook through interleavings a single-shot test cannot reach: swaps of wildly
/// varying size and direction, block rolls, liquidity added and pulled, and a reserve that
/// is drained and refilled underneath all of it.
///
/// Bounds are deliberately WIDE. The suite's previous fuzz bounds sat two to four orders of
/// magnitude below the regime where both critical bugs lived, so the properties that
/// mattered were unreachable by construction. Swap sizes here span nine orders of magnitude
/// and price limits are sometimes pinned one wei away, which is the shape of the phantom
/// notional drain.
contract VaneHandler is CommonBase, StdCheats, StdUtils {
    using PoolIdLibrary for PoolKey;

    IPoolManager public immutable manager;
    VaneHookHarness public immutable hook;
    PoolSwapTest public immutable swapRouter;
    PoolModifyLiquidityTest public immutable liquidityRouter;
    PoolKey public poolKey;
    PoolKey public otherKey;

    Currency public immutable currency0;
    Currency public immutable currency1;

    uint256 public ghostFunded0;
    uint256 public ghostFunded1;
    uint256 public ghostWithdrawn0;
    uint256 public ghostWithdrawn1;

    uint256 public swapCount;
    uint256 public revertCount;

    constructor(
        IPoolManager _manager,
        VaneHookHarness _hook,
        PoolSwapTest _swapRouter,
        PoolModifyLiquidityTest _liquidityRouter,
        PoolKey memory _poolKey,
        PoolKey memory _otherKey
    ) {
        manager = _manager;
        hook = _hook;
        swapRouter = _swapRouter;
        liquidityRouter = _liquidityRouter;
        poolKey = _poolKey;
        otherKey = _otherKey;
        currency0 = _poolKey.currency0;
        currency1 = _poolKey.currency1;
    }

    function _mintAndApprove() internal {
        MockERC20(Currency.unwrap(currency0)).mint(address(this), 1_000_000 ether);
        MockERC20(Currency.unwrap(currency1)).mint(address(this), 1_000_000 ether);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency0)).approve(address(liquidityRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(liquidityRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
    }

    /// A swap over nine orders of magnitude, either direction, either exactness mode, and
    /// occasionally with the price limit pinned next to spot so almost nothing executes.
    function swap(uint256 rawAmount, bool zeroForOne, bool exactInput, uint8 limitMode) external {
        _mintAndApprove();

        uint256 amount = bound(rawAmount, 1, 500_000 ether);
        int256 amountSpecified = exactInput ? -int256(amount) : int256(amount);

        uint160 limit;
        if (limitMode % 4 == 0) {
            (uint160 spot,,,) = _slot0();
            // One wei from spot: the shape of the phantom-notional drain.
            limit = zeroForOne ? spot - 1 : spot + 1;
        } else {
            limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        }

        swapCount++;
        try swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) {}
        catch {
            // A swap may legitimately fail on liquidity or price limits. What must never
            // happen is the HOOK reverting, which the invariants check separately via the
            // pool remaining usable.
            revertCount++;
        }
    }

    function rollBlocks(uint8 rawBlocks) external {
        vm.roll(block.number + bound(uint256(rawBlocks), 1, 64));
    }

    function addLiquidity(uint128 rawLiquidity) external {
        _mintAndApprove();
        uint256 liq = bound(uint256(rawLiquidity), 1e15, 100_000 ether);
        try liquidityRouter.modifyLiquidity(poolKey, ModifyLiquidityParams(-60000, 60000, int256(liq), 0), "") {}
            catch {}
    }

    function removeLiquidity(uint128 rawLiquidity) external {
        uint256 liq = bound(uint256(rawLiquidity), 1e15, 50_000 ether);
        try liquidityRouter.modifyLiquidity(poolKey, ModifyLiquidityParams(-60000, 60000, -int256(liq), 0), "") {}
            catch {}
    }

    function fundReserve(uint128 rawAmount, bool which) external {
        _mintAndApprove();
        uint256 amount = bound(uint256(rawAmount), 1, 10_000 ether);
        Currency c = which ? currency0 : currency1;
        try hook.fundReserve(c, amount) {
            if (which) ghostFunded0 += amount;
            else ghostFunded1 += amount;
        } catch {}
    }

    function withdrawReserve(uint128 rawAmount, bool which) external {
        Currency c = which ? currency0 : currency1;
        uint256 held = hook.reserveOf(c);
        if (held == 0) return;
        uint256 amount = bound(uint256(rawAmount), 1, held);
        try hook.withdrawReserve(c, amount, address(this)) {
            if (which) ghostWithdrawn0 += amount;
            else ghostWithdrawn1 += amount;
        } catch {}
    }

    /// Trades the second pool so cross-pool isolation is exercised under real traffic
    /// rather than against an untouched pool.
    function swapOtherPool(uint128 rawAmount, bool zeroForOne) external {
        _mintAndApprove();
        uint256 amount = bound(uint256(rawAmount), 1e12, 100 ether);
        try swapRouter.swap(
            otherKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) {}
            catch {}
    }

    function _slot0() internal view returns (uint160, int24, uint24, uint24) {
        bytes32 slot = keccak256(abi.encode(poolKey.toId(), uint256(6)));
        bytes32 data = manager.extsload(slot);
        uint160 sqrtPriceX96 = uint160(uint256(data));
        int24 tick = int24(uint24(uint256(data) >> 160));
        return (sqrtPriceX96, tick, 0, 0);
    }

    receive() external payable {}
}
