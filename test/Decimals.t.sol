// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
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
import {VaneHook} from "../src/VaneHook.sol";

/// `flowUnit` is wei per flow unit, and nothing in the contract knows a currency's
/// decimals. So the same configured value means completely different things for an
/// 18-decimal token and a 6-decimal one, and for the latter the shipped default silently
/// discards every realistic swap.
///
/// This is the mirror image of saturation. Saturation has a checked return, a sticky flag,
/// two events and an operator recovery path; this direction had none of that — the gain
/// simply stayed at zero and no observer could tell why.
contract DecimalsTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    VaneHookHarness internal hook;
    PoolKey internal usdcKey;
    PoolId internal id;

    MockERC20 internal weth;
    MockERC20 internal usdc;

    function setUp() public {
        deployFreshManagerAndRouters();

        // A realistic pair: 18-decimal base, 6-decimal quote. currency1 is the side the
        // hook measures flow on, so the quote token's decimals are what matter.
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        (MockERC20 t0, MockERC20 t1) = address(weth) < address(usdc) ? (weth, usdc) : (usdc, weth);

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        address hookAddr = address(flags ^ (0xDEC1 << 144));
        deployCodeTo(
            "VaneHookHarness.sol:VaneHookHarness", abi.encode(manager, Fixtures.config(), address(this)), hookAddr
        );
        hook = VaneHookHarness(hookAddr);

        usdcKey = PoolKey(Currency.wrap(address(t0)), Currency.wrap(address(t1)), 3000, 60, IHooks(hookAddr));
        id = usdcKey.toId();
        hook.allowPool(usdcKey);
        manager.initialize(usdcKey, SQRT_PRICE_1_1);

        t0.mint(address(this), 1e30);
        t1.mint(address(this), 1e30);
        t0.approve(address(modifyLiquidityRouter), type(uint256).max);
        t1.approve(address(modifyLiquidityRouter), type(uint256).max);
        t0.approve(address(swapRouter), type(uint256).max);
        t1.approve(address(swapRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity(usdcKey, ModifyLiquidityParams(-60000, 60000, 1e21, 0), "");
    }

    function _swap(bool zeroForOne, int256 amount) internal {
        swapRouter.swap(
            usdcKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amount,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// The arithmetic, stated as a table so the exposure is explicit per decimals.
    function test_FlowUnitMeaningDependsOnDecimals() public pure {
        uint64 shipped = 1e12;

        // Smallest swap registering one flow unit, in whole tokens.
        assertEq(shipped / 1e6, 1_000_000, "6-dec: a million tokens");
        assertEq(shipped / 1e8, 10_000, "8-dec: ten thousand tokens");
        assertEq(shipped / 1e18, 0, "18-dec: sub-token, fine");

        // Even the smallest permitted flow unit still discards a thousand USDC.
        uint64 minimum = 1e9;
        assertEq(minimum / 1e6, 1_000, "6-dec at MIN_FLOW_UNIT: a thousand tokens");
    }

    /// End to end on a real 6-decimal pool: substantial flow, zero measurement.
    function test_SixDecimalPoolMeasuresRealFlowAsZero() public {
        // 250,000 USDC a block for 60 blocks. Nobody would call this negligible.
        for (uint256 i = 0; i < 60; i++) {
            vm.roll(block.number + 1);
            _swap(i % 2 == 0, -int256(250_000 * 1e6));
        }

        console2.log("flowVarUnitsSq :", hook.poolState(id).flowVarUnitsSq);
        console2.log("kappa          :", hook.kappaOf(id));

        assertEq(hook.poolState(id).flowVarUnitsSq, 0, "the flow estimate never left zero");
        assertEq(hook.kappaOf(id), 0, "so the gain can never turn on");
    }

    /// The fix: the condition is now recorded and announced instead of being invisible.
    function test_UnmeasurableFlowIsRecordedAndAnnounced() public {
        assertFalse(hook.poolState(id).flowUnmeasurable, "clean before any swap");

        vm.recordLogs();
        vm.roll(block.number + 1);
        _swap(true, -int256(250_000 * 1e6));

        bytes32 wanted = keccak256("FlowUnmeasurable(bytes32,uint256,uint64)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == wanted) found = true;
        }

        assertTrue(found, "an operator must be told the flow unit is too large");
        assertTrue(hook.poolState(id).flowUnmeasurable, "and it must be queryable state");
    }

    /// It is emitted once on the transition, not on every swap.
    function test_AnnouncedOnceNotPerSwap() public {
        vm.roll(block.number + 1);
        _swap(true, -int256(250_000 * 1e6));
        assertTrue(hook.poolState(id).flowUnmeasurable, "precondition");

        vm.recordLogs();
        for (uint256 i = 0; i < 5; i++) {
            vm.roll(block.number + 1);
            _swap(i % 2 == 0, -int256(250_000 * 1e6));
        }

        bytes32 wanted = keccak256("FlowUnmeasurable(bytes32,uint256,uint64)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 count;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == wanted) count++;
        }
        assertEq(count, 0, "the record is sticky, so it must not re-emit");
    }

    /// Correcting the cause restores measurement, and clears the record.
    function test_CorrectFlowUnitRestoresMeasurement() public {
        vm.roll(block.number + 1);
        _swap(true, -int256(250_000 * 1e6));
        assertTrue(hook.poolState(id).flowUnmeasurable, "precondition");

        // Sized for six decimals rather than eighteen.
        uint64 sized = FlowVariance.recommendedFlowUnit(6);
        hook.allowPool(usdcKey, sized);

        assertFalse(hook.poolState(id).flowUnmeasurable, "re-allowlisting clears the record");

        for (uint256 i = 0; i < 30; i++) {
            vm.roll(block.number + 1);
            _swap(i % 2 == 0, -int256(250_000 * 1e6));
        }

        console2.log("recommended flowUnit for 6 decimals:", sized);
        console2.log("flowVarUnitsSq after correction    :", hook.poolState(id).flowVarUnitsSq);

        assertGt(hook.poolState(id).flowVarUnitsSq, 0, "flow is measurable once the unit fits the currency");
        assertFalse(hook.poolState(id).flowUnmeasurable, "and stays cleared");
    }

    /// The helper must stay inside the validated range for every plausible token.
    function testFuzz_RecommendedFlowUnitIsAlwaysValid(uint8 decimals) public pure {
        uint64 unit = FlowVariance.recommendedFlowUnit(decimals);
        assertGe(unit, 1e9, "never below MIN_FLOW_UNIT");
        assertLe(unit, 1e18, "never above MAX_FLOW_UNIT");
    }

    function test_RecommendedFlowUnitByDecimals() public pure {
        // A ten-thousandth of a token, clamped into [1e9, 1e18].
        assertEq(FlowVariance.recommendedFlowUnit(6), 1e9, "6-dec clamps to the floor");
        assertEq(FlowVariance.recommendedFlowUnit(18), 1e14, "18-dec: 0.0001 tokens");
        assertEq(FlowVariance.recommendedFlowUnit(8), 1e9, "8-dec clamps to the floor");
        assertEq(FlowVariance.recommendedFlowUnit(24), 1e18, "very high decimals clamp to the ceiling");
    }
}
