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

/// What does it cost to switch VANE off for a pool, and for how long does it stay off?
///
/// Saturating the flow-variance accumulator withdraws the gain, which is the correct
/// response to an estimate that has overflowed. The danger was the DURATION: the gate used
/// to read a sticky flag, so one 43,000-ether round trip — 258 ether at the 0.3% tier —
/// switched the hook off until a human re-allowlisted the pool. A denial of mechanism that
/// can be bought outright is an economic break even though nothing is stolen.
///
/// The gate now reads the live level instead. The two regimes are opposites: while an
/// update overflows the stored value understates the true variance (lambda* overstated,
/// dangerous), and once ordinary flow resumes that same value overstates it (lambda*
/// understated, conservative). So recovery is automatic as the corrupted sample washes
/// out, and the attacker has to keep paying to hold the mechanism down.
contract SaturationDoSTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    VaneHookHarness internal hook;
    PoolKey internal vaneKey;
    PoolId internal id;

    address internal attacker = address(0xA77ACC);

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        address hookAddr = address(flags ^ (0xD05D << 144));
        deployCodeTo(
            "VaneHookHarness.sol:VaneHookHarness", abi.encode(manager, Fixtures.config(), address(this)), hookAddr
        );
        hook = VaneHookHarness(hookAddr);

        vaneKey = PoolKey(currency0, currency1, 3000, 60, IHooks(hookAddr));
        id = vaneKey.toId();
        hook.allowPool(vaneKey);
        manager.initialize(vaneKey, SQRT_PRICE_1_1);

        // A deep pool, so the attack is evaluated where the mechanism is supposed to matter.
        MockERC20(Currency.unwrap(currency0)).mint(address(this), 100_000_000 ether);
        MockERC20(Currency.unwrap(currency1)).mint(address(this), 100_000_000 ether);
        MockERC20(Currency.unwrap(currency0)).approve(address(modifyLiquidityRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(modifyLiquidityRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity(vaneKey, ModifyLiquidityParams(-60000, 60000, 2_000_000 ether, 0), "");

        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        hook.fundReserve(currency0, 10_000 ether);
        hook.fundReserve(currency1, 10_000 ether);

        MockERC20(Currency.unwrap(currency0)).mint(attacker, 100_000_000 ether);
        MockERC20(Currency.unwrap(currency1)).mint(attacker, 100_000_000 ether);
        vm.startPrank(attacker);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
    }

    function _swapAs(address who, bool zeroForOne, int256 amount) internal {
        vm.prank(who);
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

    /// Bring the mechanism to life from flow alone, so the attack has something to destroy.
    function _warm() internal {
        for (uint256 i = 0; i < 400; i++) {
            vm.roll(block.number + 1);
            _swapAs(address(this), i % 2 == 0, -5 ether);
            _swapAs(address(this), i % 2 == 0, -5 ether);
        }
    }

    function _attackerValue() internal view returns (uint256) {
        return MockERC20(Currency.unwrap(currency0)).balanceOf(attacker)
            + MockERC20(Currency.unwrap(currency1)).balanceOf(attacker);
    }

    /// The attack still works, but only for as long as it is paid for.
    function test_AttackDisablesTheMechanismOnlyTransiently() public {
        _warm();
        uint256 liveKappa = hook.kappaOf(id);
        assertGt(liveKappa, 0, "precondition: the mechanism is live");
        console2.log("kappa before attack     :", liveKappa);

        uint256 valueBefore = _attackerValue();

        // One block, one direction, enough net flow to overflow the accumulator.
        vm.roll(block.number + 1);
        _swapAs(attacker, true, -43_000 ether);

        // Unwind next block to recover as much as possible.
        vm.roll(block.number + 1);
        _swapAs(attacker, false, -43_000 ether);

        uint256 valueAfter = _attackerValue();
        uint256 cost = valueBefore > valueAfter ? valueBefore - valueAfter : 0;

        // Let a horizon pass so the remedy runs.
        for (uint256 i = 0; i < 25; i++) {
            vm.roll(block.number + 1);
            _swapAs(address(this), i % 2 == 0, -5 ether);
        }

        console2.log("saturation recorded     :", hook.poolState(id).saturated);
        console2.log("kappa after recovery    :", hook.kappaOf(id));
        console2.log("attacker cost (ether)   :", cost / 1e18);

        assertTrue(hook.poolState(id).saturated, "the saturation is recorded for operators");
        assertGt(cost, 100 ether, "the attack is not free");

        // And the mechanism is back, with no operator action, because the corrupted level
        // has decayed off its bound and now reads as a conservative overstatement.
        assertGt(hook.kappaOf(id), 0, "the gain must return once the estimate is measurable again");
    }

    /// The outage has to be short enough that an attacker cannot buy meaningful downtime,
    /// and the number is worth recording rather than asserting loosely.
    function test_RecoveryTimeAfterSaturation() public {
        _warm();
        uint256 before = hook.kappaOf(id);
        assertGt(before, 0, "precondition");

        vm.roll(block.number + 1);
        _swapAs(attacker, true, -43_000 ether);
        vm.roll(block.number + 1);
        _swapAs(attacker, false, -43_000 ether);

        uint256 blocksToRecover = type(uint256).max;
        for (uint256 i = 0; i < 1200; i++) {
            vm.roll(block.number + 1);
            _swapAs(address(this), i % 2 == 0, -5 ether);
            _swapAs(address(this), i % 2 == 0, -5 ether);
            if (hook.kappaOf(id) > 0) {
                blocksToRecover = i + 1;
                break;
            }
        }

        console2.log("blocks of honest flow to recover the gain:", blocksToRecover);
        assertLt(blocksToRecover, 1200, "the mechanism must recover without operator action");
    }

    /// The inverse of the old property. Sustained honest flow must restore the mechanism
    /// on its own; requiring a human was the whole vulnerability.
    function test_MechanismRecoversWithoutOperatorAction() public {
        _warm();
        assertGt(hook.kappaOf(id), 0, "precondition");

        vm.roll(block.number + 1);
        _swapAs(attacker, true, -43_000 ether);
        vm.roll(block.number + 1);
        _swapAs(attacker, false, -43_000 ether);

        // A long stretch of ordinary two-sided flow, far more than the EWMA needs to decay.
        for (uint256 i = 0; i < 600; i++) {
            vm.roll(block.number + 1);
            _swapAs(address(this), i % 2 == 0, -5 ether);
            _swapAs(address(this), i % 2 == 0, -5 ether);
        }

        assertGt(hook.kappaOf(id), 0, "honest flow alone must bring the gain back");

        // The record of what happened survives for operators, without gating anything.
        assertTrue(hook.poolState(id).saturated, "the pool still reports that it saturated");

        // And an operator can still clear the record explicitly.
        hook.allowPool(vaneKey, 1e15);
        assertFalse(hook.poolState(id).saturated, "re-allowlisting clears the record");
    }

    /// A pool whose flow re-saturates every block must stay disabled for as long as that
    /// is true. This is the case the sticky flag was really protecting, and dropping the
    /// stickiness must not weaken it: the live gate holds the gain at zero whenever the
    /// stored level is on its bound, which under sustained oversized flow is every block.
    function test_SustainedSaturatingFlowKeepsTheGainOff() public {
        _warm();
        assertGt(hook.kappaOf(id), 0, "precondition: the mechanism is live");

        // Each block carries enough net one-directional flow to overflow the accumulator
        // on its own, so the level never decays off the bound.
        for (uint256 i = 0; i < 60; i++) {
            vm.roll(block.number + 1);
            _swapAs(attacker, true, -43_000 ether);
            vm.roll(block.number + 1);
            _swapAs(attacker, false, -43_000 ether);
        }

        assertEq(hook.poolState(id).flowVarUnitsSq, type(uint64).max, "the level stays pinned");
        assertEq(hook.kappaOf(id), 0, "and the gain stays withdrawn while it is unmeasurable");

        // Once the oversized flow stops the mechanism comes back on its own, but recovery
        // from a SUSTAINED attack is slower than from a single event: the level sat on its
        // bound throughout, so it has to decay from the ceiling rather than from one
        // sample. That cost is the attacker's leverage, so the number is worth recording.
        uint256 blocksToRecover = type(uint256).max;
        for (uint256 i = 0; i < 800; i++) {
            vm.roll(block.number + 1);
            _swapAs(address(this), i % 2 == 0, -5 ether);
            _swapAs(address(this), i % 2 == 0, -5 ether);
            if (hook.kappaOf(id) > 0) {
                blocksToRecover = i + 1;
                break;
            }
        }

        console2.log("blocks to recover after a 120-block sustained attack:", blocksToRecover);
        assertLt(blocksToRecover, 800, "the mechanism must recover without operator action");
    }
}
