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
        int256 next = deltaX64 + (kappaX64 * signedFlow) / ONE_X64;
        if (next > deltaMaxX64) return deltaMaxX64;
        if (next < -deltaMaxX64) return -deltaMaxX64;
        return next;
    }

    function scaleForReserve(int256 deltaX64, uint256 reserve, uint256 reserveTarget) internal pure returns (int256) {
        if (reserveTarget == 0 || reserve >= reserveTarget) return deltaX64;
        return (deltaX64 * int256(reserve)) / int256(reserveTarget);
    }
}
