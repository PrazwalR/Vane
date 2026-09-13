// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
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

contract TestnetDeploy is Script {
    using PoolIdLibrary for PoolKey;

    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    uint160 internal constant EXPECTED_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    error TestnetDeploy__WrongChain(uint256 actual);
    error TestnetDeploy__AddressMismatch(address expected, address actual);
    error TestnetDeploy__FlagMismatch(uint160 expected, uint160 actual);

    function run() external {
        uint256 expectedChainId = vm.envUint("EXPECTED_CHAIN_ID");
        if (block.chainid != expectedChainId) revert TestnetDeploy__WrongChain(block.chainid);

        address poolManager = vm.envAddress("POOL_MANAGER");
        uint256 key = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(key);

        vm.startBroadcast(key);

        MockERC20 tokenA = new MockERC20("Vane Test Alpha", "VANE-A", 18);
        MockERC20 tokenB = new MockERC20("Vane Test Beta", "VANE-B", 18);
        (MockERC20 token0, MockERC20 token1) = address(tokenA) < address(tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);

        token0.mint(deployer, 1_000_000 ether);
        token1.mint(deployer, 1_000_000 ether);

        bytes memory args = abi.encode(IPoolManager(poolManager), VaneParameters.config(), deployer);
        (address mined, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, EXPECTED_FLAGS, type(VaneHook).creationCode, args);

        VaneHook hook = new VaneHook{salt: salt}(IPoolManager(poolManager), VaneParameters.config(), deployer);

        if (address(hook) != mined) revert TestnetDeploy__AddressMismatch(mined, address(hook));

        uint160 actualFlags = uint160(address(hook)) & HookMiner.FLAG_MASK;
        if (actualFlags != EXPECTED_FLAGS) {
            revert TestnetDeploy__FlagMismatch(EXPECTED_FLAGS, actualFlags);
        }

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        hook.allowPool(poolKey);
        IPoolManager(poolManager).initialize(poolKey, SQRT_PRICE_1_1);

        vm.stopBroadcast();

        console2.log("chain", block.chainid);
        console2.log("hook", address(hook));
        console2.log("token0", address(token0));
        console2.log("token1", address(token1));
        console2.log("poolId");
        console2.logBytes32(PoolId.unwrap(poolKey.toId()));
    }
}
