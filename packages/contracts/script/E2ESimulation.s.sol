// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {BastionHook} from "../src/hooks/BastionHook.sol";
import {EscrowVault} from "../src/core/EscrowVault.sol";
import {InsurancePool} from "../src/core/InsurancePool.sol";
import {TriggerOracle} from "../src/core/TriggerOracle.sol";
import {IEscrowVault} from "../src/interfaces/IEscrowVault.sol";
import {IInsurancePool} from "../src/interfaces/IInsurancePool.sol";
import {ITriggerOracle} from "../src/interfaces/ITriggerOracle.sol";

/// @title E2ESimulation
/// @notice Post-deployment E2E verification script for BastionSwap on a forked anvil.
///         Reads deployed addresses from deployments/84532.json, verifies deployment integrity,
///         then runs a full lifecycle scenario: pool creation, LP, swap, and assertions.
contract E2ESimulation is Script {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // ─── Constants ────────────────────────────────────────────────────

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    uint256 constant ESCROW_AMOUNT = 100 ether;
    uint256 constant ISSUER_LP = 1000e18;
    uint256 constant TRADER_LP = 100e18;
    int24 constant TICK_LOWER = -887220;
    int24 constant TICK_UPPER = 887220;

    // ─── Deployed contracts ──────────────────────────────────────────

    IPoolManager poolManager;
    BastionHook hook;
    EscrowVault escrowVault;
    InsurancePool insurancePool;
    TriggerOracle triggerOracle;

    // ─── Test infrastructure ─────────────────────────────────────────

    PoolModifyLiquidityTest lpRouter;
    PoolSwapTest swapRouter;
    MockERC20 issuedToken;
    MockERC20 baseToken;

    PoolKey poolKey;
    PoolId poolId;
    bool issuedIsToken0;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        console2.log("=== BastionSwap E2E Simulation ===");
        console2.log("Deployer:", deployer);

        // ─── Phase A: Load & verify deployment ───────────────────────

        _loadDeployment();
        _verifyDeployment();

        // ─── Phase B: E2E scenario ───────────────────────────────────

        vm.startBroadcast(deployerKey);

        _deployTestInfra();
        _mintAndApprove(deployer);
        _initializePool(deployer);
        _addTraderLiquidity(deployer);

        // Fund hook with ETH for insurance fee collection
        (bool sent,) = address(hook).call{value: 10 ether}("");
        require(sent, "ETH transfer to hook failed");
        console2.log("Funded hook with 10 ETH for insurance fees");

        _executeBuySwap(deployer);

        vm.stopBroadcast();

        // ─── Phase C: Assertions ─────────────────────────────────────

        _runAssertions(deployer);

        console2.log("");
        console2.log("=== E2E Simulation PASSED ===");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  PHASE A: DEPLOYMENT VERIFICATION
    // ═══════════════════════════════════════════════════════════════════

    function _loadDeployment() internal {
        string memory json = vm.readFile("deployments/84532.json");

        address hookAddr = vm.parseJsonAddress(json, ".bastionHook");
        address escrowAddr = vm.parseJsonAddress(json, ".escrowVault");
        address insuranceAddr = vm.parseJsonAddress(json, ".insurancePool");
        address triggerAddr = vm.parseJsonAddress(json, ".triggerOracle");
        address reputationAddr = vm.parseJsonAddress(json, ".reputationEngine");

        // Base Sepolia PoolManager
        poolManager = IPoolManager(0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408);

        hook = BastionHook(payable(hookAddr));
        escrowVault = EscrowVault(escrowAddr);
        insurancePool = InsurancePool(insuranceAddr);
        triggerOracle = TriggerOracle(triggerAddr);

        console2.log("Loaded deployment:");
        console2.log("  BastionHook:    ", hookAddr);
        console2.log("  EscrowVault:    ", escrowAddr);
        console2.log("  InsurancePool:  ", insuranceAddr);
        console2.log("  TriggerOracle:  ", triggerAddr);
        console2.log("  ReputationEngine:", reputationAddr);
    }

    function _verifyDeployment() internal view {
        // 1. Verify hook flag bits
        uint160 hookFlags = uint160(address(hook)) & 0x3FFF;
        require(hookFlags == 0x0AC0, "Hook flag mismatch: expected 0x0AC0");
        console2.log("Hook flags verified: 0x0AC0");

        // 2. Verify immutable references
        require(address(hook.poolManager()) == address(poolManager), "Hook poolManager mismatch");
        require(address(hook.escrowVault()) == address(escrowVault), "Hook escrowVault mismatch");
        require(address(hook.insurancePool()) == address(insurancePool), "Hook insurancePool mismatch");
        require(address(hook.triggerOracle()) == address(triggerOracle), "Hook triggerOracle mismatch");
        console2.log("Immutable references verified");

        // 3. Verify InsurancePool config
        require(insurancePool.feeRate() == 100, "InsurancePool feeRate should be 100 (1%)");
        require(insurancePool.BASTION_HOOK() == address(hook), "InsurancePool hook mismatch");
        require(insurancePool.TRIGGER_ORACLE() == address(triggerOracle), "InsurancePool oracle mismatch");
        console2.log("InsurancePool config verified (feeRate=100bps)");

        console2.log("Phase A: Deployment verification PASSED");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  PHASE B: E2E SCENARIO
    // ═══════════════════════════════════════════════════════════════════

    function _deployTestInfra() internal {
        // Deploy test routers
        lpRouter = new PoolModifyLiquidityTest(poolManager);
        swapRouter = new PoolSwapTest(poolManager);
        console2.log("Deployed LP router:", address(lpRouter));
        console2.log("Deployed swap router:", address(swapRouter));

        // Deploy mock tokens
        issuedToken = new MockERC20("IssuedToken", "ISS", 18);
        baseToken = new MockERC20("BaseToken", "BASE", 18);
        console2.log("Deployed IssuedToken:", address(issuedToken));
        console2.log("Deployed BaseToken:", address(baseToken));
    }

    function _mintAndApprove(address deployer) internal {
        // Mint tokens
        issuedToken.mint(deployer, 1_000_000 ether);
        baseToken.mint(deployer, 1_000_000 ether);

        // Approve routers and hook
        issuedToken.approve(address(lpRouter), type(uint256).max);
        baseToken.approve(address(lpRouter), type(uint256).max);
        issuedToken.approve(address(swapRouter), type(uint256).max);
        baseToken.approve(address(swapRouter), type(uint256).max);
        console2.log("Minted 1M tokens each, approvals set");
    }

    function _initializePool(address deployer) internal {
        // Sort tokens for PoolKey
        Currency c0;
        Currency c1;
        if (address(issuedToken) < address(baseToken)) {
            c0 = Currency.wrap(address(issuedToken));
            c1 = Currency.wrap(address(baseToken));
            issuedIsToken0 = true;
        } else {
            c0 = Currency.wrap(address(baseToken));
            c1 = Currency.wrap(address(issuedToken));
            issuedIsToken0 = false;
        }

        poolKey = PoolKey(c0, c1, 3000, 60, IHooks(address(hook)));
        poolId = poolKey.toId();

        // Initialize pool
        poolManager.initialize(poolKey, SQRT_PRICE_1_1);
        console2.log("Pool initialized at SQRT_PRICE_1_1");

        // Issuer adds first LP with hookData → triggers escrow creation
        uint40 lockDuration = 7 days;
        uint40 vestingDuration = 83 days;

        IEscrowVault.IssuerCommitment memory commitment = IEscrowVault.IssuerCommitment({
            dailyWithdrawLimit: 0,
            maxSellPercent: 200
        });

        ITriggerOracle.TriggerConfig memory triggerConfig = ITriggerOracle.TriggerConfig({
            lpRemovalThreshold: 5000,
            dumpThresholdPercent: 300,
            dumpWindowSeconds: 86400,
            taxDeviationThreshold: 500,
            slowRugWindowSeconds: 86400,
            slowRugCumulativeThreshold: 8000,
            weeklyDumpWindowSeconds: 604800,
            weeklyDumpThresholdPercent: 1500
        });

        bytes memory hookData = abi.encode(
            deployer, address(issuedToken), lockDuration, vestingDuration, commitment, triggerConfig
        );

        lpRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                liquidityDelta: int256(ISSUER_LP),
                salt: 0
            }),
            hookData
        );
        console2.log("Issuer LP added with escrow hookData");
    }

    function _addTraderLiquidity(address) internal {
        lpRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                liquidityDelta: int256(TRADER_LP),
                salt: bytes32(uint256(1))
            }),
            ""
        );
        console2.log("Trader LP added (no hookData)");
    }

    function _executeBuySwap(address) internal {
        // Buy issued token (swap base → issued)
        bool zeroForOne = !issuedIsToken0;

        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -1 ether,
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        console2.log("Buy swap executed: -1 ether exact input");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  PHASE C: ASSERTIONS
    // ═══════════════════════════════════════════════════════════════════

    function _runAssertions(address deployer) internal view {
        console2.log("");
        console2.log("--- Assertions ---");

        // 1. getPoolInfo
        (address issuer, uint256 escrowId, address issuedTok, uint256 totalLiq) = hook.getPoolInfo(poolId);
        require(issuer == deployer, "FAIL: issuer mismatch");
        require(escrowId > 0, "FAIL: escrowId should be > 0");
        require(issuedTok == address(issuedToken), "FAIL: issuedToken mismatch");
        require(totalLiq > 0, "FAIL: totalLiquidity should be > 0");
        console2.log("  getPoolInfo: issuer=%s, escrowId=%d", deployer, escrowId);
        console2.log("  issuedToken:", issuedTok);
        console2.log("  totalLiquidity:", totalLiq);

        // 2. isIssuer
        require(hook.isIssuer(poolId, deployer), "FAIL: isIssuer should be true");
        console2.log("  isIssuer(deployer) = true");

        // 3. EscrowStatus
        IEscrowVault.EscrowStatus memory es = escrowVault.getEscrowStatus(escrowId);
        require(es.totalLiquidity > 0, "FAIL: escrow totalLiquidity should be > 0");
        require(es.remainingLiquidity == es.totalLiquidity, "FAIL: escrow remainingLiquidity mismatch");
        require(es.removedLiquidity == 0, "FAIL: escrow removedLiquidity should be 0");
        console2.log("  EscrowStatus: totalLiquidity=%d, remainingLiquidity=%d", uint256(es.totalLiquidity), uint256(es.remainingLiquidity));

        // 4. InsurancePool status
        IInsurancePool.PoolStatus memory ps = insurancePool.getPoolStatus(poolId);
        require(ps.balance > 0, "FAIL: insurance pool balance should be > 0");
        require(!ps.isTriggered, "FAIL: pool should not be triggered");
        console2.log("  InsurancePool: balance=%d (fees collected)", ps.balance);
        console2.log("  InsurancePool: isTriggered=false");

        console2.log("--- All assertions PASSED ---");
    }
}
