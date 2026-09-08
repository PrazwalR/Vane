// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Q64x64
/// @notice Fixed-point primitives for the two scales VANE uses.
/// @dev Two scales are deliberate, not accidental:
///
///      Q64.64 carries the belief and kappa. Those are dimensionless log-price
///      quantities bounded well below 1, so the integer half is always zero and the
///      full 64 fractional bits are available for precision.
///
///      Q32.32 carries variance and the EWMA lambdas. Variance is measured in squared
///      ticks, which reaches ~4e6 under the tick-delta clamp; at Q64.64 that would
///      overflow a uint64 storage field, while at Q32.32 it fits with four orders of
///      magnitude to spare. Lambdas near 1 also overflow a uint64 at Q64.64
///      (0.99 * 2^64 = 1.83e19 against a 1.84e19 ceiling), which is too tight to be
///      safe; at Q32.32 the same value is 4.25e9.
library Q64x64 {
    /// @notice Q64.64 unit.
    int256 internal constant ONE_X64 = int256(1) << 64;
    /// @notice Q64.64 unit, unsigned.
    uint256 internal constant ONE_X64_U = uint256(1) << 64;
    /// @notice Q32.32 unit.
    uint256 internal constant ONE_X32 = uint256(1) << 32;

    /// @notice ln(1.0001) in Q64.64, the log-price width of one tick.
    /// @dev A tick difference is a log return scaled by this constant, which is what
    ///      lets every variance estimate stay in integer arithmetic. Derived to 60
    ///      decimal digits, truncated: 0.0000999950003333083353...
    int256 internal constant TICK_LN_X64 = 1_844_582_179_799_040;

    /// @notice ln(1.0001)^2 in Q64.64, for converting tick variance to log-price variance.
    /// @dev Var(ln P) = Var(tick) * ln(1.0001)^2.
    uint256 internal constant TICK_LN_SQ_X64 = 184_448_995_684;

    error Q64x64__CastOverflow();

    /// @notice Integer square root, floor.
    /// @dev Babylonian iteration seeded from the input's bit length. The seed matters
    ///      enormously: a naive seed of x/2 converges only after roughly log2(x)
    ///      halvings before the quadratic phase begins, which measured 14,078 gas at
    ///      x = 2^128 - 1 and made the horizon checkpoint the dominant cost in the hook.
    ///      Seeding at 2^(ceil(bitlen/2)) starts within a factor of two of the answer,
    ///      so the quadratic phase begins immediately and five or six iterations suffice
    ///      for any 256-bit input. Measured gas after the change is recorded in
    ///      docs/gas.md alongside the before figure.
    ///
    ///      The loop is retained rather than being unrolled to a fixed iteration count:
    ///      it terminates on the floor condition, which is the property the fuzz test
    ///      asserts, and unrolling would trade that guarantee for a handful of gas.
    function sqrt(uint256 x) internal pure returns (uint256 z) {
        // Inputs below 4 must be special-cased: the Babylonian step cannot descend below
        // the seed for x <= 3, so the loop would return x itself and sqrt(2) would be 2.
        if (x == 0) return 0;
        if (x < 4) return 1;

        // Bit length of x, computed by binary search over the halves.
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

        // 2^(floor(bits/2) + 1) is at least sqrt(x), so the iteration descends to the
        // floor from above and the loop's termination condition stays valid.
        z = 1 << ((bits >> 1) + 1);

        uint256 y = (z + x / z) >> 1;
        while (y < z) {
            z = y;
            y = (x / y + y) >> 1;
        }
    }

    /// @notice Square root of a Q32.32 value, returned in Q32.32.
    /// @dev sqrt(a * 2^32) = sqrt(a) * 2^16, so the input is shifted up by 32 before
    ///      the integer root to land back on the Q32.32 scale.
    function sqrtX32(uint256 aX32) internal pure returns (uint256) {
        return sqrt(aX32 << 32);
    }

    /// @notice Converts a Q32.32 value to Q64.64.
    function x32ToX64(uint256 aX32) internal pure returns (uint256) {
        return aX32 << 32;
    }

    /// @notice Exponentially weighted moving average in Q32.32.
    /// @dev new = lambda * old + (1 - lambda) * sample. The intermediate products are
    ///      computed at 256 bits because lambda * old reaches ~7e25, far above uint64.
    /// @param oldX32 Previous EWMA value, Q32.32.
    /// @param sampleX32 New observation, Q32.32.
    /// @param lambdaX32 Decay weight in Q32.32, strictly within (0, 1).
    function ewmaX32(uint256 oldX32, uint256 sampleX32, uint256 lambdaX32) internal pure returns (uint256) {
        uint256 keep = lambdaX32 * oldX32;
        uint256 add = (ONE_X32 - lambdaX32) * sampleX32;
        return (keep + add) >> 32;
    }

    /// @notice Downcasts to uint64, reverting on overflow.
    function toUint64(uint256 x) internal pure returns (uint64) {
        if (x > type(uint64).max) revert Q64x64__CastOverflow();
        return uint64(x);
    }

    /// @notice Downcasts to int64, reverting on overflow.
    function toInt64(int256 x) internal pure returns (int64) {
        if (x > type(int64).max || x < type(int64).min) revert Q64x64__CastOverflow();
        return int64(x);
    }

    /// @notice Absolute value of an int256 as uint256.
    function abs(int256 x) internal pure returns (uint256) {
        return x < 0 ? uint256(-x) : uint256(x);
    }
}
