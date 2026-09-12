// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title HookMiner
/// @notice Finds a CREATE2 salt whose resulting address carries the hook permission
///         flags v4 requires.
/// @dev v4 encodes a hook's permissions in the low 14 bits of its own address, so the
///      deployment address is not incidental: a hook deployed to the wrong address
///      simply will not be called for the callbacks it implements, and nothing reverts
///      to say so. The salt search is therefore part of deployment, not a convenience.
///
///      Deploy-time only. This is never called on chain and lives under script/ rather
///      than src/ so it cannot be reached from the hook.
library HookMiner {
    /// @notice The low 14 bits of an address that v4 reads as permission flags.
    uint160 internal constant FLAG_MASK = uint160((1 << 14) - 1);

    /// @notice Salts to try before giving up.
    /// @dev A given flag combination occurs roughly once every 2^14 = 16,384 salts, so
    ///      this bound is about ten expected hits. Exhausting it means the flags or the
    ///      creation code are wrong, not that the search was unlucky.
    uint256 internal constant MAX_SALT = 160_444;

    error HookMiner__SaltNotFound();

    /// @notice Finds the first salt producing an address with exactly `flags` set.
    /// @param deployer The CREATE2 deployer that will send the deployment.
    /// @param flags The permission bits the address must carry.
    /// @param creationCode The hook's creation code.
    /// @param constructorArgs ABI-encoded constructor arguments.
    /// @return hookAddress The address the deployment will land on.
    /// @return salt The salt that produces it.
    function find(address deployer, uint160 flags, bytes memory creationCode, bytes memory constructorArgs)
        internal
        view
        returns (address hookAddress, bytes32 salt)
    {
        bytes memory initCode = abi.encodePacked(creationCode, constructorArgs);

        for (uint256 i = 0; i < MAX_SALT; i++) {
            hookAddress = computeAddress(deployer, i, initCode);
            // The flags must match EXACTLY, not merely be present: a stray high bit
            // would enable a callback the hook does not implement, and v4 would revert
            // every swap when it called into a missing selector.
            if (uint160(hookAddress) & FLAG_MASK == flags && hookAddress.code.length == 0) {
                return (hookAddress, bytes32(i));
            }
        }
        revert HookMiner__SaltNotFound();
    }

    /// @notice The CREATE2 address for a given deployer, salt and init code.
    function computeAddress(address deployer, uint256 salt, bytes memory initCode) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xFF), deployer, salt, keccak256(initCode))))));
    }
}
