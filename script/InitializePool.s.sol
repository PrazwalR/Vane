// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";

import {VaneHook} from "../src/VaneHook.sol";

/// @notice Allowlists a pool on a deployed hook and initialises it.
/// @dev Order matters. beforeInitialize rejects any pool that is not allowlisted, so the
///      allowlist call has to land first; initialising first would simply revert. The
///      allowlist exists because a hook attached to an attacker's pool could otherwise
///      drive state the hook keys by pool id (threat 8).
contract InitializePool is Script {
    using PoolIdLibrary for PoolKey;

    error InitializePool__CurrenciesOutOfOrder(address currency0, address currency1);

    function run() external {
        address poolManager = vm.envAddress("POOL_MANAGER");
        address hookAddress = vm.envAddress("VANE_HOOK");
        address token0 = vm.envAddress("TOKEN0");
        address token1 = vm.envAddress("TOKEN1");
        uint24 fee = uint24(vm.envUint("POOL_FEE"));
        int24 tickSpacing = int24(vm.envInt("TICK_SPACING"));
        uint160 sqrtPriceX96 = uint160(vm.envUint("SQRT_PRICE_X96"));
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        // v4 requires currency0 < currency1; a reversed pair produces a different pool id
        // and would silently initialise a pool nobody intended.
        if (token0 >= token1) revert InitializePool__CurrenciesOutOfOrder(token0, token1);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hookAddress)
        });

        vm.startBroadcast(deployerKey);
        VaneHook(hookAddress).allowPool(key);
        IPoolManager(poolManager).initialize(key, sqrtPriceX96);
        vm.stopBroadcast();

        console2.log("pool initialised");
        console2.log("  hook  :", hookAddress);
        console2.logBytes32(PoolId.unwrap(key.toId()));
    }
}
