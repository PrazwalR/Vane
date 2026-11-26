// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

import {VaneHook} from "../src/VaneHook.sol";
import {PoolState, PoolStateAux} from "../src/libraries/PoolStateLib.sol";

/// Drives real flow through the deployed hook and reports what the estimators did.
///
/// The mechanism needs on the order of four hundred blocks of flow before lambdaStar
/// exceeds lambdaAmm, which cannot be fast-forwarded on a live chain. So this is run
/// repeatedly to accumulate history, and reports the estimator state each time rather
/// than asserting a gain that is not yet reachable.
contract LiveSwaps is Script {
    using PoolIdLibrary for PoolKey;

    error LiveSwaps__WrongChain(uint256 actual, uint256 expected);

    function run() external {
        uint256 expectedChainId = vm.envUint("EXPECTED_CHAIN_ID");
        if (block.chainid != expectedChainId) revert LiveSwaps__WrongChain(block.chainid, expectedChainId);

        address hookAddress = vm.envAddress("VANE_HOOK");
        address router = vm.envAddress("SWAP_ROUTER");
        address token0 = vm.envAddress("TOKEN0");
        address token1 = vm.envAddress("TOKEN1");
        uint256 key = vm.envUint("DEPLOYER_PRIVATE_KEY");

        uint256 count = vm.envOr("SWAP_COUNT", uint256(8));
        uint256 size = vm.envOr("SWAP_SIZE", uint256(25 ether));

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hookAddress)
        });
        PoolId id = poolKey.toId();
        VaneHook hook = VaneHook(payable(hookAddress));

        _report("before", hook, id, token0, token1);

        vm.startBroadcast(key);
        for (uint256 i = 0; i < count; i++) {
            bool zeroForOne = (i / 2) % 2 == 0;
            PoolSwapTest(router)
                .swap(
                    poolKey,
                    SwapParams({
                        zeroForOne: zeroForOne,
                        amountSpecified: -int256(size),
                        sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                    }),
                    PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                    ""
                );
        }
        vm.stopBroadcast();

        _report("after", hook, id, token0, token1);
    }

    function _report(string memory label, VaneHook hook, PoolId id, address token0, address token1) internal view {
        PoolState memory s = hook.poolState(id);
        PoolStateAux memory a = hook.poolStateAux(id);
        console2.log("---", label, "---");
        console2.log("  block          ", block.number);
        console2.log("  lastTick       ", s.lastTick);
        console2.log("  lastBlock      ", s.lastBlock);
        console2.log("  varOneX32      ", s.varOneX32);
        console2.log("  flowVarUnitsSq ", s.flowVarUnitsSq);
        console2.log("  saturated      ", s.saturated);
        console2.log("  checkpointBlock", a.checkpointBlock);
        console2.log("  varKX32        ", a.varKX32);
        console2.log("  kappaX64       ", a.kappaX64);
        console2.log("  flowAccum      ", a.flowAccum);
        console2.log("  belief         ", s.deltaX64);
        console2.log("  reserve0       ", hook.reserveOf(Currency.wrap(token0)));
        console2.log("  reserve1       ", hook.reserveOf(Currency.wrap(token1)));
    }
}
