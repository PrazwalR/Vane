// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

library OffsetDelta {
    int256 internal constant ONE_X64 = int256(1) << 64;

    uint256 internal constant MAX_NOTIONAL = uint256(uint128(type(int128).max));

    function offsetAmount(uint256 notional, int256 deltaX64) internal pure returns (uint256 amount) {
        if (notional > MAX_NOTIONAL) return 0;

        int256 dSquaredHalfX64 = (deltaX64 * deltaX64) / (2 * ONE_X64);
        int256 factorX64 = deltaX64 + dSquaredHalfX64;

        uint256 magnitudeX64 = factorX64 < 0 ? uint256(-factorX64) : uint256(factorX64);
        amount = (notional * magnitudeX64) >> 64;
    }

    function taylorFactorX64(int256 deltaX64) internal pure returns (int256 factorX64) {
        int256 dSquaredHalfX64 = (deltaX64 * deltaX64) / (2 * ONE_X64);
        factorX64 = deltaX64 + dSquaredHalfX64;
    }
}
