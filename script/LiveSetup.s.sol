// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {VaneHook} from "../src/VaneHook.sol";

/// Stands up the deployed pool for live observation: routers, liquidity, reserves.
///
/// v4 has no public routers on Sepolia, so the two test routers are deployed here. They
/// are the same ones the local suite uses, which keeps the live path identical to the
/// tested one.
contract LiveSetup is Script {
    using PoolIdLibrary for PoolKey;

    error LiveSetup__WrongChain(uint256 actual, uint256 expected);

    function run() external {
        uint256 expectedChainId = vm.envUint("EXPECTED_CHAIN_ID");
        if (block.chainid != expectedChainId) revert LiveSetup__WrongChain(block.chainid, expectedChainId);

        address poolManager = vm.envAddress("POOL_MANAGER");
        address hookAddress = vm.envAddress("VANE_HOOK");
        address token0 = vm.envAddress("TOKEN0");
        address token1 = vm.envAddress("TOKEN1");
        uint256 key = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(key);

        uint256 liquidity = vm.envOr("LIVE_LIQUIDITY", uint256(50_000 ether));
        uint256 reserve = vm.envOr("LIVE_RESERVE", uint256(5_000 ether));

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hookAddress)
        });

        vm.startBroadcast(key);

        PoolSwapTest swapRouter = new PoolSwapTest(IPoolManager(poolManager));
        PoolModifyLiquidityTest liquidityRouter = new PoolModifyLiquidityTest(IPoolManager(poolManager));

        MockERC20(token0).approve(address(liquidityRouter), type(uint256).max);
        MockERC20(token1).approve(address(liquidityRouter), type(uint256).max);
        MockERC20(token0).approve(address(swapRouter), type(uint256).max);
        MockERC20(token1).approve(address(swapRouter), type(uint256).max);
        MockERC20(token0).approve(hookAddress, type(uint256).max);
        MockERC20(token1).approve(hookAddress, type(uint256).max);

        liquidityRouter.modifyLiquidity(poolKey, ModifyLiquidityParams(-60000, 60000, int256(liquidity), 0), "");

        VaneHook hook = VaneHook(payable(hookAddress));
        hook.fundReserve(Currency.wrap(token0), reserve);
        hook.fundReserve(Currency.wrap(token1), reserve);

        vm.stopBroadcast();

        console2.log("swapRouter", address(swapRouter));
        console2.log("liquidityRouter", address(liquidityRouter));
        console2.log("liquidity added", liquidity);
        console2.log("reserve0", hook.reserveOf(Currency.wrap(token0)));
        console2.log("reserve1", hook.reserveOf(Currency.wrap(token1)));
        console2.log("deployer", deployer);
    }
}
