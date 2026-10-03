// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {OffsetDelta} from "../src/libraries/OffsetDelta.sol";
import {VaneConfig, VaneConfigLib} from "../src/config/VaneConfig.sol";
import {VaneParameters} from "../script/VaneParameters.sol";

contract CastSafetyTest is Test {
    int256 internal constant DELTA_MAX = int256(uint256(1 << 64)) / 100;

    function testFuzz_OffsetAmount_AlwaysFitsInt128(uint256 rawNotional, int256 rawDelta) public pure {
        int256 d = bound(rawDelta, -DELTA_MAX, DELTA_MAX);
        uint256 amount = OffsetDelta.offsetAmount(rawNotional, d);
        assertLe(amount, uint256(uint128(type(int128).max)), "offset must always fit the int128 v4 delta");
    }

    function test_OffsetAmount_DeclinesBeyondInt128Notional() public pure {
        assertEq(
            OffsetDelta.offsetAmount(uint256(uint128(type(int128).max)) + 1, DELTA_MAX),
            0,
            "a notional beyond the int128 delta domain must yield no offset"
        );
        assertEq(OffsetDelta.offsetAmount(type(uint256).max, DELTA_MAX), 0, "and must not revert");
    }

    function test_OffsetAmount_AtHugeNotional() public {
        uint256[4] memory notionals =
            [uint256(1e18), uint256(type(uint128).max), uint256(type(uint192).max), type(uint256).max];

        for (uint256 i = 0; i < notionals.length; i++) {
            try this.callOffset(notionals[i], DELTA_MAX) returns (uint256 amount) {
                console2.log("notional", notionals[i]);
                console2.log("  amount", amount);
                console2.log("  exceeds int128?", amount > uint256(uint128(type(int128).max)) ? 1 : 0);
            } catch {
                console2.log("notional", notionals[i]);
                console2.log("  REVERTED");
            }
        }
    }

    function callOffset(uint256 notional, int256 d) external pure returns (uint256) {
        return OffsetDelta.offsetAmount(notional, d);
    }

    /// The narrowing casts in `_advanceBlock` carry no runtime check, because a revert
    /// inside afterSwap bricks the pool permanently — a failure this project has already
    /// hit once, when a checked varK cast took a pool down. Their safety therefore rests
    /// on a validation rule in a different file, and these tests pin that chain so the
    /// argument cannot quietly stop holding.
    function test_ValidationBoundsTheBeliefCast() public {
        VaneConfig memory c = VaneParameters.config();

        assertLe(
            uint256(c.deltaMaxX64),
            uint256(uint64(type(int64).max)),
            "deltaMaxX64 must fit int64 or the belief cast truncates"
        );

        // And the rule is enforced, not merely satisfied by today's parameters.
        c.deltaMaxX64 = uint64(type(int64).max) + 1;
        vm.expectRevert(VaneConfigLib.Vane__DeltaMaxTooLarge.selector);
        this.validateExternally(c);
    }

    /// The gain cast is bounded by kappaMaxX64, which is itself a uint64, so the cast is
    /// width-preserving by construction. This states that rather than leaving a reader to
    /// rediscover it from the type declaration.
    function test_GainCastIsWidthPreserving() public pure {
        VaneConfig memory c = VaneParameters.config();
        assertLe(uint256(c.kappaMaxX64), uint256(type(uint64).max), "kappaMaxX64 is a uint64 by declaration");
        assertGt(c.kappaMaxX64, 0, "and must be non-zero for the gain to exist at all");
    }

    function validateExternally(VaneConfig memory c) external pure {
        VaneConfigLib.validate(c);
    }
}
