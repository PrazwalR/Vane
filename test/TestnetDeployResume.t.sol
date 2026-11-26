// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core-test/utils/Deployers.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolIdLibrary, PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {VaneHook} from "../src/VaneHook.sol";
import {HookMiner} from "../script/HookMiner.sol";
import {VaneParameters} from "../script/VaneParameters.sol";
import {TestnetDeploy} from "../script/TestnetDeploy.s.sol";

/// The testnet deploy has to survive being interrupted. Redeploying to Sepolia in November
/// 2026 died twice part-way, because forge simulates an older gas schedule than the chain
/// runs, and a rerun of a script that unconditionally deploys would then revert on the
/// hook's CREATE2 address already holding code.
contract TestnetDeployResumeTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint160 internal constant FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );
    uint256 internal constant KEY = 0xA11CE;

    TestnetDeploy internal script;
    address internal deployer;
    uint256 internal salt;
    address internal mined;

    function setUp() public {
        deployFreshManagerAndRouters();
        script = new TestnetDeploy();
        deployer = vm.addr(KEY);

        bytes memory args = abi.encode(IPoolManager(address(manager)), VaneParameters.config(), deployer);
        bytes32 s;
        (mined, s) = HookMiner.find(CREATE2_DEPLOYER, FLAGS, type(VaneHook).creationCode, args);
        salt = uint256(s);
    }

    function _initialized(PoolKey memory key) internal view returns (bool) {
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(key.toId());
        return sqrtPriceX96 != 0;
    }

    function test_AFullRunLandsTheHookAtTheMinedAddress() public {
        TestnetDeploy.Deployment memory d = script.deploy(address(manager), KEY, salt, address(0), address(0));

        assertEq(address(d.hook), mined, "the hook lands where the salt says");
        assertEq(d.hook.owner(), deployer, "owned by the deployer");
        assertTrue(d.hook.allowlisted(d.poolKey.toId()), "the pool is allowlisted");
        assertTrue(_initialized(d.poolKey), "and initialised");
        assertLt(uint160(address(d.token0)), uint160(address(d.token1)), "tokens are ordered as v4 requires");
    }

    /// A rerun after a complete run is a no-op apart from minting: nothing reverts and
    /// nothing is redeployed or re-allowlisted.
    function test_ARerunReusesEverything() public {
        TestnetDeploy.Deployment memory first = script.deploy(address(manager), KEY, salt, address(0), address(0));
        TestnetDeploy.Deployment memory second =
            script.deploy(address(manager), KEY, salt, address(first.token0), address(first.token1));

        assertEq(address(second.hook), address(first.hook), "the same hook");
        assertEq(address(second.token0), address(first.token0), "the same token0");
        assertEq(address(second.token1), address(first.token1), "the same token1");
        assertEq(PoolId.unwrap(second.poolKey.toId()), PoolId.unwrap(first.poolKey.toId()), "the same pool");
        assertTrue(_initialized(second.poolKey), "still initialised");
    }

    /// The shape of the Sepolia failure: the hook landed and nothing after it did.
    function test_ARunThatDiedAfterTheHookIsCompletedByARerun() public {
        bytes memory initCode = abi.encodePacked(
            type(VaneHook).creationCode, abi.encode(IPoolManager(address(manager)), VaneParameters.config(), deployer)
        );
        (bool ok,) = CREATE2_DEPLOYER.call(abi.encodePacked(bytes32(salt), initCode));
        assertTrue(ok && mined.code.length > 0, "precondition: the hook is already deployed");

        TestnetDeploy.Deployment memory d = script.deploy(address(manager), KEY, salt, address(0), address(0));

        assertEq(address(d.hook), mined, "the existing hook is reused rather than redeployed");
        assertTrue(d.hook.allowlisted(d.poolKey.toId()), "the rerun allowlists the pool");
        assertTrue(_initialized(d.poolKey), "and initialises it");
    }
}
