// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Deployers} from "v4-core-test/utils/Deployers.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

import {VaneHook} from "../src/VaneHook.sol";

/// @notice Measures the hook's marginal gas cost against the plain-pool baseline, so the
///         section 6.5 budget of 45,000 gas for beforeSwap + afterSwap can be checked
///         rather than assumed.
contract GasTest is Test, Deployers {
    VaneHook internal hook;
    PoolKey internal vaneKey;
    PoolKey internal plainKey;

    int256 internal constant DELTA_100BPS = int256(uint256(1 << 64)) / 100;
    uint256 internal constant GAS_BUDGET = 45_000;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        address hookAddr = address(flags ^ (0x6666 << 144));
        deployCodeTo("VaneHook.sol:VaneHook", abi.encode(manager), hookAddr);
        hook = VaneHook(hookAddr);

        vaneKey = PoolKey(currency0, currency1, 3000, 60, IHooks(hookAddr));
        hook.allowPool(vaneKey);
        manager.initialize(vaneKey, SQRT_PRICE_1_1);

        plainKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(0)));
        manager.initialize(plainKey, SQRT_PRICE_1_1);

        ModifyLiquidityParams memory liq = ModifyLiquidityParams(-60000, 60000, 1000 ether, 0);
        modifyLiquidityRouter.modifyLiquidity(vaneKey, liq, "");
        modifyLiquidityRouter.modifyLiquidity(plainKey, liq, "");

        deal(Currency.unwrap(currency0), address(hook), 10_000 ether);
        deal(Currency.unwrap(currency1), address(hook), 10_000 ether);
    }

    function _measure(PoolKey memory key) internal returns (uint256 gasUsed) {
        uint256 before = gasleft();
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        gasUsed = before - gasleft();
    }

    /// @notice The dust path: with the belief at zero the hook returns early, so the
    ///         marginal cost is only the callback dispatch. Most swaps take this path.
    function test_Gas_ZeroBeliefPath() public {
        // Warm both pools so storage-warming does not distort the comparison.
        _measure(plainKey);
        _measure(vaneKey);

        uint256 plainGas = _measure(plainKey);
        uint256 vaneGas = _measure(vaneKey);

        console2.log("plain pool swap gas     ", plainGas);
        console2.log("vane pool swap gas      ", vaneGas);
        console2.log("marginal hook cost      ", vaneGas - plainGas);

        assertLt(vaneGas - plainGas, GAS_BUDGET, "zero-belief path must fit the budget");
    }

    /// @notice The active path: belief nonzero, so the hook computes the offset and
    ///         settles a token transfer. This is the expensive case that must fit.
    function test_Gas_ActiveBeliefPath() public {
        _measure(plainKey);
        hook.setBelief(vaneKey, DELTA_100BPS);
        _measure(vaneKey);

        uint256 plainGas = _measure(plainKey);
        uint256 vaneGas = _measure(vaneKey);

        console2.log("plain pool swap gas     ", plainGas);
        console2.log("vane pool swap gas      ", vaneGas);
        console2.log("marginal hook cost      ", vaneGas - plainGas);
        console2.log("budget                  ", GAS_BUDGET);

        assertLt(vaneGas - plainGas, GAS_BUDGET, "active path must fit the 45k budget");
    }
}
