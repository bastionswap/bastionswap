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
import {ERC20} from "solmate/src/tokens/ERC20.sol";

import {BastionHook} from "../src/hooks/BastionHook.sol";
import {EscrowVault} from "../src/core/EscrowVault.sol";
import {InsurancePool} from "../src/core/InsurancePool.sol";
import {TriggerOracle} from "../src/core/TriggerOracle.sol";
import {IEscrowVault} from "../src/interfaces/IEscrowVault.sol";
import {IInsurancePool} from "../src/interfaces/IInsurancePool.sol";
import {ITriggerOracle} from "../src/interfaces/ITriggerOracle.sol";
import {IReputationEngine} from "../src/interfaces/IReputationEngine.sol";

/// @dev Minimal ERC20 that mints entire supply to deployer in constructor (saves 1 tx per token)
contract TestToken is ERC20 {
    constructor(string memory name_, string memory symbol_, uint256 supply_) ERC20(name_, symbol_, 18) {
        _mint(msg.sender, supply_);
    }
}

/// @title TestE2E — Gas-minimized E2E verification for Base Sepolia
/// @notice Deploys test tokens, creates a Bastion pool, swaps, and verifies all protocol components.
///         Designed to run within a 0.01 ETH budget.
contract TestE2E is Script {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // ─── Constants ────────────────────────────────────────────────
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    int24 constant TICK_LOWER = -887220;
    int24 constant TICK_UPPER = 887220;

    // Minimal amounts to conserve gas
    uint256 constant TOKEN_SUPPLY = 100_000e18;
    uint256 constant ESCROW_AMOUNT = 1_000e18;
    uint256 constant LP_AMOUNT = 100e18;

    // ─── Deployed contracts ──────────────────────────────────────
    IPoolManager poolManager;
    BastionHook hook;
    EscrowVault escrowVault;
    InsurancePool insurancePool;
    TriggerOracle triggerOracle;
    IReputationEngine reputationEngine;

    // ─── Test state ──────────────────────────────────────────────
    PoolModifyLiquidityTest lpRouter;
    PoolSwapTest swapRouter;
    TestToken issuedToken;
    TestToken baseToken;
    PoolKey poolKey;
    PoolId poolId;
    bool issuedIsToken0;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        console2.log("=== BastionSwap E2E Test (Gas-Optimized) ===");
        console2.log("Deployer:", deployer);
        console2.log("ETH balance:", deployer.balance);

        // Load deployed addresses
        _loadDeployment();

        vm.startBroadcast(deployerKey);

        // ==========================================
        // Step 1: Deploy test tokens (2 txs)
        // ==========================================
        console2.log("");
        console2.log("=== Step 1: Deploy Test Tokens ===");

        issuedToken = new TestToken("Bastion Test Token", "BTT", TOKEN_SUPPLY);
        baseToken = new TestToken("Base Test Token", "BTST", TOKEN_SUPPLY);

        console2.log("IssuedToken (BTT):", address(issuedToken));
        console2.log("BaseToken (BTST):", address(baseToken));

        // ==========================================
        // Step 2: Deploy routers (2 txs)
        // ==========================================
        console2.log("");
        console2.log("=== Step 2: Deploy Routers ===");

        lpRouter = new PoolModifyLiquidityTest(poolManager);
        swapRouter = new PoolSwapTest(poolManager);

        console2.log("LP Router:", address(lpRouter));
        console2.log("Swap Router:", address(swapRouter));

        // ==========================================
        // Step 3: Approvals (4 txs)
        // ==========================================
        console2.log("");
        console2.log("=== Step 3: Approvals ===");

        // issuedToken: approve to hook (escrow transfer) + lpRouter (LP)
        issuedToken.approve(address(hook), type(uint256).max);
        issuedToken.approve(address(lpRouter), type(uint256).max);
        // baseToken: approve to lpRouter (LP) + swapRouter (swap)
        baseToken.approve(address(lpRouter), type(uint256).max);
        baseToken.approve(address(swapRouter), type(uint256).max);

        console2.log("Approvals set (4 txs)");

        // ==========================================
        // Step 4: Initialize pool (1 tx)
        // ==========================================
        console2.log("");
        console2.log("=== Step 4: Initialize Pool ===");

        _buildPoolKey();
        poolManager.initialize(poolKey, SQRT_PRICE_1_1);

        console2.log("Pool initialized. PoolId:", vm.toString(PoolId.unwrap(poolId)));

        // ==========================================
        // Step 5: Fund hook with ETH for insurance (1 tx)
        // ==========================================
        console2.log("");
        console2.log("=== Step 5: Fund Hook ===");

        (bool sent,) = address(hook).call{value: 0.001 ether}("");
        require(sent, "ETH transfer to hook failed");
        console2.log("Hook funded with 0.001 ETH");

        // ==========================================
        // Step 6: Issuer adds LP with escrow (1 tx)
        // ==========================================
        console2.log("");
        console2.log("=== Step 6: Add Issuer LP (creates escrow) ===");

        bytes memory hookData = _buildHookData(deployer);

        lpRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                liquidityDelta: int256(LP_AMOUNT),
                salt: 0
            }),
            hookData
        );

        console2.log("Issuer LP added with escrow");

        // ==========================================
        // Step 7: Swap — buy issuedToken (1 tx)
        // ==========================================
        console2.log("");
        console2.log("=== Step 7: Execute Buy Swap ===");

        // Buy issued token: sell baseToken for issuedToken
        bool zeroForOne = !issuedIsToken0;

        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -0.01 ether, // Exact input: 0.01 base tokens
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        console2.log("Buy swap executed");

        vm.stopBroadcast();

        // ==========================================
        // Step 8: Assertions (read-only, 0 gas)
        // ==========================================
        console2.log("");
        console2.log("=== Step 8: Assertions ===");

        // 8a. Pool info
        (address issuer, uint256 escrowId, address issuedTok, uint256 totalLiq) = hook.getPoolInfo(poolId);
        require(issuer == deployer, "FAIL: issuer mismatch");
        require(escrowId > 0, "FAIL: escrowId should be > 0");
        require(issuedTok == address(issuedToken), "FAIL: issuedToken mismatch");
        require(totalLiq > 0, "FAIL: totalLiquidity should be > 0");
        console2.log("  getPoolInfo: issuer=%s, escrowId=%d", deployer, escrowId);
        console2.log("  issuedToken:", issuedTok);
        console2.log("  totalLiquidity:", totalLiq);

        // 8b. Issuer check
        require(hook.isIssuer(poolId, deployer), "FAIL: isIssuer should be true");
        console2.log("  isIssuer(deployer) = true");

        // 8c. Escrow status
        IEscrowVault.EscrowStatus memory es = escrowVault.getEscrowStatus(escrowId);
        require(es.totalLocked == ESCROW_AMOUNT, "FAIL: escrow totalLocked mismatch");
        require(es.remaining == ESCROW_AMOUNT, "FAIL: escrow remaining mismatch");
        require(es.released == 0, "FAIL: escrow released should be 0");
        console2.log("  Escrow: totalLocked=%d, remaining=%d", es.totalLocked, es.remaining);

        // 8d. Insurance pool
        IInsurancePool.PoolStatus memory ps = insurancePool.getPoolStatus(poolId);
        require(ps.balance > 0, "FAIL: insurance pool balance should be > 0");
        require(!ps.isTriggered, "FAIL: pool should not be triggered");
        console2.log("  Insurance: balance=%d wei", ps.balance);

        // 8e. Reputation
        uint256 score = reputationEngine.getScore(deployer);
        console2.log("  Reputation score:", score);

        // 8f. Vesting (should be 0 — within first vesting period)
        uint256 vested = escrowVault.calculateVestedAmount(escrowId);
        console2.log("  Vested amount:", vested);

        // ==========================================
        // Summary
        // ==========================================
        console2.log("");
        console2.log("====================================");
        console2.log("  BastionSwap E2E Test: ALL PASSED  ");
        console2.log("====================================");
        console2.log("");
        console2.log("Test Token (BTT):", address(issuedToken));
        console2.log("Base Token (BTST):", address(baseToken));
        console2.log("Pool ID:", vm.toString(PoolId.unwrap(poolId)));
        console2.log("Escrow Locked:", es.totalLocked);
        console2.log("Insurance Balance:", ps.balance);
        console2.log("Reputation Score:", score);
        console2.log("Deployer ETH remaining:", deployer.balance);
    }

    // ═══════════════════════════════════════════════════════════════
    //  HELPERS
    // ═══════════════════════════════════════════════════════════════

    function _loadDeployment() internal {
        string memory json = vm.readFile("deployments/84532.json");

        address hookAddr = vm.parseJsonAddress(json, ".bastionHook");
        address escrowAddr = vm.parseJsonAddress(json, ".escrowVault");
        address insuranceAddr = vm.parseJsonAddress(json, ".insurancePool");
        address triggerAddr = vm.parseJsonAddress(json, ".triggerOracle");
        address reputationAddr = vm.parseJsonAddress(json, ".reputationEngine");

        poolManager = IPoolManager(0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408);
        hook = BastionHook(payable(hookAddr));
        escrowVault = EscrowVault(escrowAddr);
        insurancePool = InsurancePool(insuranceAddr);
        triggerOracle = TriggerOracle(triggerAddr);
        reputationEngine = IReputationEngine(reputationAddr);

        console2.log("Deployed contracts loaded");
    }

    function _buildPoolKey() internal {
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
    }

    function _buildHookData(address deployer) internal view returns (bytes memory) {
        IEscrowVault.VestingStep[] memory vesting = new IEscrowVault.VestingStep[](3);
        vesting[0] = IEscrowVault.VestingStep({timeOffset: 7 days, basisPoints: 1000});
        vesting[1] = IEscrowVault.VestingStep({timeOffset: 30 days, basisPoints: 3000});
        vesting[2] = IEscrowVault.VestingStep({timeOffset: 90 days, basisPoints: 10000});

        IEscrowVault.IssuerCommitment memory commitment = IEscrowVault.IssuerCommitment({
            dailyWithdrawLimit: 500,
            lockDuration: 7776000, // 90 days
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

        return abi.encode(
            deployer, address(issuedToken), ESCROW_AMOUNT, vesting, commitment, triggerConfig
        );
    }
}
