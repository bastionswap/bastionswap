// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {BastionHook} from "../src/hooks/BastionHook.sol";
import {BastionPositionRouter} from "../src/router/BastionPositionRouter.sol";
import {TestToken} from "../src/test/TestToken.sol";
import {IEscrowVault} from "../src/interfaces/IEscrowVault.sol";
import {ITriggerOracle} from "../src/interfaces/ITriggerOracle.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";

/// @title SeedTestnet
/// @notice Deploy test tokens and create pools on Base Sepolia.
contract SeedTestnet is Script {
    // Base Sepolia addresses (v4 deployment — split routers)
    address constant POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    address constant HOOK = 0x3E1fb370C3C38Ed972566E2eaF6fbBe6E9b44AC8;
    address constant ROUTER = 0x6c195167000Be5ADbA07A4D43e68ba1D3a7C269b;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        console2.log("=== Seed Base Sepolia ===");
        console2.log("Deployer:", deployer);
        console2.log("Balance:", deployer.balance);

        vm.startBroadcast(deployerKey);

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
        BastionPositionRouter(payable(ROUTER)).createPool{value: 0.002 ether}(
            address(btt),
            address(0),    // ETH as base token
            3000,
            100_000e18,    // 100k BTT
            SQRT_PRICE_1_1,
            bttHookData
        );
        console2.log("Pool created: ETH/BTT");

        // 4. Create ETH/ALPHA pool via BastionRouter
        bytes memory alphaHookData = _buildHookData(deployer, address(alpha));
        BastionPositionRouter(payable(ROUTER)).createPool{value: 0.002 ether}(
            address(alpha),
            address(0),    // ETH as base token
            3000,
            100_000e18,    // 100k ALPHA
            SQRT_PRICE_1_1,
            alphaHookData
        );
        console2.log("Pool created: ETH/ALPHA");

        // 5. Fund hook with ETH for insurance payouts
        (bool ok,) = HOOK.call{value: 0.001 ether}("");
        require(ok, "ETH to hook failed");
        console2.log("Hook funded with 0.001 ETH");

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
            lpRemovalThreshold: 5000,
            dumpThresholdPercent: 3000,
            dumpWindowSeconds: 86400,
            taxDeviationThreshold: 500,
            slowRugWindowSeconds: 86400,
            slowRugCumulativeThreshold: 8000
        });

        return abi.encode(deployer, token, lockDuration, vestingDuration, commitment, triggerConfig);
    }
}
