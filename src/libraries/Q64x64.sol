// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

library Q64x64 {
    int256 internal constant ONE_X64 = int256(1) << 64;

    uint256 internal constant ONE_X64_U = uint256(1) << 64;

    uint256 internal constant ONE_X32 = uint256(1) << 32;

    int256 internal constant TICK_LN_X64 = 1_844_582_179_799_040;

    uint256 internal constant TICK_LN_SQ_X64 = 184_448_995_684;

    error Q64x64__CastOverflow();

    function sqrt(uint256 x) internal pure returns (uint256 z) {
        if (x == 0) return 0;
        if (x < 4) return 1;

        uint256 bits;
        uint256 t = x;
        if (t >= 1 << 128) {
            t >>= 128;
            bits += 128;
        }
        if (t >= 1 << 64) {
            t >>= 64;
            bits += 64;
        }
        if (t >= 1 << 32) {
            t >>= 32;
            bits += 32;
        }
        if (t >= 1 << 16) {
            t >>= 16;
            bits += 16;
        }
        if (t >= 1 << 8) {
            t >>= 8;
            bits += 8;
        }
        if (t >= 1 << 4) {
            t >>= 4;
            bits += 4;
        }
        if (t >= 1 << 2) {
            t >>= 2;
            bits += 2;
        }
        if (t >= 1 << 1) {
            bits += 1;
        }

        z = 1 << ((bits >> 1) + 1);

        uint256 y = (z + x / z) >> 1;
        while (y < z) {
            z = y;
            y = (x / y + y) >> 1;
        }
    }

    function sqrtX32(uint256 aX32) internal pure returns (uint256) {
        return sqrt(aX32 << 32);
    }

    function x32ToX64(uint256 aX32) internal pure returns (uint256) {
        return aX32 << 32;
    }

    function ewmaX32(uint256 oldX32, uint256 sampleX32, uint256 lambdaX32) internal pure returns (uint256) {
        uint256 keep = lambdaX32 * oldX32;
        uint256 add = (ONE_X32 - lambdaX32) * sampleX32;
        return (keep + add) >> 32;
    }

    function ewmaSigned(int256 oldValue, int256 sample, uint256 lambdaX32) internal pure returns (int256) {
        int256 keep = int256(lambdaX32) * oldValue;
        int256 add = int256(ONE_X32 - lambdaX32) * sample;
        return (keep + add) >> 32;
    }

    function toUint64(uint256 x) internal pure returns (uint64) {
        if (x > type(uint64).max) revert Q64x64__CastOverflow();
        return uint64(x);
    }

    function toInt64(int256 x) internal pure returns (int64) {
        if (x > type(int64).max || x < type(int64).min) revert Q64x64__CastOverflow();
        return int64(x);
    }

    function abs(int256 x) internal pure returns (uint256) {
        return x < 0 ? uint256(-x) : uint256(x);
    }
}
