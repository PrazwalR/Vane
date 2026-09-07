// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Deployers} from "v4-core-test/utils/Deployers.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {VaneHook} from "../src/VaneHook.sol";
import {OffsetDelta} from "../src/libraries/OffsetDelta.sol";
import {BeliefState} from "../src/libraries/BeliefState.sol";
import {KappaLib} from "../src/libraries/KappaLib.sol";

/// @notice Invariants 1, 2, 4 and 5 from spec section 8, plus the arithmetic bounds
///         from the threat model. Invariant 1 is ranked most severe: a revert in
///         beforeSwap bricks the pool permanently.
contract InvariantsTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    VaneHook internal hook;
    PoolKey internal vaneKey;

    int256 internal constant ONE_X64 = int256(1) << 64;
    /// @dev delta_max = 100 bps, the spec's stated bound.
    int256 internal constant DELTA_MAX = ONE_X64 / 100;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        address hookAddr = address(flags ^ (0x5555 << 144));
        deployCodeTo("VaneHook.sol:VaneHook", abi.encode(manager), hookAddr);
        hook = VaneHook(hookAddr);

        vaneKey = PoolKey(currency0, currency1, 3000, 60, IHooks(hookAddr));
        hook.allowPool(vaneKey);
        manager.initialize(vaneKey, SQRT_PRICE_1_1);

        modifyLiquidityRouter.modifyLiquidity(vaneKey, ModifyLiquidityParams(-60000, 60000, 1000 ether, 0), "");

        deal(Currency.unwrap(currency0), address(hook), 10_000 ether);
        deal(Currency.unwrap(currency1), address(hook), 10_000 ether);
    }

    /// @notice Invariant 1: beforeSwap must not revert for any well-formed swap, at any
    ///         belief within bounds, in either direction and either exactness mode.
    function testFuzz_Invariant_BeforeSwapNeverReverts(int256 rawDelta, uint128 rawAmount, bool zeroForOne, bool exactInput)
        public
    {
        int256 d = bound(rawDelta, -DELTA_MAX, DELTA_MAX);
        // Keep the notional well inside available liquidity so the failure under test is
        // the hook, not the pool running out of range.
        uint256 amount = bound(uint256(rawAmount), 1e6, 50 ether);

        hook.setBelief(vaneKey, d);

        int256 amountSpecified = exactInput ? -int256(amount) : int256(amount);

        try swapRouter.swap(
            vaneKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) {
            // Reaching here means all hook deltas settled and NonzeroDeltaCount hit zero,
            // otherwise PoolManager would have reverted with CurrencyNotSettled.
            assertTrue(true);
        } catch (bytes memory reason) {
            console2.log("swap reverted, delta:", d);
            console2.log("amount:", amount);
            console2.logBytes(reason);
            fail();
        }
    }

    /// @notice Invariant 2: the offset must stay strictly below the swap amount, so
    ///         HookDeltaExceedsSwapAmount is unreachable within the delta_max clamp.
    function testFuzz_Invariant_OffsetNeverExceedsSwapAmount(int256 rawDelta, uint128 rawNotional) public pure {
        int256 d = bound(rawDelta, -DELTA_MAX, DELTA_MAX);
        uint256 notional = bound(uint256(rawNotional), 1, type(uint128).max / 2);

        uint256 offset = OffsetDelta.offsetAmount(notional, d);

        // |e^d - 1| < 1.02% for |d| <= 1%, so the offset is a small fraction of notional.
        assertLt(offset, notional, "offset must never reach the full swap amount");
    }

    /// @notice The Taylor factor must stay within a tight band of the true exponential
    ///         over the whole legal delta domain. Section 4.1 requires this be asserted
    ///         against a reference rather than assumed.
    function testFuzz_TaylorFactorIsAccurate(int256 rawDelta) public pure {
        int256 d = bound(rawDelta, -DELTA_MAX, DELTA_MAX);
        int256 factor = OffsetDelta.taylorFactorX64(d);

        // The factor must have the same sign as delta and be close in magnitude.
        if (d > 0) assertGt(factor, 0, "positive belief gives positive factor");
        if (d < 0) assertLt(factor, 0, "negative belief gives negative factor");

        // |factor - d| = d^2/2 <= (0.01)^2/2 = 5e-5, i.e. tiny in Q64.64 terms.
        int256 diff = factor > d ? factor - d : d - factor;
        int256 maxDiff = (DELTA_MAX * DELTA_MAX) / (2 * ONE_X64) + 1;
        assertLe(diff, maxDiff, "second-order term must stay bounded");
    }

    /// @notice Belief decay must be monotone toward zero and never change sign.
    function testFuzz_BeliefDecayIsContractive(int256 rawDelta, uint64 rawTheta) public pure {
        int256 d = bound(rawDelta, -DELTA_MAX, DELTA_MAX);
        // theta strictly inside (0,1)
        uint256 theta = bound(uint256(rawTheta), 1, uint256(ONE_X64) - 1);

        int256 decayed = BeliefState.decay(d, theta);

        uint256 magBefore = d < 0 ? uint256(-d) : uint256(d);
        uint256 magAfter = decayed < 0 ? uint256(-decayed) : uint256(decayed);

        assertLe(magAfter, magBefore, "decay must not increase the belief magnitude");
        if (d > 0) assertGe(decayed, 0, "decay must not flip a positive belief negative");
        if (d < 0) assertLe(decayed, 0, "decay must not flip a negative belief positive");
    }

    /// @notice The belief update must respect the clamp for any flow, including extremes.
    function testFuzz_BeliefUpdateRespectsClamp(int256 rawDelta, int256 rawKappa, int256 rawFlow) public pure {
        int256 d = bound(rawDelta, -DELTA_MAX, DELTA_MAX);
        int256 kappa = bound(rawKappa, 0, ONE_X64 / 1000);
        int256 flow = bound(rawFlow, -1e24, 1e24);

        int256 next = BeliefState.update(d, kappa, flow, DELTA_MAX);

        assertLe(next, DELTA_MAX, "belief must not exceed the upper clamp");
        assertGe(next, -DELTA_MAX, "belief must not fall below the lower clamp");
    }

    /// @notice Reserve scaling implements graceful degradation, eq (5.2): as the reserve
    ///         drains, the belief shrinks toward zero rather than the hook reverting.
    function testFuzz_ReserveScalingDegradesGracefully(int256 rawDelta, uint128 rawReserve, uint128 rawTarget)
        public
        pure
    {
        int256 d = bound(rawDelta, -DELTA_MAX, DELTA_MAX);
        uint256 target = bound(uint256(rawTarget), 1, 1e30);
        uint256 reserve = bound(uint256(rawReserve), 0, 1e30);

        int256 scaled = BeliefState.scaleForReserve(d, reserve, target);

        uint256 magOriginal = d < 0 ? uint256(-d) : uint256(d);
        uint256 magScaled = scaled < 0 ? uint256(-scaled) : uint256(scaled);

        assertLe(magScaled, magOriginal, "scaling must never amplify the belief");
        if (reserve == 0) assertEq(scaled, 0, "an empty reserve must fully disable the belief");
    }

    /// @notice kappa is clamped at zero and never inverts. An inverted kappa would make
    ///         the pool subsidise flow trading against the belief.
    function testFuzz_KappaNeverInverts(uint128 rawDepth, uint64 rawSigma, uint64 rawNoise) public pure {
        uint256 depth = bound(uint256(rawDepth), 1, type(uint128).max);
        uint256 sigma = bound(uint256(rawSigma), 0, uint256(ONE_X64));
        uint256 noise = bound(uint256(rawNoise), 1, uint256(ONE_X64) * 1000);
        uint256 kappaMax = uint256(ONE_X64) / 1000;

        uint256 k = KappaLib.kappaX64(depth, sigma, noise, kappaMax);

        assertLe(k, kappaMax, "kappa must respect its cap");
    }

    /// @notice kappa must increase with depth, eq (2.5): the correction scales with the
    ///         disease. This is the structural property the whole thesis rests on.
    function test_KappaIsMonotoneInDepth() public pure {
        uint256 sigma = uint256(ONE_X64) / 50; // 2% per block
        uint256 noise = uint256(ONE_X64) * 5;
        uint256 kappaMax = type(uint64).max;

        uint256 prev = 0;
        for (uint256 i = 1; i <= 20; i++) {
            uint256 depth = uint256(ONE_X64) * 500 * i;
            uint256 k = KappaLib.kappaX64(depth, sigma, noise, kappaMax);
            assertGe(k, prev, "kappa must be non-decreasing in depth");
            prev = k;
        }
        assertGt(prev, 0, "kappa must become positive for deep pools");
    }
}
