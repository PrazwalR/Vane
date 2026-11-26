// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Q64x64} from "../src/libraries/Q64x64.sol";
import {HorizonVariance} from "../src/libraries/HorizonVariance.sol";
import {FlowVariance} from "../src/libraries/FlowVariance.sol";

contract MicroTest is Test {
    function test_Micro_SqrtGas() public view {
        uint256[5] memory inputs = [uint256(4), 1e12, 1e24, 2 ** 96, type(uint128).max];
        for (uint256 i = 0; i < inputs.length; i++) {
            uint256 g = gasleft();
            Q64x64.sqrt(inputs[i]);
            console2.log("sqrt gas for input", inputs[i], g - gasleft());
        }
    }

    function test_Micro_SqrtX32Gas() public view {
        uint256 g = gasleft();
        Q64x64.sqrtX32(6_701_222_729_825);
        console2.log("sqrtX32 gas, realistic varK:", g - gasleft());
    }

    function test_Micro_SigmaGas() public view {
        uint256 g = gasleft();
        HorizonVariance.sigmaX64(uint64(6_701_222_729_825), 20);
        console2.log("sigmaX64 gas:", g - gasleft());
    }

    function test_Micro_NoiseScaleGas() public view {
        uint256 g = gasleft();
        FlowVariance.noiseScale(uint64(4_294_967_295_999_606));
        console2.log("noiseScale gas:", g - gasleft());
    }
}
