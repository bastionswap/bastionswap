// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @title BastionDeployer
/// @notice Minimal CREATE2 deployer factory for deploying BastionHook at a flag-matching address.
contract BastionDeployer {
    function deploy(bytes32 salt, bytes memory creationCode) external returns (address addr) {
        assembly {
            addr := create2(0, add(creationCode, 0x20), mload(creationCode), salt)
        }
        require(addr != address(0), "CREATE2 failed");
    }
}
