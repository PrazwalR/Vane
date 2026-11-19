// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {VaneHook} from "../src/VaneHook.sol";
import {HookMiner} from "./HookMiner.sol";
import {VaneParameters} from "./VaneParameters.sol";

contract TestnetDeploy is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    uint160 internal constant EXPECTED_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    error TestnetDeploy__WrongChain(uint256 actual);
    error TestnetDeploy__AddressMismatch(address expected, address actual);
    error TestnetDeploy__FlagMismatch(uint160 expected, uint160 actual);

    struct Deployment {
        VaneHook hook;
        MockERC20 token0;
        MockERC20 token1;
        PoolKey poolKey;
    }

    function run() external returns (Deployment memory d) {
        uint256 expectedChainId = vm.envUint("EXPECTED_CHAIN_ID");
        if (block.chainid != expectedChainId) revert TestnetDeploy__WrongChain(block.chainid);

        d = deploy(
            vm.envAddress("POOL_MANAGER"),
            vm.envUint("DEPLOYER_PRIVATE_KEY"),
            vm.envOr("VANE_SALT", type(uint256).max),
            vm.envOr("TOKEN0", address(0)),
            vm.envOr("TOKEN1", address(0))
        );

        console2.log("chain", block.chainid);
        console2.log("hook", address(d.hook));
        console2.log("token0", address(d.token0));
        console2.log("token1", address(d.token1));
        console2.log("poolId");
        console2.logBytes32(PoolId.unwrap(d.poolKey.toId()));
    }

    /// Everything `run` does after reading the environment, taking its inputs as arguments
    /// so a test can drive it without process-wide environment variables.
    ///
    /// Resumable. On a chain whose gas schedule is newer than the one forge simulates, a run
    /// can die part-way, and every step that already landed is skipped on a rerun with the
    /// same salt and tokens. `givenSalt` of `type(uint256).max` means mine one here, which
    /// costs an RPC round trip per candidate address on a fork; mining off chain and passing
    /// it in avoids that. `given0` and `given1` reuse an earlier run's tokens when both are
    /// set.
    function deploy(address poolManager, uint256 key, uint256 givenSalt, address given0, address given1)
        public
        returns (Deployment memory d)
    {
        address deployer = vm.addr(key);
        vm.startBroadcast(key);

        (d.token0, d.token1) = _tokens(deployer, given0, given1);
        d.hook = _hook(poolManager, deployer, givenSalt);

        d.poolKey = PoolKey({
            currency0: Currency.wrap(address(d.token0)),
            currency1: Currency.wrap(address(d.token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(d.hook))
        });

        // Both are skipped when an earlier run got that far. Re-allowlisting would not be
        // harmless on a live pool: it discards the pool's belief.
        if (!d.hook.allowlisted(d.poolKey.toId())) d.hook.allowPool(d.poolKey);
        (uint160 sqrtPriceX96,,,) = IPoolManager(poolManager).getSlot0(d.poolKey.toId());
        if (sqrtPriceX96 == 0) IPoolManager(poolManager).initialize(d.poolKey, SQRT_PRICE_1_1);

        vm.stopBroadcast();
    }

    /// Deploys two test tokens, or reuses the given pair. Mints the deployer a balance
    /// either way.
    function _tokens(address deployer, address given0, address given1)
        internal
        returns (MockERC20 token0, MockERC20 token1)
    {
        MockERC20 tokenA;
        MockERC20 tokenB;
        if (given0 != address(0) && given1 != address(0)) {
            tokenA = MockERC20(given0);
            tokenB = MockERC20(given1);
        } else {
            tokenA = new MockERC20("Vane Test Alpha", "VANE-A", 18);
            tokenB = new MockERC20("Vane Test Beta", "VANE-B", 18);
        }
        (token0, token1) = address(tokenA) < address(tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);

        token0.mint(deployer, 1_000_000 ether);
        token1.mint(deployer, 1_000_000 ether);
    }

    /// Deploys the hook at its mined address, or reuses it if an earlier run already did.
    /// Reuse is sound because the address commits to the exact init code, so code already
    /// there is this hook with this owner, pool manager and configuration.
    function _hook(address poolManager, address deployer, uint256 givenSalt) internal returns (VaneHook hook) {
        bytes memory args = abi.encode(IPoolManager(poolManager), VaneParameters.config(), deployer);
        address mined;
        bytes32 salt;
        if (givenSalt != type(uint256).max) {
            salt = bytes32(givenSalt);
            mined = HookMiner.computeAddressFromHash(
                CREATE2_DEPLOYER, givenSalt, keccak256(abi.encodePacked(type(VaneHook).creationCode, args))
            );
        } else {
            (mined, salt) = HookMiner.find(CREATE2_DEPLOYER, EXPECTED_FLAGS, type(VaneHook).creationCode, args);
        }

        if (mined.code.length == 0) {
            hook = new VaneHook{salt: salt}(IPoolManager(poolManager), VaneParameters.config(), deployer);
            if (address(hook) != mined) revert TestnetDeploy__AddressMismatch(mined, address(hook));
        } else {
            hook = VaneHook(mined);
            console2.log("hook already deployed by an earlier run; reusing it");
        }

        uint160 actualFlags = uint160(address(hook)) & HookMiner.FLAG_MASK;
        if (actualFlags != EXPECTED_FLAGS) revert TestnetDeploy__FlagMismatch(EXPECTED_FLAGS, actualFlags);
    }
}
