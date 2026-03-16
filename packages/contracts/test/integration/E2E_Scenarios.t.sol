// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {SortTokens} from "@uniswap/v4-core/test/utils/SortTokens.sol";

import {BastionHook} from "../../src/hooks/BastionHook.sol";
import {EscrowVault} from "../../src/core/EscrowVault.sol";
import {InsurancePool} from "../../src/core/InsurancePool.sol";
import {TriggerOracle} from "../../src/core/TriggerOracle.sol";
import {IEscrowVault} from "../../src/interfaces/IEscrowVault.sol";
import {IInsurancePool} from "../../src/interfaces/IInsurancePool.sol";
import {ITriggerOracle} from "../../src/interfaces/ITriggerOracle.sol";

contract MockReputationEngine {
    function recordEvent(address, uint8, bytes calldata) external {}
    function getScore(address) external pure returns (uint256) { return 500; }
}

contract MockBastionRouter {
    function forceRemoveLiquidity(PoolKey calldata, uint128, address) external {}
    function forceCollectFees(PoolKey calldata, address) external {}
}

/// @title E2E Scenario Tests for BastionSwap Protocol (LP Permission Model)
/// @notice Validates the protocol's core value proposition through three full lifecycle scenarios:
///         1. Rug-pull attempt -> LP removal blocked by vesting + Trigger lockdown
///         2. Legitimate project -> Normal vesting with gradual LP removal
///         3. Issuer dump -> Trigger + Compensation
contract E2E_ScenariosTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    uint256 constant ISSUER_LP = 1000e18;
    uint256 constant TRADER_LP = 100e18;
    int24 constant TICK_LOWER = -887220;
    int24 constant TICK_UPPER = 887220;

    address issuerAddr;
    address trader1;
    address trader2;
    address guardian;
    address governance;

    BastionHook hook;
    EscrowVault escrowVault;
    InsurancePool insurancePool;
    TriggerOracle triggerOracle;

    MockERC20 issuedToken;
    MockERC20 baseToken;

    PoolKey _poolKey;
    PoolId _poolId;
    bool _issuedIsToken0;
    uint256 _escrowId;

    function setUp() public {
        issuerAddr = makeAddr("issuer");
        trader1 = makeAddr("trader1");
        trader2 = makeAddr("trader2");
        guardian = makeAddr("guardian");
        governance = makeAddr("governance");

        deployFreshManagerAndRouters();

        uint160 flags = uint160(
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        address hookAddr = address(flags);

        MockReputationEngine mockReputation = new MockReputationEngine();
        address reputationAddr = address(mockReputation);

        uint64 nonce = vm.getNonce(address(this));
        address escrowAddr = vm.computeCreateAddress(address(this), nonce);
        address insuranceAddr = vm.computeCreateAddress(address(this), nonce + 1);
        address triggerAddr = vm.computeCreateAddress(address(this), nonce + 2);

        escrowVault = new EscrowVault(hookAddr, triggerAddr, reputationAddr);
        insurancePool = new InsurancePool(hookAddr, triggerAddr, governance, escrowAddr, address(0xBEEF));
        triggerOracle = new TriggerOracle(hookAddr, escrowAddr, insuranceAddr, guardian, reputationAddr, governance);

        {
            bytes memory bytecode = abi.encodePacked(
                type(BastionHook).creationCode,
                abi.encode(address(manager), address(escrowVault), address(insurancePool), address(triggerOracle), reputationAddr, governance, address(0), address(0))
            );
            address deployed;
            assembly {
                deployed := create(0, add(bytecode, 0x20), mload(bytecode))
            }
            vm.etch(hookAddr, deployed.code);
            // Restore storage lost by vm.etch
            vm.store(hookAddr, bytes32(uint256(24)), bytes32(uint256(uint160(governance))));
            // Restore duration params + LP removal defaults: defaultLockDuration=7days, defaultVestingDuration=83days, minLockDuration=7days, minVestingDuration=7days, dailyLpRemovalBps=1000, weeklyLpRemovalBps=3000
            vm.store(hookAddr, bytes32(uint256(26)), bytes32(uint256(uint40(7 days)) | (uint256(uint40(83 days)) << 40) | (uint256(uint40(7 days)) << 80) | (uint256(uint40(7 days)) << 120) | (uint256(uint16(1000)) << 160) | (uint256(uint16(3000)) << 176)));
            // Restore _owner at slot 21 so setBastionRouter works
            vm.store(hookAddr, bytes32(uint256(21)), bytes32(uint256(uint160(governance))));
        }
        hook = BastionHook(payable(hookAddr));

        // Wire up mock router for force removal
        MockBastionRouter mockRouter = new MockBastionRouter();
        vm.prank(governance);
        hook.setBastionRouter(address(mockRouter));

        issuedToken = new MockERC20("IssuedToken", "ISS", 18);
        baseToken = new MockERC20("BaseToken", "BASE", 18);

        // Register baseToken as an allowed base token (storage lost by vm.etch)
        vm.prank(governance);
        hook.addBaseToken(address(baseToken), 0);

        (Currency c0, Currency c1) = SortTokens.sort(issuedToken, baseToken);
        currency0 = c0;
        currency1 = c1;
        _issuedIsToken0 = (Currency.unwrap(currency0) == address(issuedToken));

        _mintAndApprove();
        vm.deal(address(hook), 100 ether);
    }

    function _mintAndApprove() internal {
        address[4] memory actors = [issuerAddr, address(this), trader1, trader2];
        for (uint256 i; i < actors.length; ++i) {
            issuedToken.mint(actors[i], 1_000_000 ether);
            baseToken.mint(actors[i], 1_000_000 ether);
        }

        issuedToken.approve(address(modifyLiquidityRouter), type(uint256).max);
        baseToken.approve(address(modifyLiquidityRouter), type(uint256).max);
        issuedToken.approve(address(swapRouter), type(uint256).max);
        baseToken.approve(address(swapRouter), type(uint256).max);

        // Issuer approvals — no hook approval needed
        vm.startPrank(issuerAddr);
        issuedToken.approve(address(modifyLiquidityRouter), type(uint256).max);
        baseToken.approve(address(modifyLiquidityRouter), type(uint256).max);
        issuedToken.approve(address(swapRouter), type(uint256).max);
        baseToken.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        for (uint256 i; i < 2; ++i) {
            address t = i == 0 ? trader1 : trader2;
            vm.startPrank(t);
            issuedToken.approve(address(swapRouter), type(uint256).max);
            baseToken.approve(address(swapRouter), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ─── Helpers ─────────────────────────────────────────────────────

    uint40 constant DEFAULT_LOCK = 7 days;
    uint40 constant DEFAULT_VESTING = 83 days;

    function _triggerConfig() internal pure returns (ITriggerOracle.TriggerConfig memory) {
        return ITriggerOracle.TriggerConfig({
            dailyLpRemovalBps: 1000,
            weeklyLpRemovalBps: 3000,
            dumpThresholdPercent: 300,
            dumpWindowSeconds: 86400,
            taxDeviationThreshold: 500,
            weeklyDumpWindowSeconds: 604800,
            weeklyDumpThresholdPercent: 1500
        });
    }

    function _encodeHookData(IEscrowVault.IssuerCommitment memory commitment)
        internal
        view
        returns (bytes memory)
    {
        return abi.encode(
            issuerAddr, address(issuedToken), DEFAULT_LOCK, DEFAULT_VESTING, commitment, _triggerConfig()
        );
    }

    function _initPool(IEscrowVault.IssuerCommitment memory commitment) internal {
        _poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(hook)));
        _poolId = _poolKey.toId();
        manager.initialize(_poolKey, SQRT_PRICE_1_1);

        vm.prank(issuerAddr);
        modifyLiquidityRouter.modifyLiquidity(
            _poolKey,
            ModifyLiquidityParams({tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: int256(ISSUER_LP), salt: 0}),
            _encodeHookData(commitment)
        );
        (, _escrowId,,,) = hook.getPoolInfo(_poolId);

        modifyLiquidityRouter.modifyLiquidity(
            _poolKey,
            ModifyLiquidityParams({
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                liquidityDelta: int256(TRADER_LP),
                salt: bytes32(uint256(1))
            }),
            ""
        );
    }

    function _buyIssuedToken(address trader, int256 amount) internal {
        bool zeroForOne = !_issuedIsToken0;
        vm.prank(trader);
        swapRouter.swap(
            _poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amount,
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _getTotalLP() internal view returns (uint256) {
        (,,,uint256 totalLP,) = hook.getPoolInfo(_poolId);
        return totalLP;
    }

    // ═══════════════════════════════════════════════════════════════════
    //  SCENARIO 1: Rug-Pull Attempt -> LP Removal Blocked + Lockdown
    // ═══════════════════════════════════════════════════════════════════

    function test_scenario1_rugPull_blockAndLockdown() public {
        console.log("=== SCENARIO 1: Rug-Pull Attempt (LP Permission Model) ===");

        // Phase 1: Pool creation
        IEscrowVault.IssuerCommitment memory commitment =
            IEscrowVault.IssuerCommitment({maxSellPercent: 200});

        _initPool(commitment);

        _scenario1_verifyCreation();
        _scenario1_tradersBuy();
        _scenario1_vestingBlocked();
        _scenario1_rugPullTrigger();
        _scenario1_insuranceClaims();

        console.log("=== SCENARIO 1 COMPLETE ===");
    }

    function _scenario1_verifyCreation() internal view {
        assertTrue(hook.isIssuer(_poolId, issuerAddr), "issuer not registered");
        // Vault holds no tokens (LP permission model)
        assertEq(issuedToken.balanceOf(address(escrowVault)), 0, "vault should hold no tokens");
        assertTrue(triggerOracle.isConfigSet(_poolId), "trigger config not set");

        IEscrowVault.EscrowStatus memory s = escrowVault.getEscrowStatus(_escrowId);
        assertGt(s.totalLiquidity, 0);
        assertEq(s.removedLiquidity, 0);
        assertEq(s.remainingLiquidity, s.totalLiquidity);
        console.log("  Escrow totalLiquidity:", uint256(s.totalLiquidity));
        console.log("  Total LP:", _getTotalLP());
    }

    function _scenario1_tradersBuy() internal {
        uint256 before = baseToken.balanceOf(address(insurancePool));

        _buyIssuedToken(trader1, -1 ether);
        _buyIssuedToken(trader2, -0.5 ether);

        uint256 fees = baseToken.balanceOf(address(insurancePool)) - before;
        assertGt(fees, 0, "no insurance fees");
        console.log("  Insurance fees (base token):", fees);
    }

    function _scenario1_vestingBlocked() internal {
        vm.warp(block.timestamp + 6 days);
        assertEq(escrowVault.calculateVestedLiquidity(_escrowId), 0);
        assertEq(escrowVault.getRemovableLiquidity(_escrowId), 0);
        console.log("  Before 7d: LP removal blocked (0 removable)");
    }

    function _scenario1_rugPullTrigger() internal {
        // Warp into mid-vesting so issuer has removable LP.
        // Lock=7d, Vesting=83d. Already at day 6. Warp +74d = day 80 (73d into 83d vesting).
        vm.warp(block.timestamp + 74 days);

        uint128 removable = escrowVault.getRemovableLiquidity(_escrowId);
        assertGt(removable, 0, "issuer should have removable LP after vesting progress");

        // Daily LP removal limit = 10% of initial LP (1000e18) = 100e18
        // Remove 90e18 (9%) — within daily limit
        uint128 safeChunk = 90e18;
        vm.prank(issuerAddr);
        modifyLiquidityRouter.modifyLiquidity(
            _poolKey,
            ModifyLiquidityParams({tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: -int256(uint256(safeChunk)), salt: 0}),
            abi.encode(issuerAddr)
        );

        // Second removal within same day exceeds daily limit (90+90=180e18 = 18% > 10%)
        vm.warp(block.timestamp + 6 hours);
        vm.prank(issuerAddr);
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(
            _poolKey,
            ModifyLiquidityParams({tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: -int256(uint256(safeChunk)), salt: 0}),
            abi.encode(issuerAddr)
        );
        console.log("  v1: Second LP removal reverted (DailyLpRemovalExceeded)");

        // Trigger directly (v2 watcher path — preserved infra)
        uint256 totalSupply = issuedToken.totalSupply();
        vm.prank(address(hook));
        triggerOracle.executeTrigger(_poolId, _poolKey, ITriggerOracle.TriggerType.RUG_PULL, totalSupply);

        // Trigger fires
        ITriggerOracle.TriggerResult memory result = triggerOracle.checkTrigger(_poolId);
        assertTrue(result.triggered, "trigger should have fired");
        assertEq(uint8(result.triggerType), uint8(ITriggerOracle.TriggerType.RUG_PULL));
        console.log("  RUG_PULL trigger fired via direct trigger call (v2 path)");

        // Escrow locked down
        IEscrowVault.EscrowStatus memory s = escrowVault.getEscrowStatus(_escrowId);
        assertEq(s.remainingLiquidity, 0, "escrow remaining should be 0 after lockdown");
        assertEq(escrowVault.getRemovableLiquidity(_escrowId), 0, "removable should be 0 after lockdown");

        console.log("  Escrow locked down (LP removal permanently blocked)");
    }

    function _scenario1_insuranceClaims() internal view {
        // RUG_PULL trigger passes totalEligibleSupply from _initialTotalSupply,
        // so InsurancePool.executePayout IS called automatically by TriggerOracle.
        IInsurancePool.PoolStatus memory ps = insurancePool.getPoolStatus(_poolId);
        assertTrue(ps.isTriggered, "RUG_PULL trigger should auto-execute insurance payout");

        // ERC-20 base pool: fees are in base token
        uint256 insuranceFees = baseToken.balanceOf(address(insurancePool));
        assertGt(insuranceFees, 0, "no insurance base token fees");
        console.log("  Insurance base token accumulated:", insuranceFees);

        console.log("  Escrow lockdown verified - RUG_PULL scenario complete");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  SCENARIO 2: Legitimate Project -> Normal Vesting with LP Removal
    // ═══════════════════════════════════════════════════════════════════

    function test_scenario2_legitimateProject_normalVesting() public {
        console.log("=== SCENARIO 2: Legitimate Project (LP Permission Model) ===");

        IEscrowVault.IssuerCommitment memory commitment =
            IEscrowVault.IssuerCommitment({maxSellPercent: 200});

        _initPool(commitment);

        _scenario2_vestingMilestones();
        _scenario2_noTrigger();

        console.log("=== SCENARIO 2 COMPLETE ===");
    }

    function _scenario2_vestingMilestones() internal {
        // During lock (7 days): 0 vested
        vm.warp(block.timestamp + 6 days);
        uint128 vested = escrowVault.calculateVestedLiquidity(_escrowId);
        assertEq(vested, 0, "should have 0 vested during lock");
        console.log("  Day 6 vested liquidity:", uint256(vested));

        // Day 8: past lock, linear vesting begins
        vm.warp(block.timestamp + 2 days); // now at day 8
        vested = escrowVault.calculateVestedLiquidity(_escrowId);
        assertGt(vested, 0, "should have vested liquidity after lock");
        console.log("  Day 8 vested liquidity:", uint256(vested));

        uint128 removable = escrowVault.getRemovableLiquidity(_escrowId);
        assertGt(removable, 0, "should have removable liquidity after lock");
        console.log("  Day 8 removable liquidity:", uint256(removable));

        // Day 45: ~46% vested (38 days into 83-day vesting)
        vm.warp(block.timestamp + 37 days); // now at day 45
        vested = escrowVault.calculateVestedLiquidity(_escrowId);
        console.log("  Day 45 vested liquidity:", uint256(vested));

        // Day 90: 100% vested (lock 7 + vesting 83 = 90 days)
        vm.warp(block.timestamp + 45 days); // now at day 90
        vested = escrowVault.calculateVestedLiquidity(_escrowId);
        console.log("  Day 90 vested liquidity:", uint256(vested));

        IEscrowVault.EscrowStatus memory s = escrowVault.getEscrowStatus(_escrowId);
        assertEq(uint256(vested), uint256(s.totalLiquidity), "100% vested at 90d");
    }

    function _scenario2_noTrigger() internal view {
        assertFalse(triggerOracle.checkTrigger(_poolId).triggered, "no trigger");

        IInsurancePool.PoolStatus memory ps = insurancePool.getPoolStatus(_poolId);
        assertFalse(ps.isTriggered);
        console.log("  No trigger fired - legitimate project");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  SCENARIO 3: Cumulative LP Removal -> Trigger + Lockdown + Compensation
    // ═══════════════════════════════════════════════════════════════════

    function test_scenario3_lpRemovalTrigger_andCompensate() public {
        console.log("=== SCENARIO 3: Cumulative LP Removal Trigger (LP Permission Model) ===");

        IEscrowVault.IssuerCommitment memory commitment =
            IEscrowVault.IssuerCommitment({maxSellPercent: 200});

        _initPool(commitment);

        _scenario3_tradersBuy();
        _scenario3_cumulativeLPRemovalTrigger();
        _scenario3_claims();
        _scenario3_claimExpiry();

        console.log("=== SCENARIO 3 COMPLETE ===");
    }

    function _scenario3_tradersBuy() internal {
        _buyIssuedToken(trader1, -2 ether);
        _buyIssuedToken(trader2, -1 ether);

        uint256 insuranceFees = baseToken.balanceOf(address(insurancePool));
        assertGt(insuranceFees, 0, "no insurance fees");
        console.log("  Insurance base token fees:", insuranceFees);
    }

    function _scenario3_cumulativeLPRemovalTrigger() internal {
        // Warp past lock + well into vesting so issuer has removable LP
        vm.warp(block.timestamp + 80 days);

        uint128 removable = escrowVault.getRemovableLiquidity(_escrowId);
        assertGt(removable, 0, "issuer should have removable LP");
        console.log("  Removable LP:", uint256(removable));

        uint256 insuranceBaseTokenBefore = baseToken.balanceOf(address(insurancePool));

        // Daily limit = 10% of initial LP (1000e18) = 100e18
        // Weekly limit = 30% of initial LP = 300e18
        // Remove 90e18 per day across 3 days (cumulative 270e18 = 27%, within 30% weekly)
        uint128 dailyChunk = 90e18;

        // Day 1: 90e18 (9% daily, 9% weekly)
        vm.prank(issuerAddr);
        modifyLiquidityRouter.modifyLiquidity(
            _poolKey,
            ModifyLiquidityParams({tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: -int256(uint256(dailyChunk)), salt: 0}),
            abi.encode(issuerAddr)
        );
        assertFalse(hook.isPoolTriggered(_poolId), "should not be triggered yet");

        // Day 2: +1 day, new daily window, 90e18 (9% daily, 18% weekly cumulative)
        vm.warp(block.timestamp + 1 days);
        vm.prank(issuerAddr);
        modifyLiquidityRouter.modifyLiquidity(
            _poolKey,
            ModifyLiquidityParams({tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: -int256(uint256(dailyChunk)), salt: 0}),
            abi.encode(issuerAddr)
        );

        // Day 3: +1 day, 90e18 (9% daily, 27% weekly cumulative)
        vm.warp(block.timestamp + 1 days);
        vm.prank(issuerAddr);
        modifyLiquidityRouter.modifyLiquidity(
            _poolKey,
            ModifyLiquidityParams({tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: -int256(uint256(dailyChunk)), salt: 0}),
            abi.encode(issuerAddr)
        );

        // Day 4: +1 day, try 90e18 → reverts (weekly cumulative 360e18 = 36% > 30%)
        vm.warp(block.timestamp + 1 days);
        vm.prank(issuerAddr);
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(
            _poolKey,
            ModifyLiquidityParams({tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: -int256(uint256(dailyChunk)), salt: 0}),
            abi.encode(issuerAddr)
        );
        console.log("  v1: LP removal reverted (WeeklyLpRemovalExceeded)");

        // Trigger directly (v2 watcher path — preserved infra)
        uint256 totalSupply = issuedToken.totalSupply();
        vm.prank(address(hook));
        triggerOracle.executeTrigger(_poolId, _poolKey, ITriggerOracle.TriggerType.RUG_PULL, totalSupply);

        // Verify trigger fired
        ITriggerOracle.TriggerResult memory result = triggerOracle.checkTrigger(_poolId);
        assertTrue(result.triggered, "RUG_PULL trigger should have fired");
        assertEq(uint8(result.triggerType), uint8(ITriggerOracle.TriggerType.RUG_PULL));
        console.log("  RUG_PULL trigger fired via direct trigger call (v2 path)");

        // Escrow locked down
        IEscrowVault.EscrowStatus memory s = escrowVault.getEscrowStatus(_escrowId);
        assertEq(s.remainingLiquidity, 0, "escrow remaining should be 0 after lockdown");
        assertEq(escrowVault.getRemovableLiquidity(_escrowId), 0, "removable should be 0 after lockdown");
        console.log("  Escrow locked down");

        // InsurancePool.executePayout was called automatically with bytes32(0) merkle root
        IInsurancePool.PoolStatus memory ps = insurancePool.getPoolStatus(_poolId);
        assertTrue(ps.isTriggered, "insurance pool should be triggered");
        assertTrue(ps.totalEligibleSupply > 0, "eligible supply should be set");

        assertGt(insuranceBaseTokenBefore, 0, "should have base token fees before payout");
        console.log("  Insurance base token for claims:", insuranceBaseTokenBefore);
    }

    function _scenario3_claims() internal {
        // Advance past 24h merkle submission deadline + one block for flash-loan protection
        vm.warp(block.timestamp + 24 hours + 1);
        vm.roll(block.number + 1);

        uint256 t1Bal = issuedToken.balanceOf(trader1);
        uint256 t2Bal = issuedToken.balanceOf(trader2);

        // Approve InsurancePool to lock tokens (H-01 fix)
        vm.prank(trader1);
        issuedToken.approve(address(insurancePool), t1Bal);
        vm.prank(trader2);
        issuedToken.approve(address(insurancePool), t2Bal);

        // Trader1 claims using fallback mode
        uint256 baseBefore1 = baseToken.balanceOf(trader1);
        vm.prank(trader1);
        insurancePool.claimCompensationFallback(_poolId, t1Bal);

        uint256 baseReceived1 = baseToken.balanceOf(trader1) - baseBefore1;
        assertGt(baseReceived1, 0, "trader1 should receive base token compensation");
        console.log("  Trader1 base token claimed:", baseReceived1);

        // Trader2 claims using fallback mode
        uint256 baseBefore2 = baseToken.balanceOf(trader2);
        vm.prank(trader2);
        insurancePool.claimCompensationFallback(_poolId, t2Bal);

        uint256 baseReceived2 = baseToken.balanceOf(trader2) - baseBefore2;
        assertGt(baseReceived2, 0, "trader2 should receive base token compensation");
        console.log("  Trader2 base token claimed:", baseReceived2);

        assertTrue(insurancePool.hasClaimed(_poolId, trader1));
        assertTrue(insurancePool.hasClaimed(_poolId, trader2));

        // Duplicate claim blocked
        vm.prank(trader1);
        vm.expectRevert(abi.encodeWithSelector(InsurancePool.AlreadyClaimed.selector));
        insurancePool.claimCompensationFallback(_poolId, t1Bal);
    }

    function _scenario3_claimExpiry() internal {
        vm.warp(block.timestamp + 8 days);

        vm.prank(address(this));
        vm.expectRevert(abi.encodeWithSelector(InsurancePool.ClaimPeriodExpired.selector));
        insurancePool.claimCompensationFallback(_poolId, 1000 ether);
        console.log("  Claim after 7d fallback window correctly blocked");
    }
}
