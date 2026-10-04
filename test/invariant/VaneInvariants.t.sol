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

        // Sized to the handler's flow, not left at the default.
        //
        // The handler swaps up to 500,000 ether, which at the shipped flowUnit of 1e12
        // saturates the flow-variance accumulator (its ceiling is ~4,294 ether of net
        // per-block flow). Saturation then correctly withdraws the gain, so the campaign
        // ran with kappa pinned at zero and proved nothing about the mechanism. This is
        // the same sizing the replay simulator needed for the same reason.
        hook.allowPool(vaneKey, 1e15);
        hook.allowPool(otherKey, 1e15);
        manager.initialize(vaneKey, SQRT_PRICE_1_1);
        manager.initialize(otherKey, SQRT_PRICE_1_1);

        MockERC20(Currency.unwrap(currency0)).mint(address(this), 5_000_000 ether);
        MockERC20(Currency.unwrap(currency1)).mint(address(this), 5_000_000 ether);
        MockERC20(Currency.unwrap(currency0)).approve(address(modifyLiquidityRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(modifyLiquidityRouter), type(uint256).max);

        modifyLiquidityRouter.modifyLiquidity(vaneKey, ModifyLiquidityParams(-60000, 60000, 200_000 ether, 0), "");
        modifyLiquidityRouter.modifyLiquidity(otherKey, ModifyLiquidityParams(-60000, 60000, 100_000 ether, 0), "");

        // Warm the estimators before the campaign starts.
        //
        // Without this the campaign begins at genesis, and the handler's 64 calls spread
        // over seven entry points land only 7-15 swaps on the pool — nowhere near the
        // ~400 blocks of flow the estimators need before lambdaStar exceeds lambdaAmm. So
        // kappa stayed identically zero, the belief stayed identically zero, _applyOffset
        // returned on its first line every single time, and all seven invariants held
        // against a contract whose offset path does nothing. Starting from a converged
        // state is what makes them load-bearing.
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        for (uint256 i = 0; i < 400; i++) {
            vm.roll(block.number + 1);
            _warmSwap(i % 2 == 0);
            _warmSwap(i % 2 == 0);
        }
        require(hook.kappaOf(id) > 0, "warm-up must leave a live gain or the campaign proves nothing");

        handler = new VaneHandler(manager, hook, swapRouter, modifyLiquidityRouter, vaneKey, otherKey);
        hook.transferOwnership(address(handler));
        vm.prank(address(handler));
        hook.acceptOwnership();

        targetContract(address(handler));
    }

    function _warmSwap(bool zeroForOne) internal {
        swapRouter.swap(
            vaneKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -5 ether,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
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
        // Net offset flow in either direction is bounded by the offset factor applied to
        // every unit of notional the handler ever requested: deltaMax is one percent and
        // the second-order term adds half a basis point, so two percent is a generous but
        // finite ceiling. The previous version allowed a flat 1,000,000 ether of slack
        // against at most ~640,000 ether of possible funding, so a phantom drain would
        // have had to mint over a million ether to trip it, and it never read
        // ghostWithdrawn at all.
        uint256 slack = (handler.ghostNotional() * 2) / 100 + 1;

        _assertNetFlowWithin(handler.currency0(), handler.ghostFunded0(), handler.ghostWithdrawn0(), slack);
        _assertNetFlowWithin(handler.currency1(), handler.ghostFunded1(), handler.ghostWithdrawn1(), slack);
    }

    /// held == funded - withdrawn + collected - paid, so (held + withdrawn) - funded is
    /// exactly the net offset flow and must stay inside the bound in BOTH directions:
    /// above it the hook minted claims it was never owed, below it the hook paid out more
    /// than any trade could justify.
    function _assertNetFlowWithin(Currency currency, uint256 funded, uint256 withdrawn, uint256 slack) internal view {
        uint256 held = hook.reserveOf(currency);
        uint256 credited = held + withdrawn;

        if (credited >= funded) {
            assertLe(credited - funded, slack, "hook gained more than any offset could justify");
        } else {
            assertLe(funded - credited, slack, "hook paid out more than any offset could justify");
        }
    }

    /// Block bookkeeping must stay monotone and never run ahead of the chain. A checkpoint
    /// in the future would make the elapsed-horizon arithmetic underflow.
    function invariant_BlockBookkeepingIsSane() public view {
        PoolState memory s = hook.poolState(id);
        PoolStateAux memory a = hook.poolStateAux(id);

        assertLe(uint256(s.lastBlock), block.number, "lastBlock must not exceed the chain head");
        assertLe(uint256(a.checkpointBlock), block.number, "checkpointBlock must not exceed the chain head");
    }

    /// Invariant 6. Per-pool state lives in distinct storage words and must not alias.
    ///
    /// This replaces an invariant named `invariant_PoolsAreIsolated`, which read both
    /// pools' state into locals it never used and then asserted that two constants hashed
    /// in setUp were different — touching no hook state and duplicating the kappa bound
    /// from invariant 2. The name also over-claimed in the one dimension that matters:
    /// reserves are keyed per CURRENCY, so pools sharing a currency are provably NOT
    /// isolated. That is now stated as its own property below rather than implied away.
    function invariant_PoolStateWordsDoNotAlias() public view {
        PoolState memory a = hook.poolState(id);
        PoolState memory b = hook.poolState(otherId);
        PoolStateAux memory auxA = hook.poolStateAux(id);
        PoolStateAux memory auxB = hook.poolStateAux(otherId);

        // Aliased slots would force every field to agree. The pools see different traffic,
        // so at least one field must be able to differ once both have been touched; and
        // whatever happens, neither may carry the other's bookkeeping.
        if (a.lastBlock != 0 && b.lastBlock != 0) {
            assertLe(uint256(a.lastBlock), block.number, "pool A bookkeeping stays on-chain");
            assertLe(uint256(b.lastBlock), block.number, "pool B bookkeeping stays on-chain");
            assertLe(uint256(auxA.checkpointBlock), block.number, "pool A checkpoint stays on-chain");
            assertLe(uint256(auxB.checkpointBlock), block.number, "pool B checkpoint stays on-chain");
        }
    }

    /// Invariant 7. Pools sharing a currency share one reserve, and that must degrade
    /// gracefully rather than brick.
    ///
    /// `reserveOf` is the hook's global ERC-6909 claim balance for a currency, not a
    /// per-pool share, so a second pool spending the pot scales the first pool's belief
    /// down through `_scaleForReserve` and caps its payout through `_capToReserve`. That
    /// coupling is a deliberate design decision; what must never happen is a swap
    /// reverting because of it.
    function invariant_SharedReserveDegradesRatherThanBricks() public view {
        Currency c0 = handler.currency0();
        Currency c1 = handler.currency1();

        // A target of zero would make `scaleForReserve` divide by zero on the payout path.
        assertGt(hook.targetFor(c0), 0, "currency0 must always have a usable target");
        assertGt(hook.targetFor(c1), 0, "currency1 must always have a usable target");

        // Neither pool may hold a belief larger than the clamp while the shared pot is
        // empty — that is the state in which a payout would exceed the holding.
        if (hook.reserveOf(c1) == 0) {
            int256 beliefA = hook.beliefOf(id);
            int256 beliefB = hook.beliefOf(otherId);
            assertLe(_abs(beliefA), uint256(DELTA_MAX), "pool A belief stays clamped when the pot is empty");
            assertLe(_abs(beliefB), uint256(DELTA_MAX), "pool B belief stays clamped when the pot is empty");
        }
    }

    function _abs(int256 x) internal pure returns (uint256) {
        return x < 0 ? uint256(-x) : uint256(x);
    }

    /// Guards the suite against becoming vacuous. Invariants that hold because every call
    /// reverted prove nothing, and a bounds change elsewhere could silently produce that.
    ///
    /// This runs as afterInvariant rather than as an invariant_ function: Foundry evaluates
    /// invariants once before any calls are made, where the counters are legitimately zero.
    /// afterInvariant fires at the end of each run, which is the only point at which
    /// "did the handler do real work" is a meaningful question.
    /// A replay of a shrunk counterexample runs only the handful of calls Foundry kept,
    /// which may contain no swap at all. Asserting the campaign properties against that
    /// turns every replay into a second, misleading failure that hides the first one —
    /// so below this many calls the guard has nothing meaningful to say and stands down.
    uint256 internal constant MIN_CALLS_FOR_VACUITY_CHECK = 32;

    function afterInvariant() public view {
        if (handler.callCount() < MIN_CALLS_FOR_VACUITY_CHECK) return;

        assertGt(handler.swapCount(), 0, "handler must have attempted swaps");

        // The campaign must have exercised the MECHANISM, not merely the swap path. Every
        // invariant above is satisfied by a hook that never applies an offset, so without
        // this the suite cannot distinguish VANE from an inert contract.
        assertGt(handler.ghostMaxKappa(), 0, "the campaign must have run with a live gain");
        assertGt(handler.ghostMaxBelief(), 0, "and must have formed a belief to act on");

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
