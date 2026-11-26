// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaneConfig} from "../src/config/VaneConfig.sol";

library VaneParameters {
    uint256 internal constant ONE_X32 = 1 << 32;
    uint256 internal constant ONE_X64 = 1 << 64;

    function config() internal pure returns (VaneConfig memory c) {
        c = VaneConfig({
            // Calibrated in the replay simulator (sim/calibrate.sh, 288 runs over decay, horizon,
            // trend and seed): a 5-block horizon is the optimum, with 3 and 10 both worse, and
            // slower decay helps with diminishing returns. 1/200 is within 4% of the best decay
            // tried while halving how long a belief outlives the flow that formed it.
            thetaX64: uint64(ONE_X64 / 200),
            varLambdaX32: uint64((uint256(99) * ONE_X32) / 100),
            flowLambdaX32: uint64((uint256(99) * ONE_X32) / 100),
            horizonK: 5,
            controllerGainX32: uint64(ONE_X32 / 100),
            controllerLeakX32: uint64(ONE_X32 / 100),
            controllerDeadbandX32: 0,
            kappaMaxX64: uint64(ONE_X64 / 1000),
            deltaMaxX64: uint64(ONE_X64 / 100),
            deltaDustX64: uint64(ONE_X64 / 1_000_000),
            maxTickDelta: 2000,
            flowUnit: 1e12,
            reserveTargetDefault: 100e18,
            gainScaleX32: uint64(ONE_X32 / 4)
        });
    }
}
