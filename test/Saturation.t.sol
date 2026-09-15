// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
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
import {FlowVariance} from "../src/libraries/FlowVariance.sol";
import {KappaLib} from "../src/libraries/KappaLib.sol";
import {PoolState, PoolStateLib} from "../src/libraries/PoolStateLib.sol";
import {Q64x64} from "../src/libraries/Q64x64.sol";

/// The replay simulator found that on any pool deep enough to be worth correcting, the flow
/// accumulator reaches its type bound within a few dozen blocks. That matters because a
/// clamped `U` and a genuinely small `U` are the same number to `lambdaStar`, so saturation
/// silently manufactures gain: sigma keeps climbing while the noise scale is pinned, and
/// kappa goes positive for a reason the market never supplied.
///
/// Every activation in the first parameter sweep was this artefact and nothing else.
contract SaturationTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    VaneHookHarness internal hook;
    PoolKey internal vaneKey;
    PoolId internal id;

    uint16 internal constant HORIZON_K = 20;
    uint64 internal constant ONE_X32_99 = uint64((uint256(99) << 32) / 100);

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        address hookAddr = address(flags ^ (0xA7A7 << 144));
        deployCodeTo(
            "VaneHookHarness.sol:VaneHookHarness", abi.encode(manager, Fixtures.config(), address(this)), hookAddr
        );
        hook = VaneHookHarness(hookAddr);

        vaneKey = PoolKey(currency0, currency1, 3000, 60, IHooks(hookAddr));
        id = vaneKey.toId();
        hook.allowPool(vaneKey);
        manager.initialize(vaneKey, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(vaneKey, ModifyLiquidityParams(-60000, 60000, 5000 ether, 0), "");

        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        hook.fundReserve(currency0, 1000 ether);
        hook.fundReserve(currency1, 1000 ether);
    }

    function _swap(bool zeroForOne, int256 amount) internal {
        swapRouter.swap(
            vaneKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amount,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// The direction of the bias, stated precisely. When the true flow variance exceeds
    /// what the slot can hold, the stored value UNDERSTATES it. A smaller `U` gives a
    /// larger `lambdaStar = sigma / 2U`, and therefore a larger gain. Saturation does not
    /// fail quietly toward doing nothing; it fails toward doing too much.
    function test_SaturationBiasesTheGainUpward() public pure {
        uint256 depth = uint256(1e13) << 64;
        uint256 sigma = (uint256(1) << 64) / 100;

        uint256 pinnedNoise = FlowVariance.noiseScaleX64(type(uint64).max);
        // What the same flow would have measured with four more bits of headroom.
        uint256 trueNoise = Q64x64.sqrt(uint256(type(uint64).max) * 16 / 2) * (uint256(1) << 64);

        uint256 pinnedGain = KappaLib.kappaX64(depth, sigma, pinnedNoise, type(uint64).max);
        uint256 honestGain = KappaLib.kappaX64(depth, sigma, trueNoise, type(uint64).max);

        assertGt(pinnedGain, honestGain, "the clamped estimate must be the one that overstates gain");
        assertTrue(FlowVariance.isSaturated(type(uint64).max), "the bound must be recognised as saturation");
        assertFalse(FlowVariance.isSaturated(type(uint64).max - 1), "one below the bound is still a measurement");
    }

    /// The variance update reports its own overflow rather than clamping in silence.
    function test_FlowVarianceReportsItsOwnSaturation() public pure {
        (uint64 big, bool sat) = FlowVariance.updateFlowVarChecked(type(uint64).max, type(int64).max, ONE_X32_99);
        assertEq(big, type(uint64).max, "must clamp rather than wrap");
        assertTrue(sat, "clamping must be reported");

        (, bool ok) = FlowVariance.updateFlowVarChecked(1e12, 1e6, ONE_X32_99);
        assertFalse(ok, "an ordinary update is not saturation");
    }

    function test_AccumulatorReportsItsOwnSaturation() public pure {
        (int64 hi, bool satHi) = FlowVariance.accumulateChecked(type(int64).max, 1);
        assertEq(hi, type(int64).max, "must clamp rather than wrap");
        assertTrue(satHi, "clamping must be reported");

        (int64 lo, bool satLo) = FlowVariance.accumulateChecked(type(int64).min, -1);
        assertEq(lo, type(int64).min, "must clamp rather than wrap");
        assertTrue(satLo, "clamping must be reported");

        (, bool ok) = FlowVariance.accumulateChecked(0, 1e9);
        assertFalse(ok, "an ordinary accumulation is not saturation");
    }

    /// A pool whose flow estimate has saturated must produce no gain at all, however long
    /// it runs and whatever the price does.
    function test_SaturatedPoolProducesNoGain() public {
        // A flowUnit far too small for this pool is exactly the misconfiguration that
        // causes saturation in the first place, and it makes the condition reachable with
        // ordinary swap sizes instead of four thousand ether.
        hook.allowPool(vaneKey, 1e9);
        hook.setVarOne(vaneKey, uint64(1 << 40));

        for (uint256 i = 0; i < HORIZON_K * 3; i++) {
            vm.roll(block.number + 1);
            _swap(i % 2 == 0, -10 ether);
        }

        assertTrue(hook.poolState(id).saturated, "the pool must record that it saturated");
        assertEq(hook.kappaOf(id), 0, "a saturated flow estimate must yield zero gain");
        assertEq(hook.beliefOf(id), 0, "with no gain there is nothing to believe");
    }

    /// Once the estimate has been corrupted the EWMA carries that level forward, so the
    /// refusal has to be sticky rather than re-evaluated from a decayed value.
    function test_SaturationDoesNotClearItself() public {
        hook.allowPool(vaneKey, 1e9);
        hook.setVarOne(vaneKey, uint64(1 << 40));

        for (uint256 i = 0; i < HORIZON_K + 2; i++) {
            vm.roll(block.number + 1);
            _swap(i % 2 == 0, -10 ether);
        }
        assertTrue(hook.poolState(id).saturated, "saturation must be recorded");

        // Quiet flow lets the EWMA decay back below the bound, but a decayed level is not
        // a recovered measurement: it still carries the corrupted history.
        hook.setFlowVar(vaneKey, uint64(1e12));
        for (uint256 i = 0; i < HORIZON_K * 2; i++) {
            vm.roll(block.number + 1);
            _swap(i % 2 == 0, -0.001 ether);
        }

        assertTrue(hook.poolState(id).saturated, "the flag must not clear itself");
        assertEq(hook.kappaOf(id), 0, "a pool that once saturated must stay disabled");
    }

    /// The recovery path is tied to fixing the cause: an operator re-allowlists with a
    /// flowUnit that fits the pool, and only then does the estimate start over.
    function test_ReallowlistingClearsSaturation() public {
        hook.allowPool(vaneKey, 1e9);
        hook.setVarOne(vaneKey, uint64(1 << 40));
        for (uint256 i = 0; i < HORIZON_K + 2; i++) {
            vm.roll(block.number + 1);
            _swap(i % 2 == 0, -10 ether);
        }
        assertTrue(hook.poolState(id).saturated, "precondition: the pool saturated");

        hook.allowPool(vaneKey, 1e15);

        assertFalse(hook.poolState(id).saturated, "a corrected flowUnit must clear the flag");
        assertEq(hook.poolState(id).flowVarX32, 0, "the corrupted level must be discarded, not carried over");
    }

    function test_OnlyOwnerCanClearSaturation() public {
        hook.allowPool(vaneKey, 1e9);
        vm.prank(address(0xBAD));
        vm.expectRevert();
        hook.allowPool(vaneKey, 1e15);
    }

    /// The flag has to survive the packing it shares a slot with.
    function testFuzz_SaturationSurvivesPacking(
        int24 lastTick,
        uint32 lastBlock,
        uint64 varOne,
        uint64 flowVar,
        int64 delta,
        bool saturated
    ) public pure {
        PoolState memory original = PoolState(lastTick, lastBlock, varOne, flowVar, delta, saturated);
        PoolState memory back = PoolStateLib.unpackState(PoolStateLib.packState(original));

        assertEq(back.lastTick, lastTick, "tick");
        assertEq(back.lastBlock, lastBlock, "block");
        assertEq(back.varOneX32, varOne, "varOne");
        assertEq(back.flowVarX32, flowVar, "flowVar");
        assertEq(back.deltaX64, delta, "delta");
        assertEq(back.saturated, saturated, "saturated");
    }

    /// The bound in wei, stated as a test so it cannot drift silently. A pool whose net
    /// per-block flow can exceed this needs a larger `flowUnit` at allowlist time.
    function test_SaturationThresholdIsDocumented() public pure {
        uint64 flowUnit = 1e12;
        uint256 maxUnits = 4_294_967_295;
        assertLt(maxUnits * maxUnits, uint256(type(uint64).max), "one below the bound must fit");
        assertGt((maxUnits + 1) * (maxUnits + 1), uint256(type(uint64).max), "one above it must not");
        assertEq(
            maxUnits * uint256(flowUnit) / 1e18,
            4294,
            "the default flowUnit saturates at about 4294 ether of net per-block flow"
        );
    }
}
