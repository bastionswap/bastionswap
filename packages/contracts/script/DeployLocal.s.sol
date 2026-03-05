// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {BastionHook} from "../src/hooks/BastionHook.sol";
import {EscrowVault} from "../src/core/EscrowVault.sol";
import {InsurancePool} from "../src/core/InsurancePool.sol";
import {TriggerOracle} from "../src/core/TriggerOracle.sol";
import {ReputationEngine} from "../src/core/ReputationEngine.sol";
import {BastionRouter} from "../src/router/BastionRouter.sol";
import {TestToken} from "../src/test/TestToken.sol";
import {IEscrowVault} from "../src/interfaces/IEscrowVault.sol";
import {ITriggerOracle} from "../src/interfaces/ITriggerOracle.sol";

import {BastionDeployer} from "./BastionDeployer.sol";
import {HookMiner} from "./HookMiner.sol";

/// @title DeployLocal
/// @notice Deploy BastionSwap to a Base mainnet fork (Anvil).
///         PoolManager already exists on the fork — only BastionSwap contracts are deployed.
contract DeployLocal is Script {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // Base mainnet Uniswap V4 PoolManager
    address constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;

    // Hook permission flags
    uint160 constant HOOK_FLAGS =
        uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);

    // Pool parameters
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    int24 constant TICK_LOWER = -887220;
    int24 constant TICK_UPPER = 887220;

    // Anvil default accounts
    uint256 constant DEPLOYER_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    address constant TRADER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;

    struct Addresses {
        address factory;
        address escrow;
        address insurance;
        address trigger;
        address reputation;
        address hook;
        bytes32 salt;
        bytes hookCreationCode;
    }

    struct Deployed {
        address hook;
        address router;
        address btt;
        address lpRouter;
        address swapRouter;
    }

    function run() external {
        address deployer = vm.addr(DEPLOYER_KEY);

        console2.log("=== BastionSwap Local Deployment (Base Fork) ===");
        console2.log("Chain ID:", block.chainid);
        console2.log("Deployer:", deployer);
        console2.log("PoolManager:", POOL_MANAGER);

        require(POOL_MANAGER.code.length > 0, "PoolManager not found on fork");

        vm.startBroadcast(DEPLOYER_KEY);

        Addresses memory a = _precompute(deployer);
        Deployed memory d = _deployContracts(deployer, a);
        _createPoolAndSeed(deployer, d);

        vm.stopBroadcast();

        _printSummary(a, d);
    }

    function _deployContracts(address deployer, Addresses memory a) internal returns (Deployed memory d) {
        console2.log("Hook target address:", a.hook);

        BastionDeployer factory = new BastionDeployer();
        require(address(factory) == a.factory, "Factory address mismatch");

        EscrowVault escrowVault = new EscrowVault(a.hook, a.trigger, a.reputation);
        require(address(escrowVault) == a.escrow, "EscrowVault address mismatch");

        InsurancePool insurancePool = new InsurancePool(a.hook, a.trigger, deployer, a.escrow, deployer);
        require(address(insurancePool) == a.insurance, "InsurancePool address mismatch");

        TriggerOracle triggerOracle = new TriggerOracle(a.hook, a.escrow, a.insurance, deployer, a.reputation);
        require(address(triggerOracle) == a.trigger, "TriggerOracle address mismatch");

        ReputationEngine reputationEngine = new ReputationEngine(a.hook, a.escrow, a.trigger);
        require(address(reputationEngine) == a.reputation, "ReputationEngine address mismatch");

        address deployedHook = factory.deploy(a.salt, a.hookCreationCode);
        require(deployedHook == a.hook, "Hook address mismatch");

        BastionRouter router = new BastionRouter(IPoolManager(POOL_MANAGER));
        TestToken btt = new TestToken("Bastion Test Token", "BTT", 18, 1_000_000e18);
        PoolModifyLiquidityTest lpRouter = new PoolModifyLiquidityTest(IPoolManager(POOL_MANAGER));
        PoolSwapTest swapRouter = new PoolSwapTest(IPoolManager(POOL_MANAGER));

        d.hook = deployedHook;
        d.router = address(router);
        d.btt = address(btt);
        d.lpRouter = address(lpRouter);
        d.swapRouter = address(swapRouter);
    }

    function _createPoolAndSeed(address deployer, Deployed memory d) internal {
        PoolKey memory poolKey = PoolKey(
            Currency.wrap(address(0)),
            Currency.wrap(d.btt),
            3000,
            60,
            IHooks(d.hook)
        );

        IPoolManager(POOL_MANAGER).initialize(poolKey, SQRT_PRICE_1_1);
        console2.log("Pool initialized: BTT/ETH");

        TestToken btt = TestToken(d.btt);
        btt.approve(d.lpRouter, type(uint256).max);
        btt.approve(d.swapRouter, type(uint256).max);
        btt.approve(d.router, type(uint256).max);

        bytes memory hookData = _buildHookData(deployer, d.btt);

        PoolModifyLiquidityTest(d.lpRouter).modifyLiquidity{value: 10 ether}(
            poolKey,
            ModifyLiquidityParams({
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                liquidityDelta: 10e18,
                salt: 0
            }),
            hookData
        );
        console2.log("Issuer LP added with escrow");

        (bool sent,) = d.hook.call{value: 1 ether}("");
        require(sent, "ETH transfer to hook failed");

        btt.transfer(TRADER, 100_000e18);
        console2.log("Sent 100,000 BTT to trader:", TRADER);

        PoolSwapTest(d.swapRouter).swap{value: 0.01 ether}(
            poolKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -0.01 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        console2.log("Test swap executed: 0.01 ETH -> BTT");
    }

    function _buildHookData(address deployer, address token) internal pure returns (bytes memory) {
        IEscrowVault.VestingStep[] memory vesting = new IEscrowVault.VestingStep[](3);
        vesting[0] = IEscrowVault.VestingStep({timeOffset: 7 days, basisPoints: 1000});
        vesting[1] = IEscrowVault.VestingStep({timeOffset: 30 days, basisPoints: 3000});
        vesting[2] = IEscrowVault.VestingStep({timeOffset: 90 days, basisPoints: 10000});

        IEscrowVault.IssuerCommitment memory commitment = IEscrowVault.IssuerCommitment({
            dailyWithdrawLimit: 500,
            lockDuration: 90 days,
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

        return abi.encode(deployer, token, vesting, commitment, triggerConfig);
    }

    function _printSummary(Addresses memory a, Deployed memory d) internal pure {
        console2.log("");
        console2.log("=== Deployment Complete ===");
        console2.log("PoolManager:      ", POOL_MANAGER);
        console2.log("BastionDeployer:  ", a.factory);
        console2.log("BastionHook:      ", a.hook);
        console2.log("EscrowVault:      ", a.escrow);
        console2.log("InsurancePool:    ", a.insurance);
        console2.log("TriggerOracle:    ", a.trigger);
        console2.log("ReputationEngine: ", a.reputation);
        console2.log("BastionRouter:    ", d.router);
        console2.log("TestToken (BTT):  ", d.btt);
        console2.log("LPRouter (test):  ", d.lpRouter);
        console2.log("SwapRouter (test):", d.swapRouter);
    }

    function _precompute(address deployer) internal view returns (Addresses memory a) {
        uint64 nonce = vm.getNonce(deployer);
        console2.log("Deployer nonce:", nonce);

        a.factory = vm.computeCreateAddress(deployer, nonce);
        a.escrow = vm.computeCreateAddress(deployer, nonce + 1);
        a.insurance = vm.computeCreateAddress(deployer, nonce + 2);
        a.trigger = vm.computeCreateAddress(deployer, nonce + 3);
        a.reputation = vm.computeCreateAddress(deployer, nonce + 4);

        a.hookCreationCode = abi.encodePacked(
            type(BastionHook).creationCode,
            abi.encode(POOL_MANAGER, a.escrow, a.insurance, a.trigger, a.reputation)
        );

        console2.log("Mining CREATE2 salt for hook flags...");
        (a.hook, a.salt) = HookMiner.find(a.factory, HOOK_FLAGS, a.hookCreationCode, 0);
        require(uint160(a.hook) & 0x3FFF == HOOK_FLAGS, "Hook flag mismatch");
    }
}
