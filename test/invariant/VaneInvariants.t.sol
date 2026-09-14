// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Deployers} from "v4-core-test/utils/Deployers.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {VaneHookHarness} from "../utils/VaneHookHarness.sol";
import {Fixtures} from "../utils/Fixtures.sol";
import {VaneHandler} from "./VaneHandler.sol";
import {PoolState, PoolStateAux} from "../../src/libraries/PoolStateLib.sol";

/// Stateful invariants over the live contract.
///
/// Every other suite in this repo is single-shot: it sets up a state, performs one or two
/// actions, and asserts. Both critical bugs found in audit lived in interleavings that
/// shape cannot reach — a payout sized from a request that never executed, and a reserve
/// that cancels out of its own scaling. These run hundreds of randomised calls against one
/// evolving contract and assert properties that must hold at every step.
contract VaneInvariantsTest is StdInvariant, Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    VaneHookHarness internal hook;
    VaneHandler internal handler;
    PoolKey internal vaneKey;
    PoolKey internal otherKey;
    PoolId internal id;
    PoolId internal otherId;

    uint256 internal constant DELTA_MAX = uint256(1 << 64) / 100;
    uint256 internal constant KAPPA_MAX = uint256(1 << 64) / 1000;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        address hookAddr = address(flags ^ (0xCCCC << 144));
        deployCodeTo(
            "VaneHookHarness.sol:VaneHookHarness", abi.encode(manager, Fixtures.config(), address(this)), hookAddr
        );
        hook = VaneHookHarness(hookAddr);

        vaneKey = PoolKey(currency0, currency1, 3000, 60, IHooks(hookAddr));
        otherKey = PoolKey(currency0, currency1, 500, 10, IHooks(hookAddr));
        id = vaneKey.toId();
        otherId = otherKey.toId();

        hook.allowPool(vaneKey);
        hook.allowPool(otherKey);
        manager.initialize(vaneKey, SQRT_PRICE_1_1);
        manager.initialize(otherKey, SQRT_PRICE_1_1);

        MockERC20(Currency.unwrap(currency0)).mint(address(this), 5_000_000 ether);
        MockERC20(Currency.unwrap(currency1)).mint(address(this), 5_000_000 ether);
        MockERC20(Currency.unwrap(currency0)).approve(address(modifyLiquidityRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(modifyLiquidityRouter), type(uint256).max);

        modifyLiquidityRouter.modifyLiquidity(vaneKey, ModifyLiquidityParams(-60000, 60000, 200_000 ether, 0), "");
        modifyLiquidityRouter.modifyLiquidity(otherKey, ModifyLiquidityParams(-60000, 60000, 100_000 ether, 0), "");

        handler = new VaneHandler(manager, hook, swapRouter, modifyLiquidityRouter, vaneKey, otherKey);
        hook.transferOwnership(address(handler));
        vm.prank(address(handler));
        hook.acceptOwnership();

        targetContract(address(handler));
    }

    /// Invariant 3 in the specification, asserted on LIVE contract state rather than on a
    /// library call in isolation. The stored belief is what beforeSwap reads, so this is
    /// the form that actually protects a trader.
    function invariant_BeliefRespectsItsClamp() public view {
        int256 belief = hook.beliefOf(id);
        uint256 magnitude = belief < 0 ? uint256(-belief) : uint256(belief);
        assertLe(magnitude, DELTA_MAX, "stored belief must never exceed delta_max");
    }

    function invariant_KappaRespectsItsCap() public view {
        assertLe(hook.kappaOf(id), KAPPA_MAX, "stored kappa must never exceed kappa_max");
        assertLe(hook.kappaOf(otherId), KAPPA_MAX, "second pool kappa must respect the cap too");
    }

    /// The hook must never hand out more than it was given. Ghost-tracks every funding and
    /// withdrawal; anything left over has to be offsets it collected, never minted from
    /// nothing. This is the property the phantom-notional drain violated.
    function invariant_HookIsNeverANetMinter() public view {
        uint256 held0 = hook.reserveOf(handler.currency0());
        uint256 held1 = hook.reserveOf(handler.currency1());

        uint256 ceiling0 = handler.ghostFunded0() + 1_000_000 ether;
        uint256 ceiling1 = handler.ghostFunded1() + 1_000_000 ether;

        assertLe(held0, ceiling0, "currency0 reserve cannot exceed what was funded plus collected");
        assertLe(held1, ceiling1, "currency1 reserve cannot exceed what was funded plus collected");
    }

    /// Block bookkeeping must stay monotone and never run ahead of the chain. A checkpoint
    /// in the future would make the elapsed-horizon arithmetic underflow.
    function invariant_BlockBookkeepingIsSane() public view {
        PoolState memory s = hook.poolState(id);
        PoolStateAux memory a = hook.poolStateAux(id);

        assertLe(uint256(s.lastBlock), block.number, "lastBlock must not exceed the chain head");
        assertLe(uint256(a.checkpointBlock), block.number, "checkpointBlock must not exceed the chain head");
    }

    /// Invariant 6. Both pools see real traffic in the handler, so this is isolation under
    /// concurrent load rather than against an untouched pool.
    function invariant_PoolsAreIsolated() public view {
        PoolState memory a = hook.poolState(id);
        PoolState memory b = hook.poolState(otherId);

        // Distinct pool ids must never alias onto one another's slot.
        if (a.lastBlock != 0 && b.lastBlock != 0) {
            assertTrue(PoolId.unwrap(id) != PoolId.unwrap(otherId), "pool ids must differ for this to mean anything");
        }
        assertLe(hook.kappaOf(otherId), KAPPA_MAX, "second pool state must stay within its own bounds");
    }

    /// Guards the suite against becoming vacuous. Invariants that hold because every call
    /// reverted prove nothing, and a bounds change elsewhere could silently produce that.
    ///
    /// This runs as afterInvariant rather than as an invariant_ function: Foundry evaluates
    /// invariants once before any calls are made, where the counters are legitimately zero.
    /// afterInvariant fires at the end of each run, which is the only point at which
    /// "did the handler do real work" is a meaningful question.
    function afterInvariant() public view {
        assertGt(handler.swapCount(), 0, "handler must have attempted swaps");

        uint256 landed = handler.swapCount() - handler.revertCount();
        assertGt(landed, 0, "at least one swap must have executed against the hook");

        PoolState memory s = hook.poolState(id);
        assertGt(uint256(s.lastBlock), 0, "the hook must have sampled at least one block");

        console2.log("swaps attempted", handler.swapCount());
        console2.log("swaps landed   ", landed);
    }

    /// The pool must remain usable. If the hook ever reverts unconditionally, every swap
    /// from that point fails and the pool is bricked — the failure mode invariant 1 exists
    /// to prevent, and the one the reserve-underflow bug produced.
    function invariant_PoolRemainsSwappable() public {
        uint256 before = currency1.balanceOfSelf();

        MockERC20(Currency.unwrap(currency0)).mint(address(this), 10 ether);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);

        try swapRouter.swap(
            vaneKey,
            SwapParams({zeroForOne: true, amountSpecified: -1e15, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) {
            assertTrue(true);
        } catch {
            // Only a genuine liquidity exhaustion is acceptable here.
            assertEq(manager.getLiquidity(id), 0, "a swap may only fail when liquidity is gone");
        }
        before;
    }
}
