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

/// @title E2E Scenario Tests for BastionSwap Protocol
/// @notice Validates the protocol's core value proposition through three full lifecycle scenarios:
///         1. Rug-pull attempt -> Block + Compensation
///         2. Legitimate project -> Normal vesting
///         3. Issuer dump -> Trigger + Compensation
contract E2E_ScenariosTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    uint256 constant ESCROW_AMOUNT = 100 ether;
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
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        address hookAddr = address(flags);

        uint64 nonce = vm.getNonce(address(this));
        address escrowAddr = vm.computeCreateAddress(address(this), nonce);
        address insuranceAddr = vm.computeCreateAddress(address(this), nonce + 1);
        address triggerAddr = vm.computeCreateAddress(address(this), nonce + 2);

        escrowVault = new EscrowVault(hookAddr, triggerAddr, insuranceAddr);
        insurancePool = new InsurancePool(hookAddr, triggerAddr, governance);
        triggerOracle = new TriggerOracle(hookAddr, escrowAddr, insuranceAddr, guardian);

        {
            bytes memory bytecode = abi.encodePacked(
                type(BastionHook).creationCode,
                abi.encode(address(manager), address(escrowVault), address(insurancePool), address(triggerOracle))
            );
            address deployed;
            assembly {
                deployed := create(0, add(bytecode, 0x20), mload(bytecode))
            }
            vm.etch(hookAddr, deployed.code);
        }
        hook = BastionHook(payable(hookAddr));

        issuedToken = new MockERC20("IssuedToken", "ISS", 18);
        baseToken = new MockERC20("BaseToken", "BASE", 18);

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

        vm.startPrank(issuerAddr);
        issuedToken.approve(address(hook), type(uint256).max);
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

    function _vestingSchedule() internal pure returns (IEscrowVault.VestingStep[] memory s) {
        s = new IEscrowVault.VestingStep[](3);
        s[0] = IEscrowVault.VestingStep({timeOffset: 7 days, basisPoints: 1000});
        s[1] = IEscrowVault.VestingStep({timeOffset: 30 days, basisPoints: 3000});
        s[2] = IEscrowVault.VestingStep({timeOffset: 90 days, basisPoints: 10000});
    }

    function _triggerConfig() internal pure returns (ITriggerOracle.TriggerConfig memory) {
        return ITriggerOracle.TriggerConfig({
            lpRemovalThreshold: 5000,
            dumpThresholdPercent: 3000,
            dumpWindowSeconds: 86400,
            taxDeviationThreshold: 500,
            slowRugWindowSeconds: 86400,
            slowRugCumulativeThreshold: 8000
        });
    }

    function _encodeHookData(IEscrowVault.IssuerCommitment memory commitment)
        internal
        view
        returns (bytes memory)
    {
        return abi.encode(
            issuerAddr, address(issuedToken), ESCROW_AMOUNT, _vestingSchedule(), commitment, _triggerConfig()
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
        (, _escrowId,,) = hook.getPoolInfo(_poolId);

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
        (,,, uint256 totalLP) = hook.getPoolInfo(_poolId);
        return totalLP;
    }

    // ═══════════════════════════════════════════════════════════════════
    //  SCENARIO 1: Rug-Pull Attempt -> Block + Compensation
    // ═══════════════════════════════════════════════════════════════════

    function test_scenario1_rugPull_blockAndCompensate() public {
        console.log("=== SCENARIO 1: Rug-Pull Attempt ===");

        // Phase 1: Pool creation
        IEscrowVault.IssuerCommitment memory commitment =
            IEscrowVault.IssuerCommitment({dailyWithdrawLimit: 0, lockDuration: 0, maxSellPercent: 200});

        uint256 g = gasleft();
        _initPool(commitment);
        console.log("Gas: pool creation + escrow", g - gasleft());

        _scenario1_verifyCreation();
        _scenario1_tradersBuy();
        _scenario1_vestingBlocked();
        _scenario1_vestingRelease();
        _scenario1_excessBlocked();
        _scenario1_rugPullTrigger();
        _scenario1_executeTrigger();
        _scenario1_insuranceClaims();

        console.log("=== SCENARIO 1 COMPLETE ===");
    }

    function _scenario1_verifyCreation() internal {
        assertTrue(hook.isIssuer(_poolId, issuerAddr), "issuer not registered");
        assertEq(issuedToken.balanceOf(address(escrowVault)), ESCROW_AMOUNT, "escrow not funded");
        assertTrue(triggerOracle.isConfigSet(_poolId), "trigger config not set");

        IEscrowVault.EscrowStatus memory s = escrowVault.getEscrowStatus(_escrowId);
        assertEq(s.totalLocked, ESCROW_AMOUNT);
        assertEq(s.released, 0);
        assertEq(s.remaining, ESCROW_AMOUNT);
        console.log("  Escrow locked:", s.totalLocked);
        console.log("  Total LP:", _getTotalLP());
    }

    function _scenario1_tradersBuy() internal {
        uint256 before = address(insurancePool).balance;

        uint256 g = gasleft();
        _buyIssuedToken(trader1, -1 ether);
        console.log("Gas: trader1 buy swap", g - gasleft());

        g = gasleft();
        _buyIssuedToken(trader2, -0.5 ether);
        console.log("Gas: trader2 buy swap", g - gasleft());

        uint256 fees = address(insurancePool).balance - before;
        assertGt(fees, 0, "no insurance fees");
        console.log("  Insurance fees (ETH):", fees);
    }

    function _scenario1_vestingBlocked() internal {
        vm.warp(block.timestamp + 6 days);
        assertEq(escrowVault.calculateVestedAmount(_escrowId), 0);

        vm.expectRevert(abi.encodeWithSelector(EscrowVault.NothingToRelease.selector));
        escrowVault.releaseVested(_escrowId);
        console.log("  Before 7d: release blocked");
    }

    function _scenario1_vestingRelease() internal {
        vm.warp(block.timestamp + 1 days); // T+7d
        assertEq(escrowVault.calculateVestedAmount(_escrowId), 10 ether);

        uint256 bal = issuedToken.balanceOf(issuerAddr);
        uint256 g = gasleft();
        escrowVault.releaseVested(_escrowId);
        console.log("Gas: releaseVested (10%)", g - gasleft());

        assertEq(issuedToken.balanceOf(issuerAddr) - bal, 10 ether);
        console.log("  Day 7: released 10 ether");
    }

    function _scenario1_excessBlocked() internal {
        vm.expectRevert(abi.encodeWithSelector(EscrowVault.NothingToRelease.selector));
        escrowVault.releaseVested(_escrowId);
        console.log("  Excess release blocked");
    }

    function _scenario1_rugPullTrigger() internal {
        uint256 totalLP = _getTotalLP();

        vm.expectEmit(true, false, false, false, address(hook));
        emit BastionHook.LPRemovalReported(_poolId, ISSUER_LP, totalLP);

        uint256 g = gasleft();
        modifyLiquidityRouter.modifyLiquidity(
            _poolKey,
            ModifyLiquidityParams({tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: -int256(ISSUER_LP), salt: 0}),
            ""
        );
        console.log("Gas: LP removal (80%%)", g - gasleft());

        (bool exists, ITriggerOracle.TriggerType tt,) = triggerOracle.getPendingTrigger(_poolId);
        assertTrue(exists, "trigger should be pending");
        assertEq(uint8(tt), uint8(ITriggerOracle.TriggerType.RUG_PULL));
        console.log("  RUG_PULL trigger pending");
    }

    function _scenario1_executeTrigger() internal {
        // Cannot execute before grace period
        vm.expectRevert(abi.encodeWithSelector(TriggerOracle.GracePeriodNotElapsed.selector));
        triggerOracle.executeTrigger(_poolId);

        (,, uint40 executeAfter) = triggerOracle.getPendingTrigger(_poolId);
        vm.warp(executeAfter);

        uint256 insuranceTokensBefore = issuedToken.balanceOf(address(insurancePool));
        uint256 expectedRedist = ESCROW_AMOUNT - 10 ether; // 90 ether

        vm.expectEmit(true, false, false, true, address(escrowVault));
        emit IEscrowVault.Redistributed(_escrowId, uint8(ITriggerOracle.TriggerType.RUG_PULL), expectedRedist);

        uint256 g = gasleft();
        triggerOracle.executeTrigger(_poolId);
        console.log("Gas: executeTrigger", g - gasleft());

        // Verify trigger state
        assertTrue(triggerOracle.checkTrigger(_poolId).triggered);

        // Escrow emptied
        IEscrowVault.EscrowStatus memory s = escrowVault.getEscrowStatus(_escrowId);
        assertEq(s.remaining, 0, "escrow should be empty");
        assertEq(s.released, 10 ether);

        // Tokens redistributed to InsurancePool
        uint256 redistributed = issuedToken.balanceOf(address(insurancePool)) - insuranceTokensBefore;
        assertEq(redistributed, expectedRedist);
        console.log("  Redistributed tokens:", redistributed);

        // Further release blocked
        vm.expectRevert(abi.encodeWithSelector(EscrowVault.EscrowTriggered.selector));
        escrowVault.releaseVested(_escrowId);
    }

    function _scenario1_insuranceClaims() internal {
        // RUG_PULL doesn't auto-trigger insurance payout (totalEligibleSupply=0).
        // Manually trigger for E2E verification.
        uint256 totalSupply = issuedToken.totalSupply();
        vm.prank(address(triggerOracle));
        insurancePool.executePayout(_poolId, uint8(ITriggerOracle.TriggerType.RUG_PULL), totalSupply);

        IInsurancePool.PoolStatus memory ps = insurancePool.getPoolStatus(_poolId);
        assertTrue(ps.isTriggered);
        assertGt(ps.balance, 0);
        console.log("  Insurance ETH for claims:", ps.balance);

        // Trader1 claims
        uint256 t1Bal = issuedToken.balanceOf(trader1);
        uint256 comp = insurancePool.calculateCompensation(_poolId, t1Bal);
        assertGt(comp, 0);

        uint256 ethBefore = trader1.balance;

        vm.expectEmit(true, true, false, true, address(insurancePool));
        emit IInsurancePool.CompensationClaimed(_poolId, trader1, comp);

        vm.prank(trader1);
        uint256 g = gasleft();
        insurancePool.claimCompensation(_poolId, t1Bal);
        console.log("Gas: claimCompensation", g - gasleft());

        assertEq(trader1.balance - ethBefore, comp);
        assertTrue(insurancePool.hasClaimed(_poolId, trader1));
        console.log("  Trader1 ETH claimed:", comp);

        // Duplicate claim blocked
        vm.prank(trader1);
        vm.expectRevert(abi.encodeWithSelector(InsurancePool.AlreadyClaimed.selector));
        insurancePool.claimCompensation(_poolId, t1Bal);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  SCENARIO 2: Legitimate Project -> Normal Vesting
    // ═══════════════════════════════════════════════════════════════════

    function test_scenario2_legitimateProject_normalVesting() public {
        console.log("=== SCENARIO 2: Legitimate Project ===");

        IEscrowVault.IssuerCommitment memory commitment =
            IEscrowVault.IssuerCommitment({dailyWithdrawLimit: 500, lockDuration: 0, maxSellPercent: 200});

        uint256 g = gasleft();
        _initPool(commitment);
        console.log("Gas: pool creation + escrow", g - gasleft());

        _scenario2_vestingMilestones();
        _scenario2_fullVesting();
        _scenario2_noTrigger();

        console.log("=== SCENARIO 2 COMPLETE ===");
    }

    function _scenario2_vestingMilestones() internal {
        // Day 7: 10% vested, daily limit = 5%
        vm.warp(block.timestamp + 7 days);
        assertEq(escrowVault.calculateVestedAmount(_escrowId), 10 ether, "10% at 7d");
        console.log("  Day 7 vested:", uint256(10 ether));

        // First release: capped at daily limit (5 ether)
        uint256 bal = issuedToken.balanceOf(issuerAddr);
        uint256 g = gasleft();
        escrowVault.releaseVested(_escrowId);
        console.log("Gas: releaseVested (daily-limited)", g - gasleft());

        uint256 released = issuedToken.balanceOf(issuerAddr) - bal;
        assertEq(released, 5 ether, "daily limit: 5 ether");
        console.log("  Day 7 released (daily limit):", released);

        // Same-day second release blocked
        vm.expectRevert(abi.encodeWithSelector(EscrowVault.DailyLimitExceeded.selector));
        escrowVault.releaseVested(_escrowId);
        console.log("  Same-day excess blocked by daily limit");

        // Next day: remaining 5 ether from 10% tranche
        vm.warp(block.timestamp + 1 days);
        bal = issuedToken.balanceOf(issuerAddr);
        escrowVault.releaseVested(_escrowId);
        assertEq(issuedToken.balanceOf(issuerAddr) - bal, 5 ether);
        console.log("  Day 8 released: 5 ether");

        // Day 30: 30% vested, daily limit applies
        vm.warp(block.timestamp + 22 days);
        assertEq(escrowVault.calculateVestedAmount(_escrowId), 30 ether, "30% at 30d");

        bal = issuedToken.balanceOf(issuerAddr);
        escrowVault.releaseVested(_escrowId);
        assertEq(issuedToken.balanceOf(issuerAddr) - bal, 5 ether, "daily limit on day 30");
    }

    function _scenario2_fullVesting() internal {
        // Day 90: 100% vested
        vm.warp(block.timestamp + 60 days);
        assertEq(escrowVault.calculateVestedAmount(_escrowId), 100 ether, "100% at 90d");
        console.log("  Day 90 vested: 100 ether");

        // Release in daily increments
        IEscrowVault.EscrowStatus memory s = escrowVault.getEscrowStatus(_escrowId);
        uint256 remaining = s.remaining;
        uint256 dayCount;

        while (remaining > 0) {
            uint256 g = gasleft();
            uint256 rel = escrowVault.releaseVested(_escrowId);
            if (dayCount == 0) console.log("Gas: releaseVested (day 90)", g - gasleft());
            remaining -= rel;
            dayCount++;
            if (remaining > 0) vm.warp(block.timestamp + 1 days);
        }

        s = escrowVault.getEscrowStatus(_escrowId);
        assertEq(s.remaining, 0, "fully released");
        assertEq(s.released, ESCROW_AMOUNT);
        console.log("  Full release took", dayCount, "daily withdrawals");
    }

    function _scenario2_noTrigger() internal {
        assertFalse(triggerOracle.checkTrigger(_poolId).triggered, "no trigger");

        IInsurancePool.PoolStatus memory ps = insurancePool.getPoolStatus(_poolId);
        assertFalse(ps.isTriggered);
        console.log("  No trigger fired - legitimate project");

        // LP removal still works
        uint256 g = gasleft();
        modifyLiquidityRouter.modifyLiquidity(
            _poolKey,
            ModifyLiquidityParams({tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: -int256(ISSUER_LP), salt: 0}),
            ""
        );
        console.log("Gas: normal LP removal", g - gasleft());
    }

    // ═══════════════════════════════════════════════════════════════════
    //  SCENARIO 3: Issuer Dump -> Trigger + Compensation
    // ═══════════════════════════════════════════════════════════════════

    function test_scenario3_issuerDump_triggerAndCompensate() public {
        console.log("=== SCENARIO 3: Issuer Dump ===");

        IEscrowVault.IssuerCommitment memory commitment =
            IEscrowVault.IssuerCommitment({dailyWithdrawLimit: 0, lockDuration: 0, maxSellPercent: 200});

        uint256 g = gasleft();
        _initPool(commitment);
        console.log("Gas: pool creation + escrow", g - gasleft());

        _scenario3_tradersBuy();
        _scenario3_issuerDump();
        _scenario3_executeTrigger();
        _scenario3_claims();
        _scenario3_claimExpiry();

        console.log("=== SCENARIO 3 COMPLETE ===");
    }

    function _scenario3_tradersBuy() internal {
        uint256 g = gasleft();
        _buyIssuedToken(trader1, -2 ether);
        console.log("Gas: trader1 buy (2 ether)", g - gasleft());

        g = gasleft();
        _buyIssuedToken(trader2, -1 ether);
        console.log("Gas: trader2 buy (1 ether)", g - gasleft());

        uint256 insuranceETH = address(insurancePool).balance;
        assertGt(insuranceETH, 0);
        console.log("  Insurance ETH:", insuranceETH);
    }

    function _scenario3_issuerDump() internal {
        // Simulate issuer selling >30% of supply via hook reporting
        // (afterSwap sender = router, not actual user, so direct oracle call)
        uint256 totalSupply = issuedToken.totalSupply();
        uint256 saleAmount = (totalSupply * 3001) / 10000; // 30.01%
        console.log("  Total supply:", totalSupply);
        console.log("  Sale amount (30.01%%):", saleAmount);

        // Two chunks to test 24h sliding window
        uint256 firstSale = saleAmount / 2;
        uint256 secondSale = saleAmount - firstSale;

        vm.prank(address(hook));
        uint256 g = gasleft();
        triggerOracle.reportIssuerSale(_poolId, issuerAddr, firstSale, totalSupply);
        console.log("Gas: reportIssuerSale (1st)", g - gasleft());

        // First sale ~15% - no trigger
        (bool pending,,) = triggerOracle.getPendingTrigger(_poolId);
        assertFalse(pending, "first sale alone should not trigger");

        // 12h later: second sale pushes cumulative >30%
        vm.warp(block.timestamp + 12 hours);

        vm.expectEmit(true, true, false, false, address(triggerOracle));
        emit TriggerOracle.TriggerPending(
            _poolId, ITriggerOracle.TriggerType.ISSUER_DUMP, uint40(block.timestamp) + 1 hours
        );

        vm.prank(address(hook));
        g = gasleft();
        triggerOracle.reportIssuerSale(_poolId, issuerAddr, secondSale, totalSupply);
        console.log("Gas: reportIssuerSale (2nd, triggers)", g - gasleft());

        (bool exists, ITriggerOracle.TriggerType tt,) = triggerOracle.getPendingTrigger(_poolId);
        assertTrue(exists);
        assertEq(uint8(tt), uint8(ITriggerOracle.TriggerType.ISSUER_DUMP));
        console.log("  ISSUER_DUMP pending");
    }

    function _scenario3_executeTrigger() internal {
        // Grace period: cannot execute early
        vm.expectRevert(abi.encodeWithSelector(TriggerOracle.GracePeriodNotElapsed.selector));
        triggerOracle.executeTrigger(_poolId);

        (,, uint40 executeAfter) = triggerOracle.getPendingTrigger(_poolId);
        vm.warp(executeAfter);

        uint256 insuranceTokensBefore = issuedToken.balanceOf(address(insurancePool));
        uint256 insuranceETHBefore = address(insurancePool).balance;

        // Expect both Redistributed and PayoutExecuted events
        vm.expectEmit(true, false, false, true, address(escrowVault));
        emit IEscrowVault.Redistributed(_escrowId, uint8(ITriggerOracle.TriggerType.ISSUER_DUMP), ESCROW_AMOUNT);

        vm.expectEmit(true, false, false, true, address(insurancePool));
        emit IInsurancePool.PayoutExecuted(
            _poolId, uint8(ITriggerOracle.TriggerType.ISSUER_DUMP), insuranceETHBefore
        );

        uint256 g = gasleft();
        triggerOracle.executeTrigger(_poolId);
        console.log("Gas: executeTrigger (ISSUER_DUMP)", g - gasleft());

        // Verify trigger state
        assertTrue(triggerOracle.checkTrigger(_poolId).triggered);

        // Escrow fully redistributed
        IEscrowVault.EscrowStatus memory s = escrowVault.getEscrowStatus(_escrowId);
        assertEq(s.remaining, 0);

        // Tokens sent to InsurancePool
        uint256 redistributed = issuedToken.balanceOf(address(insurancePool)) - insuranceTokensBefore;
        assertEq(redistributed, ESCROW_AMOUNT);
        console.log("  Escrow redistributed:", redistributed);

        // Insurance payout snapshot
        IInsurancePool.PoolStatus memory ps = insurancePool.getPoolStatus(_poolId);
        assertTrue(ps.isTriggered);
        assertEq(ps.balance, insuranceETHBefore);
        console.log("  Insurance payout (ETH):", ps.balance);

        // Escrow release blocked
        vm.expectRevert(abi.encodeWithSelector(EscrowVault.EscrowTriggered.selector));
        escrowVault.releaseVested(_escrowId);
    }

    function _scenario3_claims() internal {
        // Trader1 claims
        uint256 t1Bal = issuedToken.balanceOf(trader1);
        uint256 comp1 = insurancePool.calculateCompensation(_poolId, t1Bal);
        assertGt(comp1, 0);

        uint256 ethBefore = trader1.balance;

        vm.expectEmit(true, true, false, true, address(insurancePool));
        emit IInsurancePool.CompensationClaimed(_poolId, trader1, comp1);

        vm.prank(trader1);
        uint256 g = gasleft();
        insurancePool.claimCompensation(_poolId, t1Bal);
        console.log("Gas: claimCompensation (trader1)", g - gasleft());

        assertEq(trader1.balance - ethBefore, comp1);
        console.log("  Trader1 claimed:", comp1);

        // Trader2 claims
        uint256 t2Bal = issuedToken.balanceOf(trader2);
        uint256 comp2 = insurancePool.calculateCompensation(_poolId, t2Bal);
        assertGt(comp2, 0);

        ethBefore = trader2.balance;
        vm.prank(trader2);
        g = gasleft();
        insurancePool.claimCompensation(_poolId, t2Bal);
        console.log("Gas: claimCompensation (trader2)", g - gasleft());

        assertEq(trader2.balance - ethBefore, comp2);
        console.log("  Trader2 claimed:", comp2);

        // Both marked claimed
        assertTrue(insurancePool.hasClaimed(_poolId, trader1));
        assertTrue(insurancePool.hasClaimed(_poolId, trader2));

        // Duplicate blocked
        vm.prank(trader1);
        vm.expectRevert(abi.encodeWithSelector(InsurancePool.AlreadyClaimed.selector));
        insurancePool.claimCompensation(_poolId, t1Bal);
    }

    function _scenario3_claimExpiry() internal {
        vm.warp(block.timestamp + 31 days);

        vm.prank(address(this));
        vm.expectRevert(abi.encodeWithSelector(InsurancePool.ClaimPeriodExpired.selector));
        insurancePool.claimCompensation(_poolId, 1000 ether);
        console.log("  Claim after 30d window correctly blocked");
    }
}
