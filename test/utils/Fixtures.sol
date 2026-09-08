// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaneConfig} from "../../src/config/VaneConfig.sol";

/// @notice Shared config for tests, so a parameter change lands in one place.
/// @dev These values are placeholders pending the M6 calibration described in section
///      12 Q4: theta must come from the target pool's observed arbitrage latency and K
///      from the horizon where the plain pool's variance ratio is closest to 1. They are
///      internally consistent and inside every validator bound, which is all a unit test
///      needs, but they are not claimed to be correct for any real pool.
library Fixtures {
    uint256 internal constant ONE_X32 = 1 << 32;
    uint256 internal constant ONE_X64 = 1 << 64;

    function config() internal pure returns (VaneConfig memory c) {
        c = VaneConfig({
            thetaX64: uint64(ONE_X64 / 20), // 0.05 per block
            varLambdaX32: uint64((uint256(99) * ONE_X32) / 100), // 0.99
            flowLambdaX32: uint64((uint256(99) * ONE_X32) / 100),
            horizonK: 20,
            controllerGainX32: uint64(ONE_X32 / 100), // eta = 0.01
            controllerLeakX32: uint64(ONE_X32 / 100), // rho = 0.01, loop gain 1.0
            controllerDeadbandX32: 0,
            kappaMaxX64: uint64(ONE_X64 / 1000),
            deltaMaxX64: uint64(ONE_X64 / 100), // 100 bps
            deltaDustX64: uint64(ONE_X64 / 1_000_000),
            maxTickDelta: 2000,
            flowUnit: 1e12,
            reserveTargetDefault: 100 ether,
            safetyFactorBps: 20_000
        });
    }
}
