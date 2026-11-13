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
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {VaneHookHarness} from "./utils/VaneHookHarness.sol";
import {Fixtures} from "./utils/Fixtures.sol";

/// One transaction must not be able to take value out of the reserve.
///
/// Both reproductions below were live on the code this replaced. The belief moved only at
/// block boundaries, and the first swap of a block was priced BEFORE it moved — so that
/// swap created a belief at no cost, and the same actor traded back against it before the
/// block ended. The 0.30% fee did not protect, because an attacker who supplies the
/// pool's liquidity in the same transaction collects the fee they pay.
///
///  - JIT round trip, manual kappa:   +0.023 ether to the attacker out of the reserve.
///  - organic, no manual state at all: +141 ether to the attacker, 145 out of the reserve.
///
/// The fix prices every swap at the average belief across its own walk, which turns what
/// the hook collects and pays into the change of a potential. A loop that starts from no
/// belief can then leave the hook no worse off, whatever the legs, their order, their
/// exactness or the fee tier. The fuzz below asserts exactly that, closing every random
/// loop back to its starting price so the attacker's P&L is measured without any
/// inventory left to value.
contract AtomicHarvestTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    VaneHookHarness internal hook;
    PoolKey[3] internal keys;

    uint24[3] internal FEES = [uint24(500), 3000, 10_000];
    int24[3] internal SPACINGS = [int24(10), 60, 200];

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        address hookAddr = address(flags ^ (0xA70C << 144));
        deployCodeTo(
            "VaneHookHarness.sol:VaneHookHarness", abi.encode(manager, Fixtures.config(), address(this)), hookAddr
        );
        hook = VaneHookHarness(hookAddr);

        MockERC20(Currency.unwrap(currency0)).approve(hookAddr, type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(hookAddr, type(uint256).max);

        for (uint256 i = 0; i < 3; i++) {
            keys[i] = PoolKey(currency0, currency1, FEES[i], SPACINGS[i], IHooks(hookAddr));
            hook.allowPool(keys[i]);
            manager.initialize(keys[i], SQRT_PRICE_1_1);
            // Honest, wide, resident liquidity. Its fees are the only cost a JIT attacker
            // cannot recapture.
            modifyLiquidityRouter.modifyLiquidity(keys[i], ModifyLiquidityParams(-60000, 60000, 10_000 ether, 0), "");
        }

        hook.fundReserve(currency0, 100_000 ether);
        hook.fundReserve(currency1, 100_000 ether);
    }

    // ------------------------------------------------------------ the reproductions

    /// Jit.t.sol from the 2026-10-11 audit, with its assertions inverted.
    function test_JitRoundTripIsNotProfitable() public {
        PoolKey memory k = keys[1];
        hook.setKappa(k, 2e10);
        vm.roll(block.number + 1);

        Snap memory s0 = _snap();
        ModifyLiquidityParams memory jit = ModifyLiquidityParams(-600, 600, 10_000_000 ether, 0);
        modifyLiquidityRouter.modifyLiquidity(k, jit, "");

        _swap(k, true, -10 ether);
        for (uint256 i = 0; i < 40; i++) {
            _swap(k, false, -0.25 ether);
        }

        jit.liquidityDelta = -jit.liquidityDelta;
        modifyLiquidityRouter.modifyLiquidity(k, jit, "");

        (int256 attacker, int256 reserve) = _pnl(s0);
        console2.log("JIT attacker value pnl", attacker);
        console2.log("hook reserve value pnl", reserve);

        assertLe(attacker, 0, "a JIT round trip must not be value-positive");
        assertGe(reserve, 0, "and must not be paid out of the reserve");
    }

    /// Organic.t.sol from the same audit. No setKappa and no setBelief: the gain comes
    /// from 400 blocks of real flow, exactly as a live pool would produce it.
    function test_OrganicAtomicHarvestIsNotProfitable() public {
        PoolKey memory k = keys[1];
        modifyLiquidityRouter.modifyLiquidity(k, ModifyLiquidityParams(-120000, 120000, 190_000 ether, 0), "");
        for (uint256 i = 0; i < 400; i++) {
            vm.roll(block.number + 1);
            _swap(k, (i / 20) % 2 == 0, -5 ether);
            _swap(k, (i / 20) % 2 == 0, -5 ether);
        }
        assertGt(hook.kappaOf(k.toId()), 0, "the gain must be live or this proves nothing");
        vm.roll(block.number + 1);

        Snap memory s0 = _snap();
        ModifyLiquidityParams memory jit = ModifyLiquidityParams(-1200, 1200, 20_000_000 ether, 0);
        modifyLiquidityRouter.modifyLiquidity(k, jit, "");

        _swap(k, true, -60_000 ether);
        int256 built = hook.beliefOf(k.toId());
        for (uint256 i = 0; i < 40; i++) {
            _swap(k, false, -1_500 ether);
        }

        jit.liquidityDelta = -jit.liquidityDelta;
        modifyLiquidityRouter.modifyLiquidity(k, jit, "");

        (int256 attacker, int256 reserve) = _pnl(s0);
        console2.log("belief committed by the build leg", built);
        console2.log("attacker value pnl", attacker);
        console2.log("hook reserve value pnl", reserve);

        assertLe(attacker, 0, "an organic belief must not be harvestable inside one transaction");
        assertGe(reserve, 0, "and must not be paid out of the reserve");
    }

    // ------------------------------------------------------------------ the property

    /// Any loop of swaps inside one block, starting from no belief and closed back to its
    /// starting price, with the attacker supplying almost all of the liquidity: the
    /// reserve does not shrink and the attacker does not profit.
    function testFuzz_NoClosedLoopInOneBlockPaysTheTrader(uint8 rawTier, uint64 rawKappa, uint8 rawLegs, uint256 seed)
        public
    {
        PoolKey memory k = keys[bound(rawTier, 0, 2)];
        hook.setKappa(k, uint64(bound(rawKappa, 1e6, 1e12)));
        vm.roll(block.number + 1);

        (uint160 startPrice,,,) = manager.getSlot0(k.toId());
        Snap memory s0 = _snap();

        ModifyLiquidityParams memory jit = ModifyLiquidityParams(-1200, 1200, 10_000_000 ether, 0);
        modifyLiquidityRouter.modifyLiquidity(k, jit, "");

        uint256 legs = bound(rawLegs, 1, 12);
        for (uint256 i = 0; i < legs; i++) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            bool zeroForOne = seed & 1 == 1;
            bool exactIn = seed & 2 == 2;
            uint256 size = bound(seed >> 8, 1e15, 20_000 ether);
            _swap(k, zeroForOne, exactIn ? -int256(size) : int256(size));
        }

        // Close the loop at the starting price, so the attacker holds no inventory whose
        // value depends on a price assumption.
        (uint160 nowPrice,,,) = manager.getSlot0(k.toId());
        if (nowPrice != startPrice) {
            bool down = nowPrice > startPrice;
            swapRouter.swap(
                k,
                SwapParams({
                    zeroForOne: down, amountSpecified: -int256(1_000_000 ether), sqrtPriceLimitX96: startPrice
                }),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            );
        }

        jit.liquidityDelta = -jit.liquidityDelta;
        modifyLiquidityRouter.modifyLiquidity(k, jit, "");

        (int256 attacker, int256 reserve) = _pnl(s0);
        assertLe(attacker, 0, "a closed loop must not pay the trader");
        assertGe(reserve, 0, "and must not shrink the reserve");
    }

    /// The counterexample the 5,000-run campaign found before currency0 offsets were sized
    /// at the block's opening price: twelve legs, the price pushed up 1.4% by the loop's own
    /// flow, 93 ether of currency0 collected at the inflated rate and currency1 paid back.
    /// The attacker still lost, but the reserve came out 0.093 ether down.
    function test_ConversionCounterexampleIsClosed() public {
        testFuzz_NoClosedLoopInOneBlockPaysTheTrader(64, 1, 12, 12477);
    }

    /// The shape of the conversion leak, driven at it directly. The attacker supplies thin
    /// liquidity so their own flow moves the price a long way, builds the belief with
    /// exact-input buys — the hook collects currency0 while it is expensive — then sells
    /// back in currency1 and closes at the opening price. Under execution-rate conversion
    /// the currency0 collected is worth less than the potential it was charged against,
    /// by roughly the size of the excursion.
    function testFuzz_APriceExcursionCannotBeHarvested(
        uint8 rawTier,
        uint64 rawKappa,
        uint96 rawJit,
        uint16 rawRange,
        uint96 rawBuild,
        uint8 rawLegs
    ) public {
        Excursion memory e;
        e.k = keys[bound(rawTier, 0, 2)];
        int24 spacing = e.k.tickSpacing;
        e.range = int24(int256(bound(rawRange, 3, 60))) * spacing * 10;
        e.jit = bound(rawJit, 100_000 ether, 10_000_000 ether);
        e.build = bound(rawBuild, 1_000 ether, 200_000 ether);
        e.legs = bound(rawLegs, 1, 20);
        hook.setKappa(e.k, uint64(bound(rawKappa, 1e4, 1e9)));
        vm.roll(block.number + 1);

        (e.start,,,) = manager.getSlot0(e.k.toId());
        Snap memory s0 = _snap();

        ModifyLiquidityParams memory jit = ModifyLiquidityParams(-e.range, e.range, int256(e.jit), 0);
        modifyLiquidityRouter.modifyLiquidity(e.k, jit, "");

        // Build: exact-input buys, so the hook's take is in currency0 at a rising price.
        _swapLimited(e.k, false, -int256(e.build), TickMath.getSqrtPriceAtTick(e.range - spacing));

        // Harvest: exact-input sells in legs, paid in currency1, never past the open.
        for (uint256 i = 0; i < e.legs; i++) {
            _swapLimited(e.k, true, -int256(e.build / e.legs), e.start);
        }
        _closeAt(e.k, e.start);

        jit.liquidityDelta = -jit.liquidityDelta;
        modifyLiquidityRouter.modifyLiquidity(e.k, jit, "");

        (int256 attacker, int256 reserve) = _pnl(s0);
        assertLe(attacker, 0, "an excursion the trader made must not pay the trader");
        assertGe(reserve, 0, "and must not shrink the reserve");
    }

    struct Excursion {
        PoolKey k;
        int24 range;
        uint256 jit;
        uint256 build;
        uint256 legs;
        uint160 start;
    }

    function _swapLimited(PoolKey memory k, bool zeroForOne, int256 amount, uint160 limit) internal {
        (uint160 now_,,,) = manager.getSlot0(k.toId());
        if (zeroForOne ? now_ <= limit : now_ >= limit) return;
        swapRouter.swap(
            k,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: amount, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _closeAt(PoolKey memory k, uint160 target) internal {
        (uint160 now_,,,) = manager.getSlot0(k.toId());
        if (now_ == target) return;
        _swapLimited(k, now_ > target, -int256(10_000_000 ether), target);
    }

    // ------------------------------------------------------------------- helpers

    struct Snap {
        uint256 t0;
        uint256 t1;
        uint256 h0;
        uint256 h1;
    }

    function _snap() internal view returns (Snap memory s) {
        s.t0 = currency0.balanceOfSelf();
        s.t1 = currency1.balanceOfSelf();
        s.h0 = hook.reserveOf(currency0);
        s.h1 = hook.reserveOf(currency1);
    }

    /// Both legs valued at the pools' common starting price of 1:1.
    function _pnl(Snap memory s) internal view returns (int256 attacker, int256 reserve) {
        attacker =
            (int256(currency0.balanceOfSelf()) - int256(s.t0)) + (int256(currency1.balanceOfSelf()) - int256(s.t1));
        reserve =
            (int256(hook.reserveOf(currency0)) - int256(s.h0)) + (int256(hook.reserveOf(currency1)) - int256(s.h1));
    }

    function _swap(PoolKey memory k, bool zeroForOne, int256 amountSpecified) internal {
        swapRouter.swap(
            k,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }
}
