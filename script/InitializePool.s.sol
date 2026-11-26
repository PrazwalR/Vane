// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";

import {VaneHook} from "../src/VaneHook.sol";

contract InitializePool is Script {
    using PoolIdLibrary for PoolKey;

    error InitializePool__CurrenciesOutOfOrder(address currency0, address currency1);
    error InitializePool__WrongChain(uint256 actual, uint256 expected);
    error InitializePool__HookHasNoCode(address hook);

    function run() external {
        uint256 expectedChainId = vm.envUint("EXPECTED_CHAIN_ID");
        if (block.chainid != expectedChainId) {
            revert InitializePool__WrongChain(block.chainid, expectedChainId);
        }

        address poolManager = vm.envAddress("POOL_MANAGER");
        address hookAddress = vm.envAddress("VANE_HOOK");
        address token0 = vm.envAddress("TOKEN0");
        address token1 = vm.envAddress("TOKEN1");
        uint24 fee = uint24(vm.envUint("POOL_FEE"));
        int24 tickSpacing = int24(vm.envInt("TICK_SPACING"));
        uint160 sqrtPriceX96 = uint160(vm.envUint("SQRT_PRICE_X96"));
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        // Required, not defaulted. The flow unit decides where the variance accumulator
        // saturates, and a value too small for the pool's real flow holds the gain at zero
        // for the life of the pool. Every deploy script previously used the single-argument
        // allowlist call, so no production path could set it at all and every pool silently
        // inherited the global default.
        uint64 flowUnit = uint64(vm.envUint("FLOW_UNIT"));

        if (token0 >= token1) revert InitializePool__CurrenciesOutOfOrder(token0, token1);
        if (hookAddress.code.length == 0) revert InitializePool__HookHasNoCode(hookAddress);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hookAddress)
        });

        vm.startBroadcast(deployerKey);
        VaneHook(hookAddress).allowPool(key, flowUnit);
        IPoolManager(poolManager).initialize(key, sqrtPriceX96);
        vm.stopBroadcast();

        console2.log("pool initialised");
        console2.log("  hook  :", hookAddress);
        console2.log("  flowUnit (wei of currency1 per unit):", flowUnit);
        console2.logBytes32(PoolId.unwrap(key.toId()));
    }
}
