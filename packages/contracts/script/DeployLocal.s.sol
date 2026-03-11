// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
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
import {BastionSwapRouter} from "../src/router/BastionSwapRouter.sol";
import {BastionPositionRouter} from "../src/router/BastionPositionRouter.sol";
import {TestToken} from "../src/test/TestToken.sol";
import {IEscrowVault} from "../src/interfaces/IEscrowVault.sol";
import {ITriggerOracle} from "../src/interfaces/ITriggerOracle.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";

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

    // Base WETH and USDC
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    // Permit2 canonical address (same on all chains)
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // Hook permission flags
    uint160 constant HOOK_FLAGS =
        uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);

    // Pool parameters
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    int24 constant TICK_LOWER = -887220;
    int24 constant TICK_UPPER = 887220;

    // Anvil default accounts
    uint256 constant DEPLOYER_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 constant TRADER_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
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
        address swapRouter;
        address positionRouter;
        address btt;
        address alpha;
        address lpRouter;
        address testSwapRouter;
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

        TriggerOracle triggerOracle = new TriggerOracle(a.hook, a.escrow, a.insurance, deployer, a.reputation, deployer);
        require(address(triggerOracle) == a.trigger, "TriggerOracle address mismatch");

        ReputationEngine reputationEngine = new ReputationEngine(a.hook, a.escrow, a.trigger);
        require(address(reputationEngine) == a.reputation, "ReputationEngine address mismatch");

        address deployedHook = factory.deploy(a.salt, a.hookCreationCode);
        require(deployedHook == a.hook, "Hook address mismatch");

        BastionSwapRouter swapRouter = new BastionSwapRouter(IPoolManager(POOL_MANAGER), ISignatureTransfer(PERMIT2));
        BastionPositionRouter positionRouter = new BastionPositionRouter(IPoolManager(POOL_MANAGER), ISignatureTransfer(PERMIT2));

        // Wire up hook ↔ router cross-references
        BastionHook(payable(deployedHook)).setBastionRouter(address(positionRouter));
        swapRouter.setBastionHook(deployedHook);
        positionRouter.setBastionHook(deployedHook);

        TestToken btt = new TestToken("Bastion Test Token", "BTT", 18, 1_000_000e18);
        TestToken alpha = new TestToken("Alpha Token", "ALPHA", 18, 1_000_000e18);
        PoolModifyLiquidityTest lpRouter = new PoolModifyLiquidityTest(IPoolManager(POOL_MANAGER));
        PoolSwapTest testSwapRouter = new PoolSwapTest(IPoolManager(POOL_MANAGER));

        d.hook = deployedHook;
        d.swapRouter = address(swapRouter);
        d.positionRouter = address(positionRouter);
        d.btt = address(btt);
        d.alpha = address(alpha);
        d.lpRouter = address(lpRouter);
        d.testSwapRouter = address(testSwapRouter);
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
        btt.approve(d.testSwapRouter, type(uint256).max);
        btt.approve(d.positionRouter, type(uint256).max);
        btt.approve(PERMIT2, type(uint256).max);

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

        // ALPHA: approve router + Permit2 and send to trader
        TestToken alpha = TestToken(d.alpha);
        alpha.approve(d.positionRouter, type(uint256).max);
        alpha.approve(PERMIT2, type(uint256).max);
        alpha.approve(d.lpRouter, type(uint256).max);
        alpha.transfer(TRADER, 100_000e18);
        console2.log("Sent 100,000 ALPHA to trader:", TRADER);

        // Create ETH/ALPHA pool
        PoolKey memory alphaPoolKey = PoolKey(
            Currency.wrap(address(0)),
            Currency.wrap(d.alpha),
            3000,
            60,
            IHooks(d.hook)
        );

        IPoolManager(POOL_MANAGER).initialize(alphaPoolKey, SQRT_PRICE_1_1);
        console2.log("Pool initialized: ALPHA/ETH");

        bytes memory alphaHookData = _buildHookData(deployer, d.alpha);

        PoolModifyLiquidityTest(d.lpRouter).modifyLiquidity{value: 10 ether}(
            alphaPoolKey,
            ModifyLiquidityParams({
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                liquidityDelta: 10e18,
                salt: 0
            }),
            alphaHookData
        );
        console2.log("ALPHA/ETH LP added with escrow");

        PoolSwapTest(d.testSwapRouter).swap{value: 0.01 ether}(
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

        // General LP: Trader adds liquidity via BastionPositionRouter V2
        vm.stopBroadcast();
        vm.startBroadcast(TRADER_KEY);

        TestToken(d.btt).approve(d.positionRouter, type(uint256).max);
        BastionPositionRouter(payable(d.positionRouter)).addLiquidityV2{value: 1 ether}(
            poolKey,
            0, 0, // full-range
            1 ether, 10_000e18,
            block.timestamp + 3600
        );
        console2.log("Trader general LP added via addLiquidityV2");

        vm.stopBroadcast();
        vm.startBroadcast(DEPLOYER_KEY);
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
            slowRugCumulativeThreshold: 8000,
            weeklyDumpWindowSeconds: 604800,
            weeklyDumpThresholdPercent: 5000
        });

        return abi.encode(deployer, token, lockDuration, vestingDuration, commitment, triggerConfig);
    }

    function _printSummary(Addresses memory a, Deployed memory d) internal pure {
        console2.log("");
        console2.log("=== Deployment Complete ===");
        console2.log("PoolManager:           ", POOL_MANAGER);
        console2.log("BastionDeployer:       ", a.factory);
        console2.log("BastionHook:           ", a.hook);
        console2.log("EscrowVault:           ", a.escrow);
        console2.log("InsurancePool:         ", a.insurance);
        console2.log("TriggerOracle:         ", a.trigger);
        console2.log("ReputationEngine:      ", a.reputation);
        console2.log("BastionSwapRouter:     ", d.swapRouter);
        console2.log("BastionPositionRouter: ", d.positionRouter);
        console2.log("TestToken (BTT):       ", d.btt);
        console2.log("TestToken (ALPHA):     ", d.alpha);
        console2.log("LPRouter (test):       ", d.lpRouter);
        console2.log("SwapRouter (test):     ", d.testSwapRouter);
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
            abi.encode(POOL_MANAGER, a.escrow, a.insurance, a.trigger, a.reputation, deployer, WETH, USDC)
        );

        console2.log("Mining CREATE2 salt for hook flags...");
        (a.hook, a.salt) = HookMiner.find(a.factory, HOOK_FLAGS, a.hookCreationCode, 0);
        require(uint160(a.hook) & 0x3FFF == HOOK_FLAGS, "Hook flag mismatch");
    }
}
