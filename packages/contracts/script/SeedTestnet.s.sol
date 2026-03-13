// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {BastionHook} from "../src/hooks/BastionHook.sol";
import {BastionPositionRouter} from "../src/router/BastionPositionRouter.sol";
import {TestToken} from "../src/test/TestToken.sol";
import {IEscrowVault} from "../src/interfaces/IEscrowVault.sol";
import {ITriggerOracle} from "../src/interfaces/ITriggerOracle.sol";

/// @title SeedTestnet
/// @notice Deploy test tokens and create pools on Base Sepolia.
contract SeedTestnet is Script {
    // Base Sepolia addresses (v5 deployment — 3-window trigger)
    address constant POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    address constant HOOK = 0x61590C0544B562571AAad49e255496a0a0350AC8;
    address constant ROUTER = 0x7Bcf5618c55AadDD2451b93102285267622Bb67A;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    // Price: 1 ETH = 1,000,000,000 tokens (sqrt(1e9) * 2^96)
    uint160 constant SQRT_PRICE_1B = 2505414483750479227146068685750272;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        console2.log("=== Seed Base Sepolia ===");
        console2.log("Deployer:", deployer);
        console2.log("Balance:", deployer.balance);

        vm.startBroadcast(deployerKey);

        // 0. Lower min base amount for ETH to 0.0001 ETH
        BastionHook(payable(HOOK)).updateMinBaseAmount(address(0), 0.00009 ether);
        console2.log("Min base amount for ETH lowered to 0.00009 ETH");

        // 1. Deploy test tokens
        TestToken btt = new TestToken("Bastion Test Token", "BTT", 18, 1_000_000e18);
        TestToken alpha = new TestToken("Alpha Token", "ALPHA", 18, 1_000_000e18);
        console2.log("BTT:", address(btt));
        console2.log("ALPHA:", address(alpha));

        // 2. Approve router for both tokens
        btt.approve(ROUTER, type(uint256).max);
        alpha.approve(ROUTER, type(uint256).max);

        // 3. Create ETH/BTT pool via BastionRouter
        bytes memory bttHookData = _buildHookData(deployer, address(btt));
        BastionPositionRouter(payable(ROUTER)).createPool{value: 0.0002 ether}(
            address(btt),
            address(0),    // ETH as base token
            3000,
            100_000e18,    // 100k BTT
            SQRT_PRICE_1B,
            bttHookData
        );
        console2.log("Pool created: ETH/BTT");

        // 4. Create ETH/ALPHA pool via BastionRouter
        bytes memory alphaHookData = _buildHookData(deployer, address(alpha));
        BastionPositionRouter(payable(ROUTER)).createPool{value: 0.0002 ether}(
            address(alpha),
            address(0),    // ETH as base token
            3000,
            100_000e18,    // 100k ALPHA
            SQRT_PRICE_1B,
            alphaHookData
        );
        console2.log("Pool created: ETH/ALPHA");

        // 5. Fund hook with ETH for insurance payouts (skip if insufficient balance)
        if (deployer.balance > 0.001 ether) {
            (bool ok,) = HOOK.call{value: 0.001 ether}("");
            if (ok) console2.log("Hook funded with 0.001 ETH");
        }

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== Seeding Complete ===");
        console2.log("BTT:", address(btt));
        console2.log("ALPHA:", address(alpha));
        console2.log("Anyone can call btt.faucet() / alpha.faucet() for 1,000 tokens");
    }

    function _buildHookData(address deployer, address token) internal pure returns (bytes memory) {
        uint40 lockDuration = 7 days;
        uint40 vestingDuration = 83 days;

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

        return abi.encode(deployer, token, lockDuration, vestingDuration, commitment, triggerConfig);
    }
}
