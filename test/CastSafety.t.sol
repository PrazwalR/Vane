// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {OffsetDelta} from "../src/libraries/OffsetDelta.sol";

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
}
