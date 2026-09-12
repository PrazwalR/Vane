// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";

library GasGuard {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    string internal constant SKIP_FLAG = "VANE_SKIP_GAS_ASSERTIONS";

    function assertionsEnabled() internal view returns (bool) {
        return !VM.envOr(SKIP_FLAG, false);
    }
}
