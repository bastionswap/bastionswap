// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";

import {BastionSwapRouter} from "../src/router/BastionSwapRouter.sol";
import {BastionPositionRouter} from "../src/router/BastionPositionRouter.sol";

/// @title DeployRouter — Deploy BastionSwapRouter and BastionPositionRouter to Base Sepolia
/// @notice Minimal script. Only deploys the routers (no special permissions needed).
contract DeployRouter is Script {
    // Base Sepolia PoolManager
    address constant POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        console2.log("=== Deploy BastionRouters ===");
        console2.log("Deployer:", deployer);
        console2.log("ETH balance:", deployer.balance);

        vm.startBroadcast(deployerKey);

        ISignatureTransfer permit2 = ISignatureTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);
        BastionSwapRouter swapRouter = new BastionSwapRouter(IPoolManager(POOL_MANAGER), permit2);
        BastionPositionRouter positionRouter = new BastionPositionRouter(IPoolManager(POOL_MANAGER), permit2);

        vm.stopBroadcast();

        console2.log("BastionSwapRouter deployed at:", address(swapRouter));
        console2.log("BastionPositionRouter deployed at:", address(positionRouter));
        console2.log("PoolManager:", POOL_MANAGER);
        console2.log("Remaining ETH:", deployer.balance);
    }
}
