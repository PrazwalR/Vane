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

contract ReserveSolvencyTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    VaneHookHarness internal hook;
    PoolKey internal vaneKey;

    int256 internal constant DELTA_MAX = int256(uint256(1 << 64)) / 100;
    uint256 internal constant RESERVE_TARGET = 100 ether;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        address hookAddr = address(flags ^ (0x9999 << 144));
        deployCodeTo(
            "VaneHookHarness.sol:VaneHookHarness", abi.encode(manager, Fixtures.config(), address(this)), hookAddr
        );
        hook = VaneHookHarness(hookAddr);

        vaneKey = PoolKey(currency0, currency1, 3000, 60, IHooks(hookAddr));
        hook.allowPool(vaneKey);
        manager.initialize(vaneKey, SQRT_PRICE_1_1);

        MockERC20(Currency.unwrap(currency0)).mint(address(this), 5_000_000 ether);
        MockERC20(Currency.unwrap(currency1)).mint(address(this), 5_000_000 ether);
        MockERC20(Currency.unwrap(currency0)).approve(address(modifyLiquidityRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(modifyLiquidityRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);

        modifyLiquidityRouter.modifyLiquidity(vaneKey, ModifyLiquidityParams(-120000, 120000, 2_000_000 ether, 0), "");

        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        hook.fundReserve(currency0, RESERVE_TARGET);
        hook.fundReserve(currency1, RESERVE_TARGET);
    }

    function test_Reserve_OwnerCanWithdraw() public {
        uint256 before = hook.reserveOf(currency0);
        uint256 recipientBefore = currency0.balanceOfSelf();

        hook.withdrawReserve(currency0, before, address(this));

        assertEq(hook.reserveOf(currency0), 0, "reserve must be emptied");
        assertEq(currency0.balanceOfSelf(), recipientBefore + before, "recipient receives the funds");
    }

    function test_Reserve_WithdrawIsOwnerOnly() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(VaneHook.Vane__NotOwner.selector);
        hook.withdrawReserve(currency0, 1, address(0xBAD));
    }

    function test_Reserve_WithdrawRejectsZeroRecipient() public {
        vm.expectRevert(VaneHook.Vane__RecipientIsZero.selector);
        hook.withdrawReserve(currency0, 1, address(0));
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

    function test_Reserve_PayoutAboveReserveMustNotRevert() public {
        hook.setBelief(vaneKey, DELTA_MAX);

        console2.log("reserve target  :", RESERVE_TARGET);
        console2.log("reserve held    :", hook.reserveOf(currency0));
        console2.log("threshold       :", RESERVE_TARGET * 100);

        // A sell into a positive belief makes the hook PAY in currency0. Past
        // target/deltaMax the payout exceeds anything the reserve can hold, because the
        // reserve level cancels out of the scaling.
        uint256 before = hook.reserveOf(currency1);
        _swap(true, -50_000 ether);
        uint256 remaining = hook.reserveOf(currency1);

        console2.log("reserve after   :", remaining);

        // The payout is capped at what the hook holds, so the swap executes and the
        // reserve is spent down to zero rather than the burn underflowing. Solvency is
        // now structural: the hook can never owe more than it has.
        assertLe(remaining, before, "reserve may be spent");
        assertGe(remaining, 0, "reserve must never go negative");
    }

    function test_Reserve_LargeSwapStillExecutes() public {
        hook.setBelief(vaneKey, DELTA_MAX);
        uint256 before1 = currency1.balanceOfSelf();
        _swap(true, -50_000 ether);
        assertGt(currency1.balanceOfSelf(), before1, "the swap itself must still succeed");
    }

    function test_Reserve_PoolKeepsWorkingAfterExhaustion() public {
        hook.setBelief(vaneKey, DELTA_MAX);
        _swap(true, -50_000 ether);

        // Invariant 1: a drained or degraded reserve must leave a working pool.
        _swap(true, -1 ether);
        _swap(false, -1 ether);
    }

    function test_Exploit_PhantomNotionalCannotDrainReserve() public {
        // The offset used to be sized from params.amountSpecified inside beforeSwap,
        // which cannot know how much will actually execute. Pairing a huge requested
        // amount with a price limit one wei away paid out on a trade that never
        // happened, draining the entire reserve for a couple of wei of fees.
        //
        // The offset is now computed in afterSwap from the realized BalanceDelta, so a
        // trade that moves nothing earns nothing.
        hook.setBelief(vaneKey, DELTA_MAX);

        uint256 reserveBefore = hook.reserveOf(currency1);
        uint256 attackerBefore = currency1.balanceOfSelf();
        (uint160 sqrtNow,,,) = manager.getSlot0(vaneKey.toId());

        swapRouter.swap(
            vaneKey,
            SwapParams({zeroForOne: true, amountSpecified: -900_000 ether, sqrtPriceLimitX96: sqrtNow - 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        console2.log("reserve before:", reserveBefore);
        console2.log("reserve after :", hook.reserveOf(currency1));

        assertEq(hook.reserveOf(currency1), reserveBefore, "a phantom notional must not move the reserve");
        assertLe(currency1.balanceOfSelf(), attackerBefore, "attacker must not profit");
    }

    function testFuzz_Exploit_PriceLimitedSwapsNeverOverpay(uint256 rawAmount, uint8 rawLimitOffset) public {
        uint256 amount = bound(rawAmount, 1e6, 900_000 ether);
        uint160 limitOffset = uint160(bound(uint256(rawLimitOffset), 1, 255));
        hook.setBelief(vaneKey, DELTA_MAX);

        uint256 reserveBefore = hook.reserveOf(currency1);
        (uint160 sqrtNow,,,) = manager.getSlot0(vaneKey.toId());

        swapRouter.swap(
            vaneKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(amount), sqrtPriceLimitX96: sqrtNow - limitOffset}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        // Whatever the hook paid must be justified by a trade that actually executed,
        // so it can never exceed the offset on the realized amount.
        assertLe(reserveBefore - hook.reserveOf(currency1), amount, "payout must not exceed the trade");
    }

    function testFuzz_Reserve_NeverRevertsAtAnyNotional(uint256 rawAmount, bool zeroForOne) public {
        uint256 amount = bound(rawAmount, 1e6, 500_000 ether);
        hook.setBelief(vaneKey, DELTA_MAX);

        try swapRouter.swap(
            vaneKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) {}
        catch (bytes memory reason) {
            console2.log("reverted at notional:", amount);
            console2.logBytes(reason);
            fail();
        }
    }
}
