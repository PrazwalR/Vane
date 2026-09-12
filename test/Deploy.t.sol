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

/// @notice The deployment path itself, exercised rather than assumed. A hook whose
///         address carries the wrong flags is never called for the callbacks it
///         implements, and nothing reverts to say so, so this is checked with a real
///         CREATE2 deployment and a real swap.
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

    /// @dev Deploys through the canonical CREATE2 factory rather than with a salted
    ///      `new`, because that is what the script does. A salted `new` inside a test
    ///      uses the test contract as the deployer, so the salt mined for the factory
    ///      produces a different address and the test would validate a path nobody runs.
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

    /// @notice The shipped parameter set must pass its own validator. A deploy script
    ///         that mines for a minute and then reverts in the constructor is a slow way
    ///         to discover a bad parameter.
    function test_Deploy_ShippedParametersAreValid() public pure {
        VaneConfigLib.validate(VaneParameters.config());
    }

    /// @notice The mined address must carry exactly the five permissions in section 6.3.
    ///         Extra flags make v4 call into selectors the hook does not implement.
    function test_Deploy_MinedAddressCarriesExactlyTheExpectedFlags() public {
        VaneHook hook = _mineAndDeploy();

        uint160 actual = uint160(address(hook)) & HookMiner.FLAG_MASK;
        console2.log("hook address:", address(hook));
        console2.log("flags expected:", EXPECTED_FLAGS);
        console2.log("flags actual  :", actual);

        assertEq(actual, EXPECTED_FLAGS, "flags must match exactly, not merely overlap");
    }

    /// @notice None of the liquidity or donate permissions may be set. Invariant 11: a
    ///         hook on add or remove liquidity could trap LPs, so the address must make
    ///         that structurally impossible rather than rely on the callbacks being
    ///         no-ops.
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

    /// @notice The full path: mine, deploy, allowlist, initialise, add liquidity, swap.
    ///         This is the M0 exit criterion.
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

    /// @notice beforeInitialize must reject a pool that was not allowlisted, so the
    ///         deploy script's ordering is enforced by the contract rather than by
    ///         convention. Threat 8.
    function test_Deploy_InitializeRevertsWithoutAllowlist() public {
        VaneHook hook = _mineAndDeploy();
        PoolKey memory key = PoolKey(currency0, currency1, 3000, 60, IHooks(address(hook)));

        vm.expectRevert();
        manager.initialize(key, SQRT_PRICE_1_1);
    }

    /// @notice Only the deployer may allowlist pools.
    function test_Deploy_AllowlistIsOwnerOnly() public {
        VaneHook hook = _mineAndDeploy();
        PoolKey memory key = PoolKey(currency0, currency1, 3000, 60, IHooks(address(hook)));

        vm.prank(address(0xBEEF));
        vm.expectRevert(VaneHook.Vane__NotOwner.selector);
        hook.allowPool(key);
    }
}
