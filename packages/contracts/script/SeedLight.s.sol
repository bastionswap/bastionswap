// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {BastionPositionRouter} from "../src/router/BastionPositionRouter.sol";
import {TestToken} from "../src/test/TestToken.sol";
import {IEscrowVault} from "../src/interfaces/IEscrowVault.sol";
import {ITriggerOracle} from "../src/interfaces/ITriggerOracle.sol";

/// @title SeedLight — Deploy 2 test tokens, create 2 pools, report addresses
contract SeedLight is Script {
    address constant POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    address constant HOOK = 0x61590C0544B562571AAad49e255496a0a0350AC8;
    address constant ROUTER = 0x7Bcf5618c55AadDD2451b93102285267622Bb67A;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        console2.log("Deployer:", deployer);
        console2.log("Balance:", deployer.balance);

        vm.startBroadcast(deployerKey);

        // Deploy 2 test tokens (1M each, faucet-enabled)
        TestToken btt = new TestToken("Bastion Test Token", "BTT", 18, 1_000_000e18);
        TestToken alpha = new TestToken("Alpha Token", "ALPHA", 18, 1_000_000e18);

        // Approve position router
        btt.approve(ROUTER, type(uint256).max);

        // Create ETH/BTT pool with 0.0001 ETH + 1000 BTT
        bytes memory hookData = _buildHookData(deployer, address(btt));
        BastionPositionRouter(payable(ROUTER)).createPool{value: 0.0002 ether}(
            address(btt),
            address(0), // ETH as base token
            3000,
            1000e18,    // 1000 BTT
            SQRT_PRICE_1_1,
            hookData
        );

        // Create ETH/ALPHA pool with 0.0001 ETH + 500 ALPHA
        alpha.approve(ROUTER, type(uint256).max);
        bytes memory hookData2 = _buildHookData(deployer, address(alpha));
        BastionPositionRouter(payable(ROUTER)).createPool{value: 0.0002 ether}(
            address(alpha),
            address(0), // ETH as base token
            3000,
            500e18,     // 500 ALPHA
            SQRT_PRICE_1_1,
            hookData2
        );

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== Seeding Complete ===");
        console2.log("BTT (pool created):", address(btt));
        console2.log("ALPHA (pool created):", address(alpha));
        console2.log("Call btt.faucet() / alpha.faucet() for 1000 tokens");
    }

    function _buildHookData(address deployer, address token) internal pure returns (bytes memory) {
        IEscrowVault.IssuerCommitment memory commitment = IEscrowVault.IssuerCommitment({
            dailyWithdrawLimit: 500,
            maxSellPercent: 300
        });

        ITriggerOracle.TriggerConfig memory triggerConfig = ITriggerOracle.TriggerConfig({
            dailyLpRemovalBps: 1000,
            weeklyLpRemovalBps: 3000,
            dumpThresholdPercent: 300,
            dumpWindowSeconds: 86400,
            taxDeviationThreshold: 500,
            weeklyDumpWindowSeconds: 604800,
            weeklyDumpThresholdPercent: 1500
        });

        return abi.encode(deployer, token, uint40(7 days), uint40(83 days), commitment, triggerConfig);
    }
}
