// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BeliefState} from "../src/libraries/BeliefState.sol";

/// dampPending is the guard that stops a swap harvesting a belief that its own,
/// not-yet-sampled flow is in the act of reversing. It must only ever shrink a
/// belief toward zero, never widen it and never flip its sign.
contract BeliefDampingTest is Test {
    int256 internal constant ONE_X64 = int256(1) << 64;
    int256 internal constant ONE_PCT = ONE_X64 / 100;

    function test_OpposingFlowShrinksTheBelief() public pure {
        int256 damped = BeliefState.dampPending(ONE_PCT, -ONE_PCT / 4);
        assertLt(damped, ONE_PCT, "opposing flow must shrink the payout");
        assertGt(damped, 0, "partial opposition must not zero it out");
    }

    function test_FullyOpposingFlowZeroesTheBelief() public pure {
        assertEq(BeliefState.dampPending(ONE_PCT, -ONE_PCT), 0, "an exact reversal pays nothing");
        assertEq(BeliefState.dampPending(ONE_PCT, -ONE_PCT * 5), 0, "overshoot must clamp at zero, not flip sign");
        assertEq(BeliefState.dampPending(-ONE_PCT, ONE_PCT * 5), 0, "same on the short side");
    }

    function test_AgreeingFlowNeverWidensTheBelief() public pure {
        assertEq(BeliefState.dampPending(ONE_PCT, ONE_PCT), ONE_PCT, "must not pay more than the stored belief");
        assertEq(BeliefState.dampPending(-ONE_PCT, -ONE_PCT), -ONE_PCT, "same on the short side");
    }

    function test_ZeroBeliefStaysZero() public pure {
        assertEq(BeliefState.dampPending(0, ONE_X64), 0, "no belief, no payout");
    }

    /// The three properties the guard relies on, over the whole representable range.
    function testFuzz_DampingIsAOneSidedShrink(int64 rawDelta, int128 rawIncrement) public pure {
        int256 d = int256(rawDelta);
        int256 damped = BeliefState.dampPending(d, int256(rawIncrement));

        // 1. never widens
        assertLe(_abs(damped), _abs(d), "damping must never increase the magnitude");

        // 2. never flips sign
        if (damped != 0) {
            assertTrue((damped > 0) == (d > 0), "damping must never flip the sign");
        }

        // 3. flow that agrees with the belief leaves it exactly at the stored value
        if (d > 0 && rawIncrement >= 0) assertEq(damped, d, "agreeing flow is capped at the stored belief");
        if (d < 0 && rawIncrement <= 0) assertEq(damped, d, "agreeing flow is capped at the stored belief");
    }

    function testFuzz_DampingIsMonotoneInOpposingFlow(int64 rawDelta, uint64 a, uint64 b) public pure {
        int256 d = int256(rawDelta);
        vm.assume(d > 0);
        int256 small = -int256(uint256(a));
        int256 large = -int256(uint256(a)) - int256(uint256(b));

        assertLe(
            BeliefState.dampPending(d, large),
            BeliefState.dampPending(d, small),
            "more opposing flow must never pay more"
        );
    }

    function _abs(int256 x) private pure returns (uint256) {
        return x < 0 ? uint256(-x) : uint256(x);
    }
}
