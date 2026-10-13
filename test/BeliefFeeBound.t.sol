// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Deployers} from "v4-core-test/utils/Deployers.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {VaneHookHarness} from "./utils/VaneHookHarness.sol";
import {Fixtures} from "./utils/Fixtures.sol";

/// The payout must never price the favourable leg better than the market.
///
/// `deltaMaxX64` is one global parameter and used to be the only bound on the belief, so
/// nothing connected the size of the correction to the pool it was applied to. On a pool
/// whose fee sits below deltaMax, the favourable leg was then priced better than the curve
/// by `delta` while costing only `fee` — so a trader netted `delta - fee` against the true
/// market and the hook paid the difference out of reserve.
///
/// Measured before the bound: 7.53 ether of value on 1,000 of notional on a 5bp pool at a
/// 1% belief, or +0.75%. Repeating it was self-defeating, because curve slippage overtakes
/// the edge within a few trades — so this was never unbounded draining. It was the
/// protocol paying an arbitrageur once per belief, for nothing.
contract BeliefFeeBoundTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    VaneHookHarness internal hook;
    PoolKey internal cheapKey;
    PoolKey internal richKey;
    int256 internal DELTA_MAX = int256(uint256(1) << 64) / 100;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        address a = address(flags ^ (0xFEE5 << 144));
        deployCodeTo("VaneHookHarness.sol:VaneHookHarness", abi.encode(manager, Fixtures.config(), address(this)), a);
        hook = VaneHookHarness(a);

        // 5bp: fee far below deltaMax, where the edge existed.
        cheapKey = PoolKey(currency0, currency1, 500, 10, IHooks(a));
        // 100bp: fee at deltaMax, where the fee already protected.
        richKey = PoolKey(currency0, currency1, 10_000, 200, IHooks(a));

        hook.allowPool(cheapKey);
        hook.allowPool(richKey);
        manager.initialize(cheapKey, SQRT_PRICE_1_1);
        manager.initialize(richKey, SQRT_PRICE_1_1);

        MockERC20(Currency.unwrap(currency0)).mint(address(this), 1e28);
        MockERC20(Currency.unwrap(currency1)).mint(address(this), 1e28);
        MockERC20(Currency.unwrap(currency0)).approve(address(modifyLiquidityRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(modifyLiquidityRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency0)).approve(a, type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(a, type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity(cheapKey, ModifyLiquidityParams(-60000, 60000, 500_000 ether, 0), "");
        modifyLiquidityRouter.modifyLiquidity(richKey, ModifyLiquidityParams(-60000, 60000, 500_000 ether, 0), "");
        hook.fundReserve(currency0, 50_000 ether);
        hook.fundReserve(currency1, 50_000 ether);
    }

    /// Sells token0 into a positive belief, which is the leg the hook PAYS, and values the
    /// result at the pool's entry price of 1:1 — what flattening on an external venue at
    /// the true market price would realise.
    function _harvestValue(PoolKey memory k, uint256 size) internal returns (int256) {
        uint256 b0 = MockERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        uint256 b1 = MockERC20(Currency.unwrap(currency1)).balanceOf(address(this));

        swapRouter.swap(
            k,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(size), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        int256 d0 = int256(MockERC20(Currency.unwrap(currency0)).balanceOf(address(this))) - int256(b0);
        int256 d1 = int256(MockERC20(Currency.unwrap(currency1)).balanceOf(address(this))) - int256(b1);
        return d0 + d1;
    }

    /// The edge is gone: taking the paid leg on a cheap pool at a clamped belief can no
    /// longer beat the market.
    function test_NoRiskFreeEdgeOnALowFeePool() public {
        hook.setBelief(cheapKey, DELTA_MAX);

        int256 value = _harvestValue(cheapKey, 1_000 ether);
        console2.log("5bp pool, belief at deltaMax, net value to trader:", value);

        assertLe(value, 0, "the favourable leg must not be priced better than the market");
    }

    /// Across a range of trade sizes, so this is not an artefact of one size.
    function testFuzz_NoRiskFreeEdgeAtAnySize(uint96 rawSize) public {
        uint256 size = bound(uint256(rawSize), 1 ether, 20_000 ether);
        hook.setBelief(cheapKey, DELTA_MAX);

        int256 value = _harvestValue(cheapKey, size);
        assertLe(value, 0, "no trade size may extract value from the reserve");
    }

    /// The payout is bounded BY THE FEE, not merely reduced. On a 5bp pool the belief is
    /// capped at 5bp however large deltaMax is.
    function test_PayoutIsCappedAtTheFee() public {
        hook.setBelief(cheapKey, DELTA_MAX);
        uint256 r1 = hook.reserveOf(currency1);

        _harvestValue(cheapKey, 1_000 ether);
        uint256 paid = r1 - hook.reserveOf(currency1);

        // 5bp of 1,000 is 0.5; allow room for the second-order term and curve movement.
        console2.log("reserve paid on 1,000 notional at 5bp:", paid);
        assertLt(paid, 0.8 ether, "payout must track the 5bp fee, not the 1% deltaMax");
        assertGt(paid, 0, "but the mechanism must still act");
    }

    /// A pool whose fee already equals deltaMax is unaffected — the bound only binds where
    /// the fee is the smaller of the two.
    function test_HighFeePoolIsUnchanged() public {
        hook.setBelief(richKey, DELTA_MAX);
        uint256 r1 = hook.reserveOf(currency1);

        _harvestValue(richKey, 1_000 ether);
        uint256 paid = r1 - hook.reserveOf(currency1);

        console2.log("reserve paid on 1,000 notional at 100bp:", paid);
        assertGt(paid, 5 ether, "at a 100bp fee the full 1% belief still applies");
    }

    /// The TAKING side is deliberately left on deltaMax alone. There the hook collects,
    /// and a trader paying more than the fee is the correction doing its job — bounding
    /// that by the fee would halve the mechanism for no safety gain.
    function test_TakingSideIsNotFeeBounded() public {
        // A negative belief makes a token0 seller the paying party instead.
        hook.setBelief(cheapKey, -DELTA_MAX);
        uint256 r1 = hook.reserveOf(currency1);

        uint256 b1 = MockERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        swapRouter.swap(
            cheapKey,
            SwapParams({
                zeroForOne: true, amountSpecified: -1_000 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        uint256 received = MockERC20(Currency.unwrap(currency1)).balanceOf(address(this)) - b1;

        // The hook took, so the reserve grew rather than shrank.
        assertGe(hook.reserveOf(currency1), r1, "the hook collects on this side");
        // And it collected on the full belief, not a fee-sized slice.
        assertLt(received, 995 ether, "a full 1% is taken, well beyond the 5bp fee");
    }
}
