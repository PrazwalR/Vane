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

    /// The residual of converting at the block's opening price: whoever controls the last
    /// transaction of one block and the first of the next can choose that price. Here the
    /// attacker pushes the pool up in block N with exact-OUTPUT buys, which are charged
    /// exactly in currency1, and holds it across the boundary. In block N+1 the opening
    /// price is the inflated one, so exact-input buys hand the hook currency0 at that rate;
    /// the belief is then unwound for currency1 and the price put back. Converting at the
    /// opening price alone lets that pay; anchoring the reference to a slow average of
    /// opening prices means the false price has to be held for many blocks, not one.
    function testFuzz_AManipulatedOpeningCannotBeHarvested(
        uint8 rawTier,
        uint64 rawKappa,
        uint96 rawJit,
        uint16 rawRange,
        uint96 rawPush,
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

        uint160 ceiling = TickMath.getSqrtPriceAtTick(e.range - spacing);

        // Block N: push the price up, settling the belief's walk exactly in currency1.
        _swapLimited(e.k, false, int256(bound(rawPush, 1_000 ether, 200_000 ether)), ceiling);

        // Block N+1 opens at the pushed price.
        vm.roll(block.number + 1);
        _swapLimited(e.k, false, -int256(e.build), ceiling);
        for (uint256 i = 0; i < e.legs; i++) {
            _swapLimited(e.k, true, -int256(e.build / e.legs), e.start);
        }
        _closeAt(e.k, e.start);

        jit.liquidityDelta = -jit.liquidityDelta;
        modifyLiquidityRouter.modifyLiquidity(e.k, jit, "");

        (int256 attacker, int256 reserve) = _pnl(s0);
        assertLe(attacker, 0, "a price held across one block boundary must not pay the trader");
        assertGe(reserve, 0, "and must not shrink the reserve");
    }

    /// The manipulation limit, modelled with the cost that makes it a limit. The attacker
    /// holds the price up for `blocks` consecutive blocks so the slow average drifts toward
    /// it, then harvests in one transaction: JIT liquidity, exact-input buys that pay the
    /// hook currency0 at the drifted reference, sells for currency1, and the price put back.
    ///
    /// What the attacks above leave out is that a price held off the market does not stay
    /// there. An arbitrageur trades it back as the first transaction of every block, so the
    /// attacker has to push it up again as the last transaction of every block, paying the
    /// pool's fee and slippage each time. That is the cost the average is meant to impose.
    function testFuzz_AHeldPriceCannotBeHarvested(
        uint8 rawTier,
        uint64 rawKappa,
        uint16 rawBlocks,
        uint16 rawPushTicks,
        uint96 rawBuild,
        uint8 rawLegs,
        uint16 rawShallow
    ) public {
        Excursion memory e;
        e.k = keys[bound(rawTier, 0, 2)];
        e.build = bound(rawBuild, 1_000 ether, 200_000 ether);
        e.legs = bound(rawLegs, 1, 20);
        uint256 blocks = bound(rawBlocks, 1, 200);
        // A shallow pool makes holding the price cheap, which is the attacker's best case:
        // leave between 0.1% and all of the resident liquidity in place.
        uint256 removed = (10_000 ether * bound(rawShallow, 0, 999)) / 1000;
        if (removed > 0) {
            modifyLiquidityRouter.modifyLiquidity(e.k, ModifyLiquidityParams(-60000, 60000, -int256(removed), 0), "");
        }
        int24 pushTicks = int24(int256(bound(rawPushTicks, 10, 2_000)));
        hook.setKappa(e.k, uint64(bound(rawKappa, 1e4, 1e9)));

        address arb = makeAddr("arb");
        MockERC20(Currency.unwrap(currency0)).mint(arb, 1e30);
        MockERC20(Currency.unwrap(currency1)).mint(arb, 1e30);
        vm.startPrank(arb);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        vm.roll(block.number + 1);
        (e.start,,,) = manager.getSlot0(e.k.toId());
        uint160 high = TickMath.getSqrtPriceAtTick(pushTicks);
        Snap memory s0 = _snap();

        for (uint256 b = 0; b < blocks; b++) {
            vm.roll(block.number + 1);
            // First transaction of the block: the arbitrageur takes the price back. A
            // start/stop prank, because the helper's first call is a price read and a
            // one-shot prank would be spent on it.
            vm.startPrank(arb);
            _swapLimited(e.k, true, -int256(10_000_000 ether), e.start);
            vm.stopPrank();
            // Last transaction of the block: the attacker pushes it up again, with an
            // exact-output buy so the belief it walks settles exactly in currency1.
            _swapLimited(e.k, false, int256(10_000_000 ether), high);
        }

        // The harvest block. The arbitrageur still goes first.
        vm.roll(block.number + 1);
        vm.startPrank(arb);
        _swapLimited(e.k, true, -int256(10_000_000 ether), e.start);
        vm.stopPrank();

        ModifyLiquidityParams memory jit = ModifyLiquidityParams(-6000, 6000, int256(10_000_000 ether), 0);
        modifyLiquidityRouter.modifyLiquidity(e.k, jit, "");
        _swapLimited(e.k, false, -int256(e.build), TickMath.getSqrtPriceAtTick(5_000));
        for (uint256 i = 0; i < e.legs; i++) {
            _swapLimited(e.k, true, -int256(e.build / e.legs), e.start);
        }
        _closeAt(e.k, e.start);
        jit.liquidityDelta = -jit.liquidityDelta;
        modifyLiquidityRouter.modifyLiquidity(e.k, jit, "");

        (int256 attacker,) = _pnl(s0);
        assertLe(attacker, 0, "holding a price against arbitrage and harvesting it must not pay");
    }

    /// The shape the replay simulator found once a trend ran a pool past its liquidity. The
    /// pool's price sits at the minimum tick, so the next block opens at a price of about
    /// 1e-38. A buy then jumps the price through the empty ticks to the maximum, walking
    /// the belief upward, and in the block after a sell walks it back down and is paid.
    ///
    /// Converted at that opening price, the buy's currency0 collection was around 10^62 and
    /// hit an overflow guard that returned zero, so the walk was free and the sell back was
    /// paid 235 ether for it. Starting from no belief, so every unit of belief in the loop is
    /// one the loop itself built: a belief planted beforehand would be a liability nobody
    /// paid for, and being paid to unwind it is the mechanism working, not a leak.
    function testFuzz_AJumpThroughEmptyTicksIsNotFree(uint8 rawTier, uint64 rawKappa) public {
        uint24 fee = FEES[bound(rawTier, 0, 2)];
        int24 spacing = SPACINGS[bound(rawTier, 0, 2)];
        // A pool whose only liquidity is a narrow band, so the price can leave it.
        PoolKey memory k = PoolKey(currency0, currency1, fee, spacing * 2, keys[0].hooks);
        hook.allowPool(k, 1e15);
        manager.initialize(k, SQRT_PRICE_1_1);
        int24 edge = (3000 / (spacing * 2)) * (spacing * 2);
        modifyLiquidityRouter.modifyLiquidity(k, ModifyLiquidityParams(-edge, edge, 1_000_000 ether, 0), "");
        hook.setKappa(k, uint64(bound(rawKappa, 1e6, 1e9)));

        // Run the price out of the band to the minimum tick.
        vm.roll(block.number + 1);
        _swapLimited(k, true, -int256(10_000_000 ether), TickMath.MIN_SQRT_PRICE + 1);
        hook.setBelief(k, 0);

        Snap memory s0 = _snap();

        // Next block: jump to the maximum through the empty ticks.
        vm.roll(block.number + 1);
        _swapLimited(k, false, -int256(10_000_000 ether), TickMath.MAX_SQRT_PRICE - 1);
        // The block after: sell it all back.
        vm.roll(block.number + 1);
        _swapLimited(k, true, -int256(10_000_000 ether), TickMath.MIN_SQRT_PRICE + 1);

        (, int256 reserve) = _pnl(s0);
        // Valued at 1:1, the band's own price; the loop moves the same tokens out and back,
        // so what remains is the hook's offsets.
        assertGe(reserve, 0, "a loop through empty ticks must not be paid out of the reserve");
    }

    /// The property the attack above depends on, pinned directly: a price pushed in one
    /// block and held into the next does not move the reference the next block converts at,
    /// and once it does enter, it moves the average by a sixty-fourth.
    function test_TheReferenceLagsTheOpeningByABlock() public {
        PoolKey memory k = keys[1];
        PoolId pid = k.toId();

        // Block N opens at an honest price; record it, then push the price a long way up.
        vm.roll(block.number + 1);
        (, int24 openN,,) = manager.getSlot0(pid);
        _swap(k, false, -5_000 ether);
        int256 avgN = hook.openTickAverageOf(pid);
        (, int24 pushed,,) = manager.getSlot0(pid);
        assertGt(pushed, openN + 100, "precondition: the push moved the price");

        // Block N+1 opens at the pushed price. Its rollover folds in block N's opening —
        // the honest one — so the reference this block converts at has not seen the push.
        vm.roll(block.number + 1);
        _swap(k, false, -1 ether);
        int256 avgN1 = hook.openTickAverageOf(pid);
        assertEq(avgN1, _fold(avgN, openN), "the current opening must not move its own reference");

        // Block N+2's rollover folds in N+1's opening, which was the pushed price, at a
        // weight of one sixty-fourth.
        vm.roll(block.number + 1);
        _swap(k, false, -1 ether);
        assertEq(
            hook.openTickAverageOf(pid), _fold(avgN1, pushed), "it enters once a boundary has passed, at a sixty-fourth"
        );
    }

    // ------------------------------------------------------------------- helpers

    /// The hook's update of the opening-tick average, in eighths of a tick: a 1/64 step
    /// toward the folded tick, rounded to nearest.
    function _fold(int256 avgEighths, int24 tick) internal pure returns (int256) {
        return avgEighths + (((int256(tick) * 8) - avgEighths + 32) >> 6);
    }

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
        attacker = _diff(currency0.balanceOfSelf(), s.t0) + _diff(currency1.balanceOfSelf(), s.t1);
        reserve = _diff(hook.reserveOf(currency0), s.h0) + _diff(hook.reserveOf(currency1), s.h1);
    }

    /// `now - before` as a signed number, taken in unsigned arithmetic first. The test
    /// contract is minted 2^255 of each token, so casting a balance to int256 overflows as
    /// soon as it rises at all.
    function _diff(uint256 now_, uint256 before) internal pure returns (int256) {
        return now_ >= before ? int256(now_ - before) : -int256(before - now_);
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
