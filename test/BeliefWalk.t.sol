// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BeliefState} from "../src/libraries/BeliefState.sol";

/// The pricing rule the offset rests on: a swap pays the average belief across the walk
/// its own flow makes, so what the hook collects and pays is the change in a potential.
///
/// With the belief written `x` and a step from `a` to `b`, the hook's take on that step is
/// `(b - a) * walkAverage(a, b)`, which is positive when the step moves away from zero and
/// negative when it moves back. These properties are what the reserve's solvency against
/// round trips reduces to.
contract BeliefWalkTest is Test {
    int256 internal constant ONE_X64 = int256(1) << 64;
    int256 internal constant CAP = ONE_X64 / 100;

    // ------------------------------------------------------------------ exact values

    function test_InsideTheBandTheAverageIsTheMidpoint() public pure {
        assertEq(BeliefState.walkAverage(0, CAP / 2, CAP), CAP / 4, "linear integrand");
        assertEq(BeliefState.walkAverage(-CAP / 2, CAP / 2, CAP), 0, "symmetric walk through zero");
        assertEq(BeliefState.walkAverage(CAP / 2, 0, CAP), CAP / 4, "direction does not change the average");
    }

    function test_SaturatedOnOneSideTheAverageIsTheCap() public pure {
        assertEq(BeliefState.walkAverage(CAP, 3 * CAP, CAP), CAP, "flat above the band");
        assertEq(BeliefState.walkAverage(-5 * CAP, -CAP, CAP), -CAP, "flat below the band");
    }

    function test_AZeroLengthWalkPricesAtTheClampedPoint() public pure {
        assertEq(BeliefState.walkAverage(CAP / 3, CAP / 3, CAP), CAP / 3, "inside");
        assertEq(BeliefState.walkAverage(7 * CAP, 7 * CAP, CAP), CAP, "clamped above");
        assertEq(BeliefState.walkAverage(-7 * CAP, -7 * CAP, CAP), -CAP, "clamped below");
    }

    /// A walk from 0 to 2*cap: half of it on the ramp averaging cap/2, half on the flat at
    /// cap, so 3/4 cap. Pricing it at the midpoint of the CLAMPED endpoints would give cap/2
    /// and undercharge a single large leg against one walked back in small steps.
    function test_AWalkAcrossTheCapIntegratesTheClamp() public pure {
        assertEq(BeliefState.walkAverage(0, 2 * CAP, CAP), (3 * CAP) / 4, "ramp then flat");
        assertEq(BeliefState.walkAverage(2 * CAP, 0, CAP), (3 * CAP) / 4, "same segment, reversed");
        assertEq(BeliefState.walkAverage(0, -2 * CAP, CAP), -(3 * CAP) / 4, "negative side");
    }

    // ------------------------------------------------------------------- properties

    function testFuzz_AverageIsWithinTheCap(int128 a, int128 b, uint64 rawCap) public pure {
        int256 cap = int256(uint256(bound(rawCap, 1, uint64(type(int64).max))));
        int256 avg = BeliefState.walkAverage(int256(a), int256(b), cap);
        assertLe(avg, cap, "above the cap");
        assertGe(avg, -cap, "below the cap");
    }

    /// The clamp is monotone, so its average over a segment lies between its values at the
    /// two ends. Allow one unit for the integer division.
    function testFuzz_AverageLiesBetweenTheClampedEndpoints(int128 a, int128 b, uint64 rawCap) public pure {
        int256 cap = int256(uint256(bound(rawCap, 1, uint64(type(int64).max))));
        int256 ca = _clamp(int256(a), cap);
        int256 cb = _clamp(int256(b), cap);
        int256 lo = ca < cb ? ca : cb;
        int256 hi = ca < cb ? cb : ca;

        int256 avg = BeliefState.walkAverage(int256(a), int256(b), cap);
        assertGe(avg, lo - 1, "below both endpoints");
        assertLe(avg, hi + 1, "above both endpoints");
    }

    /// The property the reserve depends on. Build a belief in one step, then walk it back
    /// to where it started in `n` unequal steps: the hook's net take is zero up to one unit
    /// of rounding per step. However the trader splits the legs, a closed loop pays them
    /// nothing.
    function testFuzz_AClosedLoopNetsToZero(int64 start, int128 rawSpan, uint8 rawSteps, uint256 seed) public pure {
        int256 cap = CAP;
        int256 a = int256(start);
        int256 span = int256(bound(int256(rawSpan), -100 * CAP, 100 * CAP));
        uint256 n = bound(uint256(rawSteps), 1, 40);

        int256 b = a + span;
        int256 take = _take(a, b, cap);

        int256 x = b;
        uint256 slack = 1;
        for (uint256 i = 0; i < n; i++) {
            int256 next;
            if (i == n - 1) {
                next = a;
            } else {
                // A random fraction of what is left, so the legs are unequal.
                seed = uint256(keccak256(abi.encode(seed, i)));
                next = x + ((a - x) * int256(seed % 1000)) / 1000;
            }
            take += _take(x, next, cap);
            slack += _abs(next - x) / uint256(ONE_X64) + 2;
            x = next;
        }

        // Rounding is at most one unit of the average per step, which is |step| / 2^64 of
        // the take, plus one for the take's own division. `slack` sums exactly that.
        assertLe(_abs(take), slack, "a closed loop must net to zero");
    }

    /// The single-leg form of the same thing: walking out and straight back is free.
    function testFuzz_OutAndBackIsFree(int64 start, int128 rawSpan) public pure {
        int256 a = int256(start);
        int256 b = a + int256(bound(int256(rawSpan), -100 * CAP, 100 * CAP));
        int256 net = _take(a, b, CAP) + _take(b, a, CAP);
        assertLe(_abs(net), 2 * (_abs(b - a) / uint256(ONE_X64)) + 4, "out and back must cancel");
    }

    /// Moving away from zero always costs the trader, and moving toward it always pays them.
    function testFuzz_TheTakeHasTheSignOfTheWalk(int64 rawA, int64 rawB) public pure {
        int256 a = int256(rawA);
        int256 b = int256(rawB);
        vm.assume(a != b);
        // Both on the same side of zero, so "away" and "toward" are well defined.
        vm.assume((a >= 0 && b >= 0) || (a <= 0 && b <= 0));

        int256 take = _take(a, b, CAP);
        if (_abs(b) > _abs(a)) assertGe(take, 0, "building a belief must never be paid");
        else assertLe(take, 0, "unwinding a belief must never be charged");
    }

    // -------------------------------------------------------------------- revision

    function test_AFallingGainShrinksTheBeliefInProportion() public pure {
        assertEq(BeliefState.revise(CAP, 25, 100), CAP / 4, "a quarter of the gain, a quarter of the belief");
        assertEq(BeliefState.revise(-CAP, 50, 100), -CAP / 2, "same on the short side");
    }

    function test_AWithdrawnGainWithdrawsTheBelief() public pure {
        assertEq(BeliefState.revise(CAP, 0, 1), 0, "a belief that no longer moves with flow is unbounded liability");
        assertEq(BeliefState.revise(-CAP, 0, type(uint64).max), 0, "same on the short side");
    }

    function test_ARisingGainLeavesTheBeliefAlone() public pure {
        assertEq(BeliefState.revise(CAP, 200, 100), CAP, "never widen");
        assertEq(BeliefState.revise(CAP, 100, 100), CAP, "an unchanged gain is a no-op");
        assertEq(BeliefState.revise(CAP, 0, 0), CAP, "no gain before or after");
    }

    /// The liability of a belief at gain k is d^2 / (2k): what flow walking it back to zero
    /// is paid. A revision must never raise it. Cross-multiplied to stay in integers.
    function testFuzz_RevisionNeverRaisesTheLiability(int64 rawD, uint64 kNew, uint64 kOld) public pure {
        vm.assume(kNew > 0 && kOld > 0);
        int256 d = int256(rawD);
        int256 revised = BeliefState.revise(d, kNew, kOld);

        // revised^2 / kNew <= d^2 / kOld   <=>   revised^2 * kOld <= d^2 * kNew   (kNew < kOld)
        // and for kNew >= kOld the belief is unchanged, so the liability falls on its own.
        uint256 lhs = _abs(revised) * _abs(revised) * uint256(kOld);
        uint256 rhs = _abs(d) * _abs(d) * uint256(kNew);
        if (kNew < kOld) assertLe(lhs, rhs, "a falling gain must not raise the liability");
        else assertEq(revised, d, "a rising gain must not touch the belief");
    }

    function testFuzz_RevisionNeverWidensOrFlips(int64 rawD, uint64 kNew, uint64 kOld) public pure {
        int256 d = int256(rawD);
        int256 revised = BeliefState.revise(d, kNew, kOld);
        assertLe(_abs(revised), _abs(d), "never widen");
        if (revised != 0) assertTrue((revised > 0) == (d > 0), "never flip");
    }

    // ---------------------------------------------------------------------- helpers

    function _take(int256 a, int256 b, int256 cap) internal pure returns (int256) {
        return ((b - a) * BeliefState.walkAverage(a, b, cap)) / ONE_X64;
    }

    function _clamp(int256 x, int256 cap) internal pure returns (int256) {
        if (x > cap) return cap;
        if (x < -cap) return -cap;
        return x;
    }

    function _abs(int256 x) internal pure returns (uint256) {
        return x < 0 ? uint256(-x) : uint256(x);
    }
}
