// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

library BeliefState {
    int256 internal constant ONE_X64 = int256(1) << 64;

    function decay(int256 deltaX64, uint256 thetaX64) internal pure returns (int256) {
        int256 retained = ONE_X64 - int256(thetaX64);
        return (deltaX64 * retained) / ONE_X64;
    }

    function update(int256 deltaX64, int256 kappaX64, int256 signedFlow, int256 deltaMaxX64)
        internal
        pure
        returns (int256)
    {
        int256 next = deltaX64 + kappaX64 * signedFlow;
        if (next > deltaMaxX64) return deltaMaxX64;
        if (next < -deltaMaxX64) return -deltaMaxX64;
        return next;
    }

    /// The belief a swap is priced at: the average of the clamped belief over the segment
    /// its own flow walks, from `x0` to `x1`.
    ///
    /// This is what makes the offset conservative. The belief moves with flow,
    /// `d(delta) = kappa * dq`, so a trade that is priced at the average belief across
    /// its own path pays exactly `G(x1) - G(x0)` per unit of gain, where `G` is the
    /// antiderivative of the clamp. Summed over any sequence of trades that telescopes,
    /// and a sequence that returns the belief to where it started nets to zero. The only
    /// way to be paid by the hook is to walk back a belief somebody else paid to build.
    ///
    /// Pricing every trade at the belief stored at the start of the block instead, which
    /// is what this replaced, leaves the trade that creates a belief paying nothing for
    /// it, and lets the same actor trade back against it within one transaction.
    ///
    /// Precondition: |x0|, |x1| < 2^128 and 0 < cap <= int64.max. Every caller satisfies
    /// it with room to spare — the belief is an int64 and kappa * flow a uint64 times an
    /// int64, so |x| <= 2^127 + 2^63 — and under it the square is only taken inside the
    /// band, so no intermediate exceeds 2^192.
    function walkAverage(int256 x0, int256 x1, int256 cap) internal pure returns (int256) {
        if (x0 == x1) return _clamp(x0, cap);

        bool inside0 = x0 >= -cap && x0 <= cap;
        bool inside1 = x1 >= -cap && x1 <= cap;

        // Unchecked under the precondition above: no sum, product or difference here can
        // reach 2^255 while |x| < 2^128 and 0 < cap < 2^63.
        unchecked {
            // The integrand is linear inside the band, so the average is the midpoint. This
            // is the common case and needs neither a square nor a division by the span.
            if (inside0 && inside1) return (x0 + x1) / 2;

            // Saturated on the same side for the whole segment: the integrand is constant.
            if (x0 >= cap && x1 >= cap) return cap;
            if (x0 <= -cap && x1 <= -cap) return -cap;

            return (_antiderivative(x1, cap) - _antiderivative(x0, cap)) / (x1 - x0);
        }
    }

    /// Re-evaluates a belief at a lower gain, and never at a higher one.
    ///
    /// The belief is the gain times the decayed net flow that formed it, and what the
    /// hook can be made to pay to walk it back to zero is `delta^2 / (2 * kappa)`. A gain
    /// that falls with the belief left in place therefore raises that liability above
    /// what the builders paid in, and at a gain of zero makes it unbounded: the belief
    /// stops moving with flow, so a trader can sell into it for as long as the reserve
    /// lasts. Scaling the belief by the ratio of the gains bounds the liability by
    /// `kNew / kOld` of its previous level instead.
    ///
    /// A rising gain shrinks the liability on its own, so the belief is left alone; raising
    /// it would charge nobody for the increase.
    function revise(int256 deltaX64, uint256 kappaNewX64, uint256 kappaOldX64) internal pure returns (int256) {
        if (kappaNewX64 >= kappaOldX64) return deltaX64;
        // The caller's belief is an int64 and its gains uint64, so the product is below
        // 2^127. kappaOld is nonzero because it exceeds kappaNew.
        unchecked {
            return (deltaX64 * int256(kappaNewX64)) / int256(kappaOldX64);
        }
    }

    function scaleForReserve(int256 deltaX64, uint256 reserve, uint256 reserveTarget) internal pure returns (int256) {
        if (reserveTarget == 0 || reserve >= reserveTarget) return deltaX64;
        return (deltaX64 * int256(reserve)) / int256(reserveTarget);
    }

    function _clamp(int256 x, int256 cap) private pure returns (int256) {
        if (x > cap) return cap;
        if (x < -cap) return -cap;
        return x;
    }

    /// The integral of clamp(t, -cap, cap) from 0 to x. Even in x.
    function _antiderivative(int256 x, int256 cap) private pure returns (int256) {
        unchecked {
            int256 m = x < 0 ? -x : x;
            if (m <= cap) return (x * x) / 2;
            return cap * m - (cap * cap) / 2;
        }
    }
}
