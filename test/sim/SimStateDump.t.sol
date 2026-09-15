// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core-test/utils/Deployers.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {VaneHook} from "../../src/VaneHook.sol";
import {Fixtures} from "../utils/Fixtures.sol";

/// Builds a funded VANE pool alongside a plain control pool on identical liquidity, then
/// writes the whole EVM state to disk for the Rust replay engine to load.
///
/// The setup lives in Solidity rather than Rust on purpose. Deploying the v4 stack, mining
/// a hook address, initialising pools and seeding liquidity is delicate, and this path is
/// already exercised by the rest of the suite. Reproducing it in Rust would be a second
/// implementation of the part most likely to diverge silently.
contract SimStateDumpTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    uint256 internal LIQUIDITY = vm.envOr("SIM_LIQUIDITY", uint256(1_000_000 ether));
    uint256 internal RESERVE = vm.envOr("SIM_RESERVE", uint256(1000 ether));
    int24 internal RANGE = int24(int256(vm.envOr("SIM_RANGE", uint256(3000))));
    uint24 internal FEE = uint24(vm.envOr("SIM_FEE", uint256(3000)));
    int24 internal SPACING = int24(int256(vm.envOr("SIM_SPACING", uint256(60))));

    function test_DumpSimState() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        address hookAddr = address(flags ^ (0x5151 << 144));
        deployCodeTo("VaneHook.sol:VaneHook", abi.encode(manager, Fixtures.config(), address(this)), hookAddr);
        VaneHook hook = VaneHook(payable(hookAddr));

        PoolKey memory vaneKey = PoolKey(currency0, currency1, FEE, SPACING, IHooks(hookAddr));
        hook.allowPool(vaneKey, uint64(vm.envOr("SIM_FLOW_UNIT", uint256(1e15))));
        manager.initialize(vaneKey, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(vaneKey, ModifyLiquidityParams(-RANGE, RANGE, int256(LIQUIDITY), 0), "");

        PoolKey memory plainKey = PoolKey(currency0, currency1, FEE, SPACING, IHooks(address(0)));
        manager.initialize(plainKey, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(plainKey, ModifyLiquidityParams(-RANGE, RANGE, int256(LIQUIDITY), 0), "");

        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        hook.fundReserve(currency0, RESERVE);
        hook.fundReserve(currency1, RESERVE);

        // The replay engine trades as this address, so it needs balance and standing
        // approvals already in the dumped state.
        address trader = address(0x7EA0E8);
        MockERC20(Currency.unwrap(currency0)).mint(trader, 100_000_000 ether);
        MockERC20(Currency.unwrap(currency1)).mint(trader, 100_000_000 ether);
        vm.startPrank(trader);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        string memory manifest = string.concat(
            '{\n  "poolManager": "',
            vm.toString(address(manager)),
            '",\n  "swapRouter": "',
            vm.toString(address(swapRouter)),
            '",\n  "vaneHook": "',
            vm.toString(hookAddr),
            '",\n  "currency0": "',
            vm.toString(Currency.unwrap(currency0)),
            '",\n  "currency1": "',
            vm.toString(Currency.unwrap(currency1)),
            '",\n  "trader": "',
            vm.toString(trader),
            '",\n  "vanePoolId": "',
            vm.toString(PoolId.unwrap(vaneKey.toId())),
            '",\n  "plainPoolId": "',
            vm.toString(PoolId.unwrap(plainKey.toId())),
            '",\n  "fee": ',
            vm.toString(uint256(FEE)),
            ',\n  "tickSpacing": ',
            vm.toString(int256(SPACING)),
            ',\n  "liquidity": "',
            vm.toString(LIQUIDITY),
            '",\n  "reserve": "',
            vm.toString(RESERVE),
            '"\n}\n'
        );
        vm.writeFile("sim/state/manifest.json", manifest);
        vm.dumpState("sim/state/state.json");
    }
}
