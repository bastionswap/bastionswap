// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @title HookMiner
/// @notice Off-chain library to brute-force a CREATE2 salt whose deployed address
///         has lower 14 bits matching the required V4 hook permission flags.
library HookMiner {
    /// @notice Find a salt such that CREATE2(deployer, salt, creationCode) has
    ///         `address & 0x3FFF == flags`.
    /// @param deployer  The CREATE2 deployer contract address.
    /// @param flags     The target hook permission bits (lower 14 bits).
    /// @param creationCode  The full creation bytecode (creationCode ++ constructorArgs).
    /// @param startSalt Starting salt value for the search.
    /// @return hookAddress The computed hook address.
    /// @return salt       The salt that produces the matching address.
    function find(address deployer, uint160 flags, bytes memory creationCode, uint256 startSalt)
        internal
        pure
        returns (address hookAddress, bytes32 salt)
    {
        bytes32 initCodeHash = keccak256(creationCode);
        for (uint256 i = startSalt; i < type(uint256).max; i++) {
            salt = bytes32(i);
            hookAddress = computeAddress(deployer, salt, initCodeHash);
            if (uint160(hookAddress) & 0x3FFF == flags) {
                return (hookAddress, salt);
            }
        }
        revert("HookMiner: salt not found");
    }

    function computeAddress(address deployer, bytes32 salt, bytes32 initCodeHash)
        internal
        pure
        returns (address)
    {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }
}
