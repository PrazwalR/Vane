// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core-test/utils/Deployers.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {VaneHook} from "../src/VaneHook.sol";
import {VaneHookHarness} from "./utils/VaneHookHarness.sol";
import {Fixtures} from "./utils/Fixtures.sol";

contract AccessControlTest is Test, Deployers {
    VaneHookHarness internal hook;
    PoolKey internal vaneKey;

    address internal constant ATTACKER = address(0xBAD);

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG
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

    function test_BeforeSwapIsAnUngatedNoOp() public {
        // beforeSwap carries no permission flag and returns a zero delta. It is
        // deliberately callable by anyone because it reads and writes nothing: the
        // offset moved to afterSwap, where the realized amount is known.
        vm.prank(ATTACKER);
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
        hook.setReserveTarget(currency0, 1);
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
}
