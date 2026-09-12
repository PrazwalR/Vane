// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaneConfig} from "../src/config/VaneConfig.sol";

library VaneParameters {
    uint256 internal constant ONE_X32 = 1 << 32;
    uint256 internal constant ONE_X64 = 1 << 64;

    function config() internal pure returns (VaneConfig memory c) {
        c = VaneConfig({
            thetaX64: uint64(ONE_X64 / 20),
            varLambdaX32: uint64((uint256(99) * ONE_X32) / 100),
            flowLambdaX32: uint64((uint256(99) * ONE_X32) / 100),
            horizonK: 20,
            controllerGainX32: uint64(ONE_X32 / 100),
            controllerLeakX32: uint64(ONE_X32 / 100),
            controllerDeadbandX32: 0,
            kappaMaxX64: uint64(ONE_X64 / 1000),
            deltaMaxX64: uint64(ONE_X64 / 100),
            deltaDustX64: uint64(ONE_X64 / 1_000_000),
            maxTickDelta: 2000,
            flowUnit: 1e12,
            reserveTargetDefault: 100e18,
            maxEstimatorDivergenceX32: uint64(ONE_X32 / 2),
            routeBZScore: 3
        });
    }
}
