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
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {VaneHook} from "../src/VaneHook.sol";
import {VaneHookHarness} from "./utils/VaneHookHarness.sol";
import {Fixtures} from "./utils/Fixtures.sol";
import {OffsetDelta} from "../src/libraries/OffsetDelta.sol";
import {BeliefState} from "../src/libraries/BeliefState.sol";
import {KappaLib} from "../src/libraries/KappaLib.sol";

contract InvariantsTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    VaneHookHarness internal hook;
    PoolKey internal vaneKey;

    int256 internal constant ONE_X64 = int256(1) << 64;

    int256 internal constant DELTA_MAX = ONE_X64 / 100;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        address hookAddr = address(flags ^ (0x5555 << 144));
        deployCodeTo(
            "VaneHookHarness.sol:VaneHookHarness", abi.encode(manager, Fixtures.config(), address(this)), hookAddr
        );
        hook = VaneHookHarness(hookAddr);

        vaneKey = PoolKey(currency0, currency1, 3000, 60, IHooks(hookAddr));
        hook.allowPool(vaneKey);
        manager.initialize(vaneKey, SQRT_PRICE_1_1);

        modifyLiquidityRouter.modifyLiquidity(vaneKey, ModifyLiquidityParams(-60000, 60000, 1000 ether, 0), "");

        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        hook.fundReserve(currency0, 10_000 ether);
        hook.fundReserve(currency1, 10_000 ether);
    }

    function testFuzz_Invariant_BeforeSwapNeverReverts(
        int256 rawDelta,
        uint128 rawAmount,
        bool zeroForOne,
        bool exactInput
    ) public {
        int256 d = bound(rawDelta, -DELTA_MAX, DELTA_MAX);

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
            assertTrue(true);
        } catch (bytes memory reason) {
            console2.log("swap reverted, delta:", d);
            console2.log("amount:", amount);
            console2.logBytes(reason);
            fail();
        }
    }

    function testFuzz_Invariant_OffsetNeverExceedsSwapAmountAtAnyScale(int256 rawDelta, uint256 rawNotional)
        public
        pure
    {
        int256 d = bound(rawDelta, -DELTA_MAX, DELTA_MAX);
        uint256 offset = OffsetDelta.offsetAmount(rawNotional, d);
        assertLe(offset, uint256(uint128(type(int128).max)), "offset must fit the int128 v4 delta at any notional");
        if (rawNotional <= OffsetDelta.MAX_NOTIONAL && rawNotional > 0) {
            assertLt(offset, rawNotional, "offset must stay below the swap amount");
        }
    }

    function testFuzz_Invariant_OffsetNeverExceedsSwapAmount(int256 rawDelta, uint128 rawNotional) public pure {
        int256 d = bound(rawDelta, -DELTA_MAX, DELTA_MAX);
        uint256 notional = bound(uint256(rawNotional), 1, type(uint128).max);

        uint256 offset = OffsetDelta.offsetAmount(notional, d);

        assertLt(offset, notional, "offset must never reach the full swap amount");
    }

    function testFuzz_TaylorFactorIsAccurate(int256 rawDelta) public pure {
        int256 d = bound(rawDelta, -DELTA_MAX, DELTA_MAX);
        int256 factor = OffsetDelta.taylorFactorX64(d);

        if (d > 0) assertGt(factor, 0, "positive belief gives positive factor");
        if (d < 0) assertLt(factor, 0, "negative belief gives negative factor");

        int256 diff = factor > d ? factor - d : d - factor;
        int256 maxDiff = (DELTA_MAX * DELTA_MAX) / (2 * ONE_X64) + 1;
        assertLe(diff, maxDiff, "second-order term must stay bounded");
    }

    function testFuzz_BeliefDecayIsContractive(int256 rawDelta, uint64 rawTheta) public pure {
        int256 d = bound(rawDelta, -DELTA_MAX, DELTA_MAX);

        uint256 theta = bound(uint256(rawTheta), 1, uint256(ONE_X64) - 1);

        int256 decayed = BeliefState.decay(d, theta);

        uint256 magBefore = d < 0 ? uint256(-d) : uint256(d);
        uint256 magAfter = decayed < 0 ? uint256(-decayed) : uint256(decayed);

        assertLe(magAfter, magBefore, "decay must not increase the belief magnitude");
        if (d > 0) assertGe(decayed, 0, "decay must not flip a positive belief negative");
        if (d < 0) assertLe(decayed, 0, "decay must not flip a negative belief positive");
    }

    function testFuzz_BeliefUpdateRespectsClamp(int256 rawDelta, int256 rawKappa, int256 rawFlow) public pure {
        int256 d = bound(rawDelta, -DELTA_MAX, DELTA_MAX);
        int256 kappa = bound(rawKappa, 0, ONE_X64 / 1000);
        int256 flow = bound(rawFlow, -1e24, 1e24);

        int256 next = BeliefState.update(d, kappa, flow, DELTA_MAX);

        assertLe(next, DELTA_MAX, "belief must not exceed the upper clamp");
        assertGe(next, -DELTA_MAX, "belief must not fall below the lower clamp");
    }

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

    function testFuzz_KappaNeverInverts(uint128 rawDepth, uint64 rawSigma, uint64 rawNoise) public pure {
        uint256 depth = bound(uint256(rawDepth), 1, type(uint128).max);
        uint256 sigma = bound(uint256(rawSigma), 0, uint256(ONE_X64));
        uint256 noise = bound(uint256(rawNoise), 1, uint256(ONE_X64) * 1000);
        uint256 kappaMax = uint256(ONE_X64) / 1000;

        uint256 k = KappaLib.kappaX64(depth, sigma, noise, kappaMax);

        assertLe(k, kappaMax, "kappa must respect its cap");
    }

    function test_KappaIsMonotoneInDepth() public pure {
        uint256 sigma = uint256(ONE_X64) / 50;
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
