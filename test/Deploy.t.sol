// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Deployers} from "v4-core-test/utils/Deployers.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {Currency} from "v4-core/types/Currency.sol";

import {VaneHook} from "../src/VaneHook.sol";
import {VaneConfig, VaneConfigLib} from "../src/config/VaneConfig.sol";
import {HookMiner} from "../script/HookMiner.sol";
import {VaneParameters} from "../script/VaneParameters.sol";

contract DeployTest is Test, Deployers {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    uint160 internal constant EXPECTED_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG
    );

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
    }

    function _mineAndDeploy() internal returns (VaneHook hook) {
        VaneConfig memory config = VaneParameters.config();
        bytes memory args = abi.encode(IPoolManager(address(manager)), config, address(this));
        (address mined, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, EXPECTED_FLAGS, type(VaneHook).creationCode, args);

        bytes memory initCode = abi.encodePacked(type(VaneHook).creationCode, args);
        (bool ok,) = CREATE2_DEPLOYER.call(abi.encodePacked(salt, initCode));
        assertTrue(ok, "CREATE2 deployment must succeed");

        assertGt(mined.code.length, 0, "deployment must land on the mined address");
        hook = VaneHook(mined);
    }

    function test_Deploy_ShippedParametersAreValid() public pure {
        VaneConfigLib.validate(VaneParameters.config());
    }

    function test_Deploy_MinedAddressCarriesExactlyTheExpectedFlags() public {
        VaneHook hook = _mineAndDeploy();

        uint160 actual = uint160(address(hook)) & HookMiner.FLAG_MASK;
        console2.log("hook address:", address(hook));
        console2.log("flags expected:", EXPECTED_FLAGS);
        console2.log("flags actual  :", actual);

        assertEq(actual, EXPECTED_FLAGS, "flags must match exactly, not merely overlap");
    }

    function test_Deploy_LiquidityPermissionsAreStructurallyAbsent() public {
        VaneHook hook = _mineAndDeploy();
        uint160 addr = uint160(address(hook));

        assertEq(addr & Hooks.BEFORE_ADD_LIQUIDITY_FLAG, 0, "no beforeAddLiquidity");
        assertEq(addr & Hooks.AFTER_ADD_LIQUIDITY_FLAG, 0, "no afterAddLiquidity");
        assertEq(addr & Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG, 0, "no beforeRemoveLiquidity");
        assertEq(addr & Hooks.AFTER_REMOVE_LIQUIDITY_FLAG, 0, "no afterRemoveLiquidity");
        assertEq(addr & Hooks.BEFORE_DONATE_FLAG, 0, "no beforeDonate");
        assertEq(addr & Hooks.AFTER_DONATE_FLAG, 0, "no afterDonate");
    }

    function test_Deploy_EndToEndSwapThroughDeployedHook() public {
        VaneHook hook = _mineAndDeploy();

        PoolKey memory key = PoolKey(currency0, currency1, 3000, 60, IHooks(address(hook)));
        hook.allowPool(key);
        manager.initialize(key, SQRT_PRICE_1_1);

        modifyLiquidityRouter.modifyLiquidity(key, ModifyLiquidityParams(-60000, 60000, 1000 ether, 0), "");

        uint256 before = currency1.balanceOfSelf();
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertGt(currency1.balanceOfSelf(), before, "a swap must execute through the deployed hook");
    }

    function test_Deploy_InitializeRevertsWithoutAllowlist() public {
        VaneHook hook = _mineAndDeploy();
        PoolKey memory key = PoolKey(currency0, currency1, 3000, 60, IHooks(address(hook)));

        vm.expectRevert();
        manager.initialize(key, SQRT_PRICE_1_1);
    }

    function test_Deploy_AllowlistIsOwnerOnly() public {
        VaneHook hook = _mineAndDeploy();
        PoolKey memory key = PoolKey(currency0, currency1, 3000, 60, IHooks(address(hook)));

        vm.prank(address(0xBEEF));
        vm.expectRevert(VaneHook.Vane__NotOwner.selector);
        hook.allowPool(key);
    }
}
