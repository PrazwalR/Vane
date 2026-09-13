// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Deployers} from "v4-core-test/utils/Deployers.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {VaneHook} from "../src/VaneHook.sol";
import {VaneHookHarness} from "./utils/VaneHookHarness.sol";
import {Fixtures} from "./utils/Fixtures.sol";
import {VaneConfigLib} from "../src/config/VaneConfig.sol";

contract HardeningTest is Test, Deployers {
    using StateLibrary for IPoolManager;

    VaneHookHarness internal hook;
    PoolKey internal vaneKey;
    PoolId internal id;

    address internal constant ATTACKER = address(0xBAD);
    address internal constant NEW_OWNER = address(0xB0B);

    int256 internal constant DELTA_100BPS = int256(uint256(1 << 64)) / 100;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        address hookAddr = address(flags ^ (0xC0DE << 144));
        deployCodeTo(
            "VaneHookHarness.sol:VaneHookHarness", abi.encode(manager, Fixtures.config(), address(this)), hookAddr
        );
        hook = VaneHookHarness(hookAddr);

        vaneKey = PoolKey(currency0, currency1, 3000, 60, IHooks(hookAddr));
        id = vaneKey.toId();
        hook.allowPool(vaneKey);
        manager.initialize(vaneKey, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(vaneKey, ModifyLiquidityParams(-60000, 60000, 1000 ether, 0), "");

        MockERC20(Currency.unwrap(currency0)).mint(address(this), 10_000_000 ether);
        MockERC20(Currency.unwrap(currency1)).mint(address(this), 10_000_000 ether);
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        hook.fundReserve(currency0, 5_000 ether);
        hook.fundReserve(currency1, 5_000 ether);
    }

    function _swap(bool z, int256 amt) internal {
        swapRouter.swap(
            vaneKey,
            SwapParams({
                zeroForOne: z,
                amountSpecified: amt,
                sqrtPriceLimitX96: z ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    // ---------------------------------------------------------------- ownership

    function test_Ownership_IsTwoStep() public {
        assertEq(hook.owner(), address(this), "deployer owns the hook");

        hook.transferOwnership(NEW_OWNER);
        assertEq(hook.owner(), address(this), "transfer must not take effect until accepted");
        assertEq(hook.pendingOwner(), NEW_OWNER, "pending owner recorded");

        vm.prank(NEW_OWNER);
        hook.acceptOwnership();
        assertEq(hook.owner(), NEW_OWNER, "ownership moved");
        assertEq(hook.pendingOwner(), address(0), "pending cleared");
    }

    function test_Revert_AcceptFromNonPendingOwner() public {
        hook.transferOwnership(NEW_OWNER);
        vm.prank(ATTACKER);
        vm.expectRevert(VaneHook.Vane__NotOwner.selector);
        hook.acceptOwnership();
    }

    function test_Revert_AcceptWithNoPendingTransfer() public {
        vm.prank(ATTACKER);
        vm.expectRevert(VaneHook.Vane__NotOwner.selector);
        hook.acceptOwnership();
    }

    function test_Ownership_TransferCanBeCancelled() public {
        hook.transferOwnership(NEW_OWNER);
        hook.transferOwnership(address(0));

        vm.prank(NEW_OWNER);
        vm.expectRevert(VaneHook.Vane__NotOwner.selector);
        hook.acceptOwnership();
    }

    function test_Revert_TransferOwnershipFromNonOwner() public {
        vm.prank(ATTACKER);
        vm.expectRevert(VaneHook.Vane__NotOwner.selector);
        hook.transferOwnership(ATTACKER);
    }

    function test_OldOwnerLosesPowersAfterHandover() public {
        hook.transferOwnership(NEW_OWNER);
        vm.prank(NEW_OWNER);
        hook.acceptOwnership();

        vm.expectRevert(VaneHook.Vane__NotOwner.selector);
        hook.setReserveTarget(currency0, 1);
    }

    // ---------------------------------------------------------------- allowlist

    function test_DisallowPool_DisablesTheOffsetWithoutBrickingSwaps() public {
        hook.setBelief(vaneKey, DELTA_100BPS);

        uint256 reserveBefore = hook.reserveOf(currency0);
        hook.disallowPool(vaneKey);
        assertFalse(hook.allowlisted(id), "pool is off the allowlist");

        // swaps still succeed, they simply carry no belief offset
        _swap(true, -1 ether);

        assertEq(hook.reserveOf(currency0), reserveBefore, "a disallowed pool must not draw on the reserve");
    }

    function test_Revert_DisallowPoolFromNonOwner() public {
        vm.prank(ATTACKER);
        vm.expectRevert(VaneHook.Vane__NotOwner.selector);
        hook.disallowPool(vaneKey);
    }

    // ---------------------------------------------------------------- flow unit

    function test_FlowUnit_DefaultsToConfigAndIsOverridablePerPool() public {
        assertEq(hook.flowUnitOf(id), Fixtures.config().flowUnit, "defaults to the global unit");

        PoolKey memory sixDecimals = PoolKey(currency0, currency1, 500, 10, IHooks(address(hook)));
        hook.allowPool(sixDecimals, 1e9);
        assertEq(hook.flowUnitOf(sixDecimals.toId()), 1e9, "per-pool override applies");
        assertEq(hook.flowUnitOf(id), Fixtures.config().flowUnit, "other pools are untouched");
    }

    function test_Revert_PerPoolFlowUnitOutOfRange() public {
        PoolKey memory k = PoolKey(currency0, currency1, 500, 10, IHooks(address(hook)));
        vm.expectRevert(VaneConfigLib.Vane__FlowUnitOutOfRange.selector);
        hook.allowPool(k, 1);
    }

    function test_Revert_PerPoolFlowUnitFromNonOwner() public {
        PoolKey memory k = PoolKey(currency0, currency1, 500, 10, IHooks(address(hook)));
        vm.prank(ATTACKER);
        vm.expectRevert(VaneHook.Vane__NotOwner.selector);
        hook.allowPool(k, 1e12);
    }

    // ---------------------------------------------------------------- native ETH

    function test_Revert_NativeValueMismatch() public {
        vm.deal(address(this), 10 ether);
        vm.expectRevert(VaneHook.Vane__NativeValueMismatch.selector);
        hook.fundReserve{value: 1 ether}(Currency.wrap(address(0)), 2 ether);
    }

    function test_Revert_UnexpectedNativeValueOnErc20Funding() public {
        vm.deal(address(this), 10 ether);
        vm.expectRevert(VaneHook.Vane__UnexpectedNativeValue.selector);
        hook.fundReserve{value: 1 ether}(currency0, 1 ether);
    }

    // ---------------------------------------------------------------- reserve

    function test_Revert_WithdrawToZeroAddress() public {
        vm.expectRevert(VaneHook.Vane__RecipientIsZero.selector);
        hook.withdrawReserve(currency0, 1 ether, address(0));
    }

    function test_Revert_WithdrawFromNonOwner() public {
        vm.prank(ATTACKER);
        vm.expectRevert(VaneHook.Vane__NotOwner.selector);
        hook.withdrawReserve(currency0, 1 ether, ATTACKER);
    }

    // ------------------------------------------------- belief harvesting (finding 5)

    /// An attacker pushes flow one way in block N, then in a single transaction in block
    /// N+1 triggers the belief update with a dust swap and immediately trades back the
    /// other way to collect the subsidy their own flow just created. The reversal leg
    /// must not be a free draw on the reserve.
    function test_Harvest_CrossBlockRoundTripIsNotRisklessProfit() public {
        hook.setKappa(vaneKey, type(uint64).max / 2);

        uint256 hookBefore0 = hook.reserveOf(currency0);
        uint256 attackerBefore0 = currency0.balanceOfSelf();
        uint256 attackerBefore1 = currency1.balanceOfSelf();

        // block N: manufacture one-sided flow while the belief is still flat (no toll)
        vm.roll(block.number + 1);
        _swap(true, -100 ether);

        // block N+1, one transaction: dust swap rolls the belief, then harvest the reversal
        vm.roll(block.number + 1);
        _swap(true, -0.001 ether);
        _swap(false, -100 ether);

        int256 attackerPnl0 = int256(currency0.balanceOfSelf()) - int256(attackerBefore0);
        int256 attackerPnl1 = int256(currency1.balanceOfSelf()) - int256(attackerBefore1);

        console2.log("hook currency0 pnl    ", int256(hook.reserveOf(currency0)) - int256(hookBefore0));
        console2.log("attacker currency0 pnl", attackerPnl0);
        console2.log("attacker currency1 pnl", attackerPnl1);

        assertFalse(attackerPnl0 > 0 && attackerPnl1 > 0, "round trip must not be riskless profit");
    }

    /// The damping is one-sided: it may only shrink a payout, never a collection. Flow
    /// that runs with the belief is still tolled in full. For an exact-input sell the
    /// specified currency is currency1, so the hook collects in currency0.
    function test_Harvest_DampingDoesNotWeakenCollection() public {
        hook.setBelief(vaneKey, DELTA_100BPS);
        hook.setKappa(vaneKey, type(uint64).max / 2);

        uint256 before0 = hook.reserveOf(currency0);
        vm.roll(block.number + 1);
        _swap(false, -10 ether); // d > 0 and !zeroForOne -> hook takes

        assertGt(hook.reserveOf(currency0), before0, "hook must still collect when flow runs with the belief");
    }

    // ------------------------------------------- flash liquidity (finding 3 follow-up)

    /// depth feeds kappa. Until two consecutive checkpoints have both observed
    /// liquidity, depth is unknown and kappa must stay at zero rather than trusting a
    /// spot read that a single block of flash liquidity can set.
    function test_Kappa_UnseededCheckpointIgnoresFlashLiquidity() public {
        // build a price history so sigma is non-zero and kappa could otherwise be set
        for (uint256 i = 0; i < 30; i++) {
            vm.roll(block.number + 1);
            _swap(i % 2 == 0, -5 ether);
        }

        assertEq(hook.kappaOf(id), 0, "kappa starts unset");

        // force the first horizon checkpoint, with enormous flash liquidity in that block
        vm.roll(block.number + 25);
        modifyLiquidityRouter.modifyLiquidity(vaneKey, ModifyLiquidityParams(-60000, 60000, 5_000_000 ether, 0), "");
        _swap(true, -5 ether);
        modifyLiquidityRouter.modifyLiquidity(vaneKey, ModifyLiquidityParams(-60000, 60000, -5_000_000 ether, 0), "");

        assertGt(hook.poolStateAux(id).varKX32, 0, "horizon variance must be live, or the test proves nothing");
        assertEq(hook.kappaOf(id), 0, "an unseeded depth checkpoint must not hand kappa a flash-inflated depth");
    }

    /// Once seeded, a checkpoint takes the minimum of the previous and current
    /// liquidity, so flash liquidity added for one block cannot raise depth.
    function test_Kappa_SeededCheckpointTakesTheMinimumLiquidity() public {
        for (uint256 i = 0; i < 30; i++) {
            vm.roll(block.number + 1);
            _swap(i % 2 == 0, -5 ether);
        }
        vm.roll(block.number + 25);
        _swap(true, -5 ether); // seeds the depth checkpoint

        uint256 kappaSeeded = hook.kappaOf(id);

        vm.roll(block.number + 25);
        modifyLiquidityRouter.modifyLiquidity(vaneKey, ModifyLiquidityParams(-60000, 60000, 5_000_000 ether, 0), "");
        _swap(true, -5 ether);
        modifyLiquidityRouter.modifyLiquidity(vaneKey, ModifyLiquidityParams(-60000, 60000, -5_000_000 ether, 0), "");

        console2.log("kappa before flash", kappaSeeded);
        console2.log("kappa after flash ", hook.kappaOf(id));
        assertLe(
            hook.kappaOf(id), kappaSeeded == 0 ? 0 : kappaSeeded * 11 / 10, "flash liquidity must not inflate kappa"
        );
    }

    // ------------------------------------------- phantom notional (finding 1 regression)

    /// The original critical bug: the offset was sized from params.amountSpecified, which
    /// a caller can inflate arbitrarily while a tight sqrtPriceLimit keeps the executed
    /// swap at dust. The offset must be sized from the realized swap, so an enormous
    /// amountSpecified with a one-wei price limit can extract nothing.
    function test_PhantomNotional_CannotDrainTheReserve() public {
        hook.setBelief(vaneKey, DELTA_100BPS); // d > 0 -> hook pays on zeroForOne

        uint256 reserveBefore = hook.reserveOf(currency1);
        uint256 attackerBefore0 = currency0.balanceOfSelf();
        uint256 attackerBefore1 = currency1.balanceOfSelf();
        (uint160 sqrtNow,,,) = manager.getSlot0(id);

        swapRouter.swap(
            vaneKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(uint256(uint128(type(int128).max))),
                sqrtPriceLimitX96: sqrtNow - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(hook.reserveOf(currency1), reserveBefore, "a dust swap must not move the reserve");
        assertLe(currency0.balanceOfSelf(), attackerBefore0, "attacker must not profit in currency0");
        assertLe(currency1.balanceOfSelf(), attackerBefore1 + 1, "attacker must not profit in currency1");
    }

    /// The payout is bounded by the realized swap, so it can never exceed the amount the
    /// swap actually moved regardless of how the request was framed.
    function testFuzz_PayoutNeverExceedsRealizedSwap(uint96 rawNotional, bool zeroForOne) public {
        uint256 notional = bound(rawNotional, 0.001 ether, 50 ether);
        hook.setBelief(vaneKey, zeroForOne ? DELTA_100BPS : -DELTA_100BPS); // always the paying side

        uint256 reserveBefore = hook.reserveOf(zeroForOne ? currency1 : currency0);

        vm.roll(block.number + 1);
        _swap(zeroForOne, -int256(notional));

        uint256 reserveAfter = hook.reserveOf(zeroForOne ? currency1 : currency0);
        if (reserveAfter < reserveBefore) {
            assertLt(reserveBefore - reserveAfter, notional, "payout must stay under the swap notional");
        }
    }
}
