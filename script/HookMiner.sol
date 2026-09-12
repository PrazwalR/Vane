// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

library HookMiner {
    uint160 internal constant FLAG_MASK = uint160((1 << 14) - 1);

    uint256 internal constant MAX_SALT = 160_444;

    error HookMiner__SaltNotFound();

    function find(address deployer, uint160 flags, bytes memory creationCode, bytes memory constructorArgs)
        internal
        view
        returns (address hookAddress, bytes32 salt)
    {
        bytes memory initCode = abi.encodePacked(creationCode, constructorArgs);

        for (uint256 i = 0; i < MAX_SALT; i++) {
            hookAddress = computeAddress(deployer, i, initCode);

            if (uint160(hookAddress) & FLAG_MASK == flags && hookAddress.code.length == 0) {
                return (hookAddress, bytes32(i));
            }
        }
        revert HookMiner__SaltNotFound();
    }

    function computeAddress(address deployer, uint256 salt, bytes memory initCode) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xFF), deployer, salt, keccak256(initCode))))));
    }
}
