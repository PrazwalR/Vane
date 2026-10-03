// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

import {VaneHook} from "../src/VaneHook.sol";
import {VaneConfig, VaneConfigLib} from "../src/config/VaneConfig.sol";
import {HookMiner} from "./HookMiner.sol";
import {VaneParameters} from "./VaneParameters.sol";

contract DeployVane is Script {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    uint160 internal constant EXPECTED_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    error DeployVane__WrongChain(uint256 actual, uint256 expected);
    error DeployVane__PoolManagerHasNoCode(address poolManager);
    error DeployVane__Create2DeployerMissing(address deployer);
    error DeployVane__FlagMismatch(address mined, uint160 expected, uint160 actual);
    error DeployVane__AddressMismatch(address expected, address actual);

    function run() external returns (VaneHook hook) {
        // This is the chain-agnostic deploy path, so it is the one that can reach mainnet.
        // The guard is mandatory rather than optional: a stale POOL_MANAGER in the
        // environment plus a different --rpc-url otherwise deploys an owner-privileged
        // hook to the wrong chain, pointed at an address that may not be a PoolManager.
        uint256 expectedChainId = vm.envUint("EXPECTED_CHAIN_ID");
        if (block.chainid != expectedChainId) {
            revert DeployVane__WrongChain(block.chainid, expectedChainId);
        }

        address poolManager = vm.envAddress("POOL_MANAGER");
        if (poolManager.code.length == 0) revert DeployVane__PoolManagerHasNoCode(poolManager);

        // Without the deterministic-deployment proxy the salt is mined against an address
        // that will never be produced, and the run reverts only after burning the deploy.
        if (CREATE2_DEPLOYER.code.length == 0) {
            revert DeployVane__Create2DeployerMissing(CREATE2_DEPLOYER);
        }
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address owner = vm.addr(deployerKey);

        VaneConfig memory config = VaneParameters.config();

        VaneConfigLib.validate(config);

        bytes memory constructorArgs = abi.encode(IPoolManager(poolManager), config, owner);
        (address minedAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, EXPECTED_FLAGS, type(VaneHook).creationCode, constructorArgs);

        console2.log("pool manager  :", poolManager);
        console2.log("owner         :", owner);
        console2.log("mined address :", minedAddress);
        console2.log("salt          :", uint256(salt));
        console2.log("loop gain     :", VaneConfigLib.loopGainX32(config));

        vm.startBroadcast(deployerKey);
        hook = new VaneHook{salt: salt}(IPoolManager(poolManager), config, owner);
        vm.stopBroadcast();

        if (address(hook) != minedAddress) {
            revert DeployVane__AddressMismatch(minedAddress, address(hook));
        }

        uint160 actual = uint160(address(hook)) & HookMiner.FLAG_MASK;
        if (actual != EXPECTED_FLAGS) {
            revert DeployVane__FlagMismatch(address(hook), EXPECTED_FLAGS, actual);
        }

        console2.log("deployed      :", address(hook));
        console2.log("owner         :", hook.owner());
    }
}
