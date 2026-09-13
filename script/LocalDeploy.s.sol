// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {VaneHook} from "../src/VaneHook.sol";
import {HookMiner} from "./HookMiner.sol";
import {VaneParameters} from "./VaneParameters.sol";

contract LocalDeploy is Script {
    using PoolIdLibrary for PoolKey;

    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    uint160 internal constant EXPECTED_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    function run() external {
        uint256 key = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(key);

        vm.startBroadcast(key);

        PoolManager manager = new PoolManager(deployer);

        MockERC20 tokenA = new MockERC20("Vane Test A", "VTA", 18);
        MockERC20 tokenB = new MockERC20("Vane Test B", "VTB", 18);
        (MockERC20 token0, MockERC20 token1) =
            address(tokenA) < address(tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);

        bytes memory args =
            abi.encode(IPoolManager(address(manager)), VaneParameters.config(), deployer);
        (address mined, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, EXPECTED_FLAGS, type(VaneHook).creationCode, args);

        VaneHook hook =
            new VaneHook{salt: salt}(IPoolManager(address(manager)), VaneParameters.config(), deployer);
        require(address(hook) == mined, "address mismatch");

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        hook.allowPool(poolKey);
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        vm.stopBroadcast();

        console2.log("POOL_MANAGER", address(manager));
        console2.log("VANE_HOOK", address(hook));
        console2.log("TOKEN0", address(token0));
        console2.log("TOKEN1", address(token1));
        console2.log("POOL_ID");
        console2.logBytes32(PoolId.unwrap(poolKey.toId()));
    }
}
