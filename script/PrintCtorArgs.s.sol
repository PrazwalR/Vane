// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {VaneParameters} from "./VaneParameters.sol";

/// Emits the exact ABI-encoded constructor arguments the deployed hook was built with, so
/// block-explorer verification uses the same bytes rather than a hand re-encoding of a
/// sixteen-field struct.
contract PrintCtorArgs is Script {
    function run() external view {
        address poolManager = vm.envAddress("POOL_MANAGER");
        address owner = vm.envAddress("HOOK_OWNER");
        console2.log("constructor args:");
        console2.logBytes(abi.encode(IPoolManager(poolManager), VaneParameters.config(), owner));
    }
}
