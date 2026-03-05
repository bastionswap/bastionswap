// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {BastionRouter} from "../src/router/BastionRouter.sol";

/// @title DeployRouter — Deploy BastionRouter to Base Sepolia
/// @notice Minimal script. Only deploys the router (no special permissions needed).
contract DeployRouter is Script {
    // Base Sepolia PoolManager
    address constant POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        console2.log("=== Deploy BastionRouter ===");
        console2.log("Deployer:", deployer);
        console2.log("ETH balance:", deployer.balance);

        vm.startBroadcast(deployerKey);

        BastionRouter router = new BastionRouter(IPoolManager(POOL_MANAGER));

        vm.stopBroadcast();

        console2.log("BastionRouter deployed at:", address(router));
        console2.log("PoolManager:", POOL_MANAGER);
        console2.log("Remaining ETH:", deployer.balance);
    }
}
