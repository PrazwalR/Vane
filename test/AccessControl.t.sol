// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core-test/utils/Deployers.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {VaneHook} from "../src/VaneHook.sol";
import {VaneHookHarness} from "./utils/VaneHookHarness.sol";
import {Fixtures} from "./utils/Fixtures.sol";

contract AccessControlTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    VaneHookHarness internal hook;
    PoolKey internal vaneKey;

    address internal constant ATTACKER = address(0xBAD);

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        address hookAddr = address(flags ^ (0xAAAA << 144));
        deployCodeTo(
            "VaneHookHarness.sol:VaneHookHarness", abi.encode(manager, Fixtures.config(), address(this)), hookAddr
        );
        hook = VaneHookHarness(hookAddr);

        vaneKey = PoolKey(currency0, currency1, 3000, 60, IHooks(hookAddr));
        hook.allowPool(vaneKey);
        manager.initialize(vaneKey, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(vaneKey, ModifyLiquidityParams(-60000, 60000, 1000 ether, 0), "");
    }

    function _swapParams() internal pure returns (SwapParams memory) {
        return SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
    }

    /// beforeSwap rolls the pool into a new block, which writes the estimators, the
    /// committed belief and the reference price. It used to be an ungated no-op; anyone able
    /// to call it now could roll a block on their own schedule.
    function test_Revert_BeforeSwapFromNonManager() public {
        vm.prank(ATTACKER);
        vm.expectRevert(VaneHook.Vane__NotPoolManager.selector);
        hook.beforeSwap(ATTACKER, vaneKey, _swapParams(), "");
    }

    /// It still never alters the swap itself.
    function test_BeforeSwapReturnsNoDeltaAndNoFee() public {
        vm.roll(block.number + 1);
        vm.prank(address(manager));
        (bytes4 selector, BeforeSwapDelta d, uint24 fee) = hook.beforeSwap(ATTACKER, vaneKey, _swapParams(), "");
        assertEq(selector, IHooks.beforeSwap.selector, "selector");
        assertEq(BeforeSwapDelta.unwrap(d), 0, "must return a zero delta");
        assertEq(fee, 0, "must not override the fee");
    }

    function test_Revert_AfterSwapFromNonManager() public {
        vm.prank(ATTACKER);
        vm.expectRevert(VaneHook.Vane__NotPoolManager.selector);
        hook.afterSwap(ATTACKER, vaneKey, _swapParams(), BalanceDeltaLibrary.ZERO_DELTA, "");
    }

    function test_Revert_BeforeInitializeFromNonManager() public {
        vm.prank(ATTACKER);
        vm.expectRevert(VaneHook.Vane__NotPoolManager.selector);
        hook.beforeInitialize(ATTACKER, vaneKey, SQRT_PRICE_1_1);
    }

    function test_Revert_AfterInitializeFromNonManager() public {
        vm.prank(ATTACKER);
        vm.expectRevert(VaneHook.Vane__NotPoolManager.selector);
        hook.afterInitialize(ATTACKER, vaneKey, SQRT_PRICE_1_1, 0);
    }

    function test_Revert_UnlockCallbackFromNonManager() public {
        vm.prank(ATTACKER);
        vm.expectRevert(VaneHook.Vane__NotPoolManager.selector);
        hook.unlockCallback(abi.encode(ATTACKER, currency0, uint256(1 ether)));
    }

    function test_Revert_SetReserveTargetFromNonOwner() public {
        vm.prank(ATTACKER);
        vm.expectRevert(VaneHook.Vane__NotOwner.selector);
        hook.setReserveTarget(vaneKey, currency0, 1);
    }

    function test_Revert_AllowPoolFromNonOwner() public {
        PoolKey memory other = PoolKey(currency0, currency1, 500, 10, IHooks(address(hook)));
        vm.prank(ATTACKER);
        vm.expectRevert(VaneHook.Vane__NotOwner.selector);
        hook.allowPool(other);
    }

    function test_Revert_PoolNotAllowlistedBySelector() public {
        PoolKey memory rogue = PoolKey(currency0, currency1, 500, 10, IHooks(address(hook)));
        // PoolManager wraps hook reverts, so assert the inner selector appears in the
        // revert data rather than matching the wrapper exactly.
        try manager.initialize(rogue, SQRT_PRICE_1_1) {
            fail();
        } catch (bytes memory reason) {
            assertGt(reason.length, 0, "must revert with data");
            bool found;
            bytes4 want = VaneHook.Vane__PoolNotAllowlisted.selector;
            for (uint256 i = 0; i + 4 <= reason.length; i++) {
                if (
                    reason[i] == want[0] && reason[i + 1] == want[1] && reason[i + 2] == want[2]
                        && reason[i + 3] == want[3]
                ) {
                    found = true;
                    break;
                }
            }
            assertTrue(found, "revert must carry Vane__PoolNotAllowlisted");
        }
    }

    function testFuzz_Revert_AfterSwapFromAnyNonManager(address caller) public {
        vm.assume(caller != address(manager));
        vm.prank(caller);
        vm.expectRevert(VaneHook.Vane__NotPoolManager.selector);
        hook.afterSwap(caller, vaneKey, _swapParams(), BalanceDeltaLibrary.ZERO_DELTA, "");
    }

    /// The reserve target multiplies the belief before dividing, so an unbounded value
    /// admits a checked-multiply revert inside afterSwap — which bricks the pool — and
    /// above 2^255 an int256 cast that reinterprets the target as negative and inverts the
    /// payout direction. It is bounded to uint128 to match the configured default's type.
    function test_Revert_ReserveTargetAboveUint128() public {
        vm.expectRevert(VaneHook.Vane__ReserveTargetOutOfRange.selector);
        hook.setReserveTarget(vaneKey, currency0, uint256(type(uint128).max) + 1);
    }

    /// Zero previously meant "use the default" by way of targetFor, so an operator who
    /// intended a zero target silently got the default instead.
    function test_Revert_ReserveTargetZero() public {
        vm.expectRevert(VaneHook.Vane__ReserveTargetOutOfRange.selector);
        hook.setReserveTarget(vaneKey, currency0, 0);
    }

    /// The event reports the EFFECTIVE target. Targets are stored as a 24-bit float with a
    /// 17-bit mantissa, so a target is rounded up by at most one part in 65,536.
    function test_SetReserveTargetAnnouncesItself() public {
        vm.expectEmit(true, true, false, false, address(hook));
        emit VaneHook.ReserveTargetSet(vaneKey.toId(), currency0, 0);
        hook.setReserveTarget(vaneKey, currency0, 1234 ether);

        uint256 effective = hook.targetFor(vaneKey, currency0);
        assertGe(effective, 1234 ether, "rounding must never lower a target");
        assertApproxEqRel(effective, 1234 ether, 0.00002e18, "by at most one part in 65,536");
    }

    /// Exactly representable targets survive unchanged: anything below 2^17, and any
    /// mantissa below 2^17 times a power of two.
    function testFuzz_ReserveTargetRoundsUpAndOnlyJustUp(uint128 raw) public {
        uint256 target = bound(uint256(raw), 1, type(uint128).max);
        hook.setReserveTarget(vaneKey, currency1, target);
        uint256 effective = hook.targetFor(vaneKey, currency1);
        assertGe(effective, target, "never below what was asked for");
        assertLe(effective - target, target >> 16, "at most one part in 2^16 above it");
        if (target < 1 << 17) assertEq(effective, target, "small targets are exact");
    }

    function test_Revert_ReserveTargetForACurrencyNotInThePool() public {
        vm.expectRevert(VaneHook.Vane__CurrencyNotInPool.selector);
        hook.setReserveTarget(vaneKey, Currency.wrap(address(0xBEEF)), 1 ether);
    }

    function test_Revert_SetReserveTargetIsOwnerOnly() public {
        vm.prank(address(0xBAD));
        vm.expectRevert();
        hook.setReserveTarget(vaneKey, currency0, 1 ether);
    }
}
