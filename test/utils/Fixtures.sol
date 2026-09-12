// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaneConfig} from "../../src/config/VaneConfig.sol";
import {VaneParameters} from "../../script/VaneParameters.sol";

library Fixtures {
    uint256 internal constant ONE_X32 = 1 << 32;
    uint256 internal constant ONE_X64 = 1 << 64;

    function config() internal pure returns (VaneConfig memory) {
        return VaneParameters.config();
    }
}
