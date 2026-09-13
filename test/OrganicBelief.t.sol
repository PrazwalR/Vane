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
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {VaneHookHarness} from "./utils/VaneHookHarness.sol";
import {Fixtures} from "./utils/Fixtures.sol";

contract OrganicBeliefTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    VaneHookHarness internal hook;
    PoolKey internal vaneKey;
    PoolId internal id;

    uint16 internal constant HORIZON_K = 20;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        address hookAddr = address(flags ^ (0xBBBB << 144));
        deployCodeTo(
            "VaneHookHarness.sol:VaneHookHarness", abi.encode(manager, Fixtures.config(), address(this)), hookAddr
        );
        hook = VaneHookHarness(hookAddr);

        vaneKey = PoolKey(currency0, currency1, 3000, 60, IHooks(hookAddr));
        id = vaneKey.toId();
        hook.allowPool(vaneKey);
        manager.initialize(vaneKey, SQRT_PRICE_1_1);

        MockERC20(Currency.unwrap(currency0)).mint(address(this), 2_000_000 ether);
        MockERC20(Currency.unwrap(currency1)).mint(address(this), 2_000_000 ether);
        MockERC20(Currency.unwrap(currency0)).approve(address(modifyLiquidityRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(modifyLiquidityRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);

        modifyLiquidityRouter.modifyLiquidity(vaneKey, ModifyLiquidityParams(-120000, 120000, 200_000 ether, 0), "");
        hook.fundReserve(currency0, 1000 ether);
        hook.fundReserve(currency1, 1000 ether);
    }

    /// Drives the estimators to a converged state using only real swaps. Two
    /// same-direction swaps per block make the price trend within the block; the
    /// direction flips between blocks so the price wanders instead of running away.
    /// A pure per-block alternation would return the price to its start every time,
    /// leaving Var(r_k) at zero and kappa correctly at zero.
    function _warmEstimators() internal {
        for (uint256 i = 0; i < 400; i++) {
            vm.roll(block.number + 1);
            _swap(i % 2 == 0, -5 ether);
            _swap(i % 2 == 0, -5 ether);
        }
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

    /// The mechanism must engage on its own. No setKappa, no setBelief: kappa comes
    /// from the checkpoint and the belief from flow, exactly as a live pool would.
    function test_Organic_BeliefFormsFromFlowAlone() public {
        // Warm the estimators so a checkpoint has real variance to work with.
        _warmEstimators();

        uint256 kappa = hook.kappaOf(id);
        console2.log("kappa after warmup (Q64.64):", kappa);
        assertGt(kappa, 0, "kappa must become nonzero from pool state alone");

        int256 beliefBefore = hook.beliefOf(id);

        // Sustained one-sided buying: the informed case the mechanism prices.
        for (uint256 i = 0; i < 30; i++) {
            vm.roll(block.number + 1);
            _swap(false, -20 ether);
        }

        int256 beliefAfter = hook.beliefOf(id);
        console2.log("belief before one-sided flow:", beliefBefore);
        console2.log("belief after  one-sided flow:", beliefAfter);
        console2.log("belief, hundred-thousandths of a bp:", uint256(beliefAfter) * 10000 * 100000 / (1 << 64));

        assertGt(beliefAfter, 0, "sustained buying must form a positive belief with no manual kappa");
    }

    /// The same, in the other direction.
    function test_Organic_SellingFormsNegativeBelief() public {
        _warmEstimators();
        assertGt(hook.kappaOf(id), 0, "kappa must be live");

        for (uint256 i = 0; i < 30; i++) {
            vm.roll(block.number + 1);
            _swap(true, -20 ether);
        }

        int256 belief = hook.beliefOf(id);
        console2.log("belief after one-sided selling:", belief);
        assertLt(belief, 0, "sustained selling must form a negative belief");
    }

    /// An organically formed belief must actually change execution, not just sit in
    /// storage. This is the property the whole mechanism exists to deliver.
    function test_Organic_BeliefChangesExecutionPrice() public {
        _warmEstimators();
        for (uint256 i = 0; i < 30; i++) {
            vm.roll(block.number + 1);
            _swap(false, -20 ether);
        }
        assertGt(hook.beliefOf(id), 0, "belief must be live for this test to mean anything");

        uint256 reserveBefore = hook.reserveOf(currency0);
        vm.roll(block.number + 1);
        _swap(false, -20 ether);

        assertGt(hook.reserveOf(currency0), reserveBefore, "a buyer into a positive belief must pay the offset");
    }
}
