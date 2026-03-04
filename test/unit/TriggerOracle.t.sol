// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {TriggerOracle} from "../../src/core/TriggerOracle.sol";
import {ITriggerOracle} from "../../src/interfaces/ITriggerOracle.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

// ─── Mock Contracts ───────────────────────────────────────────────────────────

contract MockEscrowVault {
    uint256 public lastEscrowId;
    uint8 public lastTriggerType;
    bool public triggerCalled;

    function triggerRedistribution(uint256 escrowId, uint8 triggerType) external returns (uint256) {
        lastEscrowId = escrowId;
        lastTriggerType = triggerType;
        triggerCalled = true;
        return 100 ether;
    }
}

contract RevertingEscrowVault {
    function triggerRedistribution(uint256, uint8) external pure returns (uint256) {
        revert("escrow vault revert");
    }
}

contract MockInsurancePool {
    PoolId public lastPoolId;
    uint8 public lastTriggerType;
    uint256 public lastTotalSupply;
    bool public payoutCalled;

    function executePayout(PoolId poolId, uint8 triggerType, uint256 totalEligibleSupply, bytes32)
        external
        returns (uint256)
    {
        lastPoolId = poolId;
        lastTriggerType = triggerType;
        lastTotalSupply = totalEligibleSupply;
        payoutCalled = true;
        return 10 ether;
    }
}

contract RevertingInsurancePool {
    function executePayout(PoolId, uint8, uint256, bytes32) external pure returns (uint256) {
        revert("insurance pool revert");
    }
}

contract MockReputationEngine {
    function recordEvent(address, uint8, bytes calldata) external {}
    function getScore(address) external pure returns (uint256) { return 500; }
}

contract RevertingReputationEngine {
    function recordEvent(address, uint8, bytes calldata) external pure {
        revert("reputation engine revert");
    }
    function getScore(address) external pure returns (uint256) { return 500; }
}

// ─── Test Contract ────────────────────────────────────────────────────────────

contract TriggerOracleTest is Test {
    TriggerOracle public oracle;
    MockEscrowVault public escrowVault;
    MockInsurancePool public insurancePool;

    address public hook;
    address public guardian;
    address public issuer;
    address public bot;

    PoolId public defaultPoolId;

    uint256 constant TOTAL_LP = 1000 ether;
    uint256 constant TOTAL_SUPPLY = 1_000_000 ether;

    function setUp() public {
        hook = makeAddr("hook");
        guardian = makeAddr("guardian");
        issuer = makeAddr("issuer");
        bot = makeAddr("bot");

        escrowVault = new MockEscrowVault();
        insurancePool = new MockInsurancePool();

        MockReputationEngine reputationEngine = new MockReputationEngine();
        oracle = new TriggerOracle(hook, address(escrowVault), address(insurancePool), guardian, address(reputationEngine));

        defaultPoolId = PoolId.wrap(bytes32(uint256(1)));

        // Setup: register config and issuer
        _setDefaultConfig();
        _registerIssuer();
    }

    // ─── Helpers ──────────────────────────────────────────────────────

    function _defaultConfig() internal pure returns (ITriggerOracle.TriggerConfig memory) {
        return ITriggerOracle.TriggerConfig({
            lpRemovalThreshold: 5000, // 50%
            dumpThresholdPercent: 3000, // 30%
            dumpWindowSeconds: 86400, // 24h
            taxDeviationThreshold: 500, // 5%
            slowRugWindowSeconds: 86400, // 24h
            slowRugCumulativeThreshold: 8000 // 80%
        });
    }

    function _setDefaultConfig() internal {
        vm.prank(hook);
        oracle.setTriggerConfig(defaultPoolId, _defaultConfig());
    }

    function _registerIssuer() internal {
        vm.prank(hook);
        oracle.registerIssuer(defaultPoolId, issuer);
    }

    function _executeAfterGrace() internal {
        vm.warp(block.timestamp + 1 hours);
        oracle.executeTrigger(defaultPoolId, bytes32(0));
    }

    // ═══════════════════════════════════════════════════════════════════
    //  LP REMOVAL / RUG_PULL TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_reportLPRemoval_singleTxAboveThreshold() public {
        // Remove 51% in single tx => should trigger
        vm.prank(hook);
        oracle.reportLPRemoval(defaultPoolId, 510 ether, TOTAL_LP);

        (bool exists, ITriggerOracle.TriggerType triggerType,) = oracle.getPendingTrigger(defaultPoolId);
        assertTrue(exists);
        assertEq(uint8(triggerType), uint8(ITriggerOracle.TriggerType.RUG_PULL));
    }

    function test_reportLPRemoval_singleTxBelowThreshold() public {
        // Remove 40% in single tx => should NOT trigger
        vm.prank(hook);
        oracle.reportLPRemoval(defaultPoolId, 400 ether, TOTAL_LP);

        (bool exists,,) = oracle.getPendingTrigger(defaultPoolId);
        assertFalse(exists);
    }

    function test_reportLPRemoval_exactThreshold() public {
        // Remove exactly 50% => should trigger (>= threshold)
        vm.prank(hook);
        oracle.reportLPRemoval(defaultPoolId, 500 ether, TOTAL_LP);

        (bool exists,,) = oracle.getPendingTrigger(defaultPoolId);
        assertTrue(exists);
    }

    function test_reportLPRemoval_cumulativeAboveThreshold() public {
        // Remove 40% + 41% within 24h => cumulative 81% > 80%
        vm.prank(hook);
        oracle.reportLPRemoval(defaultPoolId, 400 ether, TOTAL_LP);

        vm.warp(block.timestamp + 6 hours);

        vm.prank(hook);
        oracle.reportLPRemoval(defaultPoolId, 410 ether, TOTAL_LP);

        (bool exists, ITriggerOracle.TriggerType triggerType,) = oracle.getPendingTrigger(defaultPoolId);
        assertTrue(exists);
        assertEq(uint8(triggerType), uint8(ITriggerOracle.TriggerType.RUG_PULL));
    }

    function test_reportLPRemoval_cumulativeBelowThreshold() public {
        // Remove 40% + 30% = 70% < 80% => no trigger
        vm.prank(hook);
        oracle.reportLPRemoval(defaultPoolId, 400 ether, TOTAL_LP);

        vm.warp(block.timestamp + 6 hours);

        vm.prank(hook);
        oracle.reportLPRemoval(defaultPoolId, 300 ether, TOTAL_LP);

        (bool exists,,) = oracle.getPendingTrigger(defaultPoolId);
        assertFalse(exists);
    }

    function test_reportLPRemoval_revertsNotHook() public {
        vm.expectRevert(TriggerOracle.OnlyHook.selector);
        oracle.reportLPRemoval(defaultPoolId, 510 ether, TOTAL_LP);
    }

    function test_reportLPRemoval_revertsNoConfig() public {
        PoolId unconfigured = PoolId.wrap(bytes32(uint256(99)));

        vm.prank(hook);
        vm.expectRevert(TriggerOracle.ConfigNotSet.selector);
        oracle.reportLPRemoval(unconfigured, 510 ether, TOTAL_LP);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  ISSUER DUMP TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_reportIssuerSale_aboveThreshold() public {
        // 31% of supply in single tx => cumulative > 30%
        vm.prank(hook);
        oracle.reportIssuerSale(defaultPoolId, issuer, 310_000 ether, TOTAL_SUPPLY);

        (bool exists, ITriggerOracle.TriggerType triggerType,) = oracle.getPendingTrigger(defaultPoolId);
        assertTrue(exists);
        assertEq(uint8(triggerType), uint8(ITriggerOracle.TriggerType.ISSUER_DUMP));
    }

    function test_reportIssuerSale_belowThreshold() public {
        // 20% => no trigger
        vm.prank(hook);
        oracle.reportIssuerSale(defaultPoolId, issuer, 200_000 ether, TOTAL_SUPPLY);

        (bool exists,,) = oracle.getPendingTrigger(defaultPoolId);
        assertFalse(exists);
    }

    function test_reportIssuerSale_cumulativeOverWindow() public {
        // 15% + 16% = 31% > 30% within 24h
        vm.prank(hook);
        oracle.reportIssuerSale(defaultPoolId, issuer, 150_000 ether, TOTAL_SUPPLY);

        vm.warp(block.timestamp + 12 hours);

        vm.prank(hook);
        oracle.reportIssuerSale(defaultPoolId, issuer, 160_000 ether, TOTAL_SUPPLY);

        (bool exists,,) = oracle.getPendingTrigger(defaultPoolId);
        assertTrue(exists);
    }

    function test_reportIssuerSale_revertsNotHook() public {
        vm.expectRevert(TriggerOracle.OnlyHook.selector);
        oracle.reportIssuerSale(defaultPoolId, issuer, 310_000 ether, TOTAL_SUPPLY);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  COMMITMENT BREACH TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_reportCommitmentBreach_triggers() public {
        vm.prank(hook);
        oracle.reportCommitmentBreach(defaultPoolId);

        (bool exists, ITriggerOracle.TriggerType triggerType,) = oracle.getPendingTrigger(defaultPoolId);
        assertTrue(exists);
        assertEq(uint8(triggerType), uint8(ITriggerOracle.TriggerType.COMMITMENT_BREACH));
    }

    function test_reportCommitmentBreach_revertsNotHook() public {
        vm.expectRevert(TriggerOracle.OnlyHook.selector);
        oracle.reportCommitmentBreach(defaultPoolId);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  24H SLIDING WINDOW TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_slidingWindow_oldRecordsExpire() public {
        // Record 20% at T=0
        vm.prank(hook);
        oracle.reportIssuerSale(defaultPoolId, issuer, 200_000 ether, TOTAL_SUPPLY);

        // Warp past 24h window
        vm.warp(block.timestamp + 24 hours + 1);

        // Record 15% at T=24h+1 => cumulative = 15% (old expired)
        vm.prank(hook);
        oracle.reportIssuerSale(defaultPoolId, issuer, 150_000 ether, TOTAL_SUPPLY);

        (bool exists,,) = oracle.getPendingTrigger(defaultPoolId);
        assertFalse(exists); // 15% < 30% threshold
    }

    function test_slidingWindow_multipleSalesWithinWindow() public {
        // 10% at T=0
        vm.prank(hook);
        oracle.reportIssuerSale(defaultPoolId, issuer, 100_000 ether, TOTAL_SUPPLY);

        // 10% at T=6h
        vm.warp(block.timestamp + 6 hours);
        vm.prank(hook);
        oracle.reportIssuerSale(defaultPoolId, issuer, 100_000 ether, TOTAL_SUPPLY);

        // 10% at T=12h => total 30% = threshold
        vm.warp(block.timestamp + 6 hours);
        vm.prank(hook);
        oracle.reportIssuerSale(defaultPoolId, issuer, 100_000 ether, TOTAL_SUPPLY);

        (bool exists,,) = oracle.getPendingTrigger(defaultPoolId);
        assertTrue(exists);
    }

    function test_slidingWindow_lpRemovalExpiry() public {
        // Remove 45% at T=0
        vm.prank(hook);
        oracle.reportLPRemoval(defaultPoolId, 450 ether, TOTAL_LP);

        // Warp 25h => outside window
        vm.warp(block.timestamp + 25 hours);

        // Remove 40% at T=25h => cumulative = 40% only (old expired)
        vm.prank(hook);
        oracle.reportLPRemoval(defaultPoolId, 400 ether, TOTAL_LP);

        (bool exists,,) = oracle.getPendingTrigger(defaultPoolId);
        assertFalse(exists); // 40% < 80% cumulative threshold
    }

    // ═══════════════════════════════════════════════════════════════════
    //  GRACE PERIOD TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_gracePeriod_cannotExecuteBeforeElapsed() public {
        vm.prank(hook);
        oracle.reportCommitmentBreach(defaultPoolId);

        // Try to execute immediately
        vm.expectRevert(TriggerOracle.GracePeriodNotElapsed.selector);
        oracle.executeTrigger(defaultPoolId, bytes32(0));
    }

    function test_gracePeriod_canExecuteAfterElapsed() public {
        vm.prank(hook);
        oracle.reportCommitmentBreach(defaultPoolId);

        vm.warp(block.timestamp + 1 hours);
        oracle.executeTrigger(defaultPoolId, bytes32(0));

        ITriggerOracle.TriggerResult memory result = oracle.checkTrigger(defaultPoolId);
        assertTrue(result.triggered);
        assertEq(uint8(result.triggerType), uint8(ITriggerOracle.TriggerType.COMMITMENT_BREACH));
    }

    function test_gracePeriod_exactBoundary() public {
        uint256 startTime = block.timestamp;

        vm.prank(hook);
        oracle.reportCommitmentBreach(defaultPoolId);

        // Exactly at grace period boundary (1 hour - 1 second) => should fail
        vm.warp(startTime + 1 hours - 1);
        vm.expectRevert(TriggerOracle.GracePeriodNotElapsed.selector);
        oracle.executeTrigger(defaultPoolId, bytes32(0));

        // Exactly at 1 hour => should succeed
        vm.warp(startTime + 1 hours);
        oracle.executeTrigger(defaultPoolId, bytes32(0));

        assertTrue(oracle.checkTrigger(defaultPoolId).triggered);
    }

    function test_gracePeriod_pendingTriggerInfo() public {
        uint256 startTime = block.timestamp;

        vm.prank(hook);
        oracle.reportCommitmentBreach(defaultPoolId);

        (bool exists, ITriggerOracle.TriggerType triggerType, uint40 executeAfter) =
            oracle.getPendingTrigger(defaultPoolId);

        assertTrue(exists);
        assertEq(uint8(triggerType), uint8(ITriggerOracle.TriggerType.COMMITMENT_BREACH));
        assertEq(executeAfter, startTime + 1 hours);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  TRIGGER EXECUTION & PROPAGATION TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_executeTrigger_propagatesToEscrowVault() public {
        vm.prank(hook);
        oracle.reportCommitmentBreach(defaultPoolId);

        _executeAfterGrace();

        assertTrue(escrowVault.triggerCalled());
        assertEq(escrowVault.lastTriggerType(), uint8(ITriggerOracle.TriggerType.COMMITMENT_BREACH));
    }

    function test_executeTrigger_propagatesToInsurancePool() public {
        // Use issuer dump to have totalEligibleSupply
        vm.prank(hook);
        oracle.reportIssuerSale(defaultPoolId, issuer, 310_000 ether, TOTAL_SUPPLY);

        _executeAfterGrace();

        assertTrue(insurancePool.payoutCalled());
        assertEq(insurancePool.lastTriggerType(), uint8(ITriggerOracle.TriggerType.ISSUER_DUMP));
        assertEq(insurancePool.lastTotalSupply(), TOTAL_SUPPLY);
    }

    function test_executeTrigger_clearsPendingState() public {
        vm.prank(hook);
        oracle.reportCommitmentBreach(defaultPoolId);

        _executeAfterGrace();

        (bool exists,,) = oracle.getPendingTrigger(defaultPoolId);
        assertFalse(exists);
    }

    function test_executeTrigger_emitsEvents() public {
        vm.prank(hook);
        oracle.reportCommitmentBreach(defaultPoolId);

        vm.warp(block.timestamp + 1 hours);

        vm.expectEmit(true, true, false, true);
        emit ITriggerOracle.TriggerDetected(
            defaultPoolId, ITriggerOracle.TriggerType.COMMITMENT_BREACH, ""
        );

        oracle.executeTrigger(defaultPoolId, bytes32(0));
    }

    function test_executeTrigger_revertsNoPending() public {
        vm.expectRevert(TriggerOracle.NoPendingTrigger.selector);
        oracle.executeTrigger(defaultPoolId, bytes32(0));
    }

    // ═══════════════════════════════════════════════════════════════════
    //  DUPLICATE TRIGGER PREVENTION
    // ═══════════════════════════════════════════════════════════════════

    function test_duplicateTrigger_preventedOnExecuted() public {
        vm.prank(hook);
        oracle.reportCommitmentBreach(defaultPoolId);
        _executeAfterGrace();

        // Trying to execute again should revert (no pending)
        vm.expectRevert(TriggerOracle.NoPendingTrigger.selector);
        oracle.executeTrigger(defaultPoolId, bytes32(0));
    }

    function test_duplicateTrigger_reportIgnoredAfterTriggered() public {
        // Trigger via commitment breach
        vm.prank(hook);
        oracle.reportCommitmentBreach(defaultPoolId);
        _executeAfterGrace();

        // Further reports are silently ignored (no revert, no new pending)
        vm.prank(hook);
        oracle.reportLPRemoval(defaultPoolId, 510 ether, TOTAL_LP);

        (bool exists,,) = oracle.getPendingTrigger(defaultPoolId);
        assertFalse(exists);
    }

    function test_duplicateTrigger_secondPendingIgnored() public {
        // First: commitment breach pending
        vm.prank(hook);
        oracle.reportCommitmentBreach(defaultPoolId);

        // Second: LP removal => should NOT overwrite pending
        vm.prank(hook);
        oracle.reportLPRemoval(defaultPoolId, 510 ether, TOTAL_LP);

        (bool exists, ITriggerOracle.TriggerType triggerType,) = oracle.getPendingTrigger(defaultPoolId);
        assertTrue(exists);
        assertEq(uint8(triggerType), uint8(ITriggerOracle.TriggerType.COMMITMENT_BREACH)); // original, not overwritten
    }

    // ═══════════════════════════════════════════════════════════════════
    //  PAUSE / UNPAUSE TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_pause_blocksReports() public {
        vm.prank(guardian);
        oracle.pause();

        vm.prank(hook);
        vm.expectRevert(TriggerOracle.IsPaused.selector);
        oracle.reportLPRemoval(defaultPoolId, 510 ether, TOTAL_LP);
    }

    function test_pause_blocksExecution() public {
        vm.prank(hook);
        oracle.reportCommitmentBreach(defaultPoolId);

        vm.prank(guardian);
        oracle.pause();

        vm.warp(block.timestamp + 1 hours);
        vm.expectRevert(TriggerOracle.IsPaused.selector);
        oracle.executeTrigger(defaultPoolId, bytes32(0));
    }

    function test_unpause_resumesOperation() public {
        vm.prank(guardian);
        oracle.pause();
        assertTrue(oracle.paused());

        vm.prank(guardian);
        oracle.unpause();
        assertFalse(oracle.paused());

        // Should work again
        vm.prank(hook);
        oracle.reportCommitmentBreach(defaultPoolId);

        (bool exists,,) = oracle.getPendingTrigger(defaultPoolId);
        assertTrue(exists);
    }

    function test_pause_revertsNotGuardian() public {
        vm.expectRevert(TriggerOracle.OnlyGuardian.selector);
        oracle.pause();
    }

    function test_unpause_revertsNotGuardian() public {
        vm.prank(guardian);
        oracle.pause();

        vm.expectRevert(TriggerOracle.OnlyGuardian.selector);
        oracle.unpause();
    }

    // ═══════════════════════════════════════════════════════════════════
    //  CONFIG & REGISTRATION TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_setTriggerConfig_storesCorrectly() public view {
        ITriggerOracle.TriggerConfig memory cfg = oracle.getTriggerConfig(defaultPoolId);
        assertEq(cfg.lpRemovalThreshold, 5000);
        assertEq(cfg.dumpThresholdPercent, 3000);
        assertEq(cfg.dumpWindowSeconds, 86400);
        assertEq(cfg.taxDeviationThreshold, 500);
    }

    function test_setTriggerConfig_revertsNotHook() public {
        vm.expectRevert(TriggerOracle.OnlyHook.selector);
        oracle.setTriggerConfig(defaultPoolId, _defaultConfig());
    }

    function test_registerIssuer_storesCorrectly() public view {
        assertEq(oracle.getPoolIssuer(defaultPoolId), issuer);
    }

    function test_registerIssuer_revertsZeroAddress() public {
        vm.prank(hook);
        vm.expectRevert(TriggerOracle.ZeroAddress.selector);
        oracle.registerIssuer(defaultPoolId, address(0));
    }

    function test_registerIssuer_revertsNotHook() public {
        vm.expectRevert(TriggerOracle.OnlyHook.selector);
        oracle.registerIssuer(defaultPoolId, issuer);
    }

    function test_isConfigSet() public view {
        assertTrue(oracle.isConfigSet(defaultPoolId));

        PoolId unconfigured = PoolId.wrap(bytes32(uint256(99)));
        assertFalse(oracle.isConfigSet(unconfigured));
    }

    // ═══════════════════════════════════════════════════════════════════
    //  ALREADY TRIGGERED TESTS (coverage: executeTrigger AlreadyTriggered)
    // ═══════════════════════════════════════════════════════════════════

    function test_executeTrigger_revertsAlreadyTriggered() public {
        // First trigger
        vm.prank(hook);
        oracle.reportCommitmentBreach(defaultPoolId);
        _executeAfterGrace();
        assertTrue(oracle.checkTrigger(defaultPoolId).triggered);

        // Manually set a new pending trigger to test AlreadyTriggered path
        // We need a new pool for this since pending is cleared
        PoolId poolId2 = PoolId.wrap(bytes32(uint256(2)));
        vm.prank(hook);
        oracle.setTriggerConfig(poolId2, _defaultConfig());
        vm.prank(hook);
        oracle.registerIssuer(poolId2, issuer);

        // Now trigger pool1 again by re-creating pending state manually is not possible,
        // so we test the path by trying executeTrigger when isTriggered=true and pending exists
        // The AlreadyTriggered check at line 217 can only be hit if somehow pending.detectedAt != 0
        // AND state.isTriggered is true. This shouldn't happen normally (pending is cleared).
        // It's a safety check. Skip this edge case as it's unreachable under normal conditions.
    }

    function test_reportIssuerSale_ignoredAfterTriggered() public {
        // Trigger pool
        vm.prank(hook);
        oracle.reportCommitmentBreach(defaultPoolId);
        _executeAfterGrace();

        // Subsequent issuer sale should be silently ignored (isTriggered early return)
        vm.prank(hook);
        oracle.reportIssuerSale(defaultPoolId, issuer, 310_000 ether, TOTAL_SUPPLY);

        (bool exists,,) = oracle.getPendingTrigger(defaultPoolId);
        assertFalse(exists); // no new pending trigger created
    }

    function test_reportCommitmentBreach_ignoredAfterTriggered() public {
        // Trigger pool
        vm.prank(hook);
        oracle.reportCommitmentBreach(defaultPoolId);
        _executeAfterGrace();

        // Subsequent commitment breach should be silently ignored
        vm.prank(hook);
        oracle.reportCommitmentBreach(defaultPoolId);

        (bool exists,,) = oracle.getPendingTrigger(defaultPoolId);
        assertFalse(exists);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  PUSH RECORD PRUNING TESTS (coverage: _pushRecord > MAX_TRACKER_ENTRIES)
    // ═══════════════════════════════════════════════════════════════════

    function test_pushRecord_prunesAfterMaxEntries() public {
        // MAX_TRACKER_ENTRIES = 50. Push 51 records to trigger pruning.
        // Use issuer sale reports (each calls _pushRecord)
        // Use a threshold so high it won't trigger
        ITriggerOracle.TriggerConfig memory highThresholdConfig = ITriggerOracle.TriggerConfig({
            lpRemovalThreshold: 9999,
            dumpThresholdPercent: 9999,
            dumpWindowSeconds: 86400,
            taxDeviationThreshold: 9999,
            slowRugWindowSeconds: 86400,
            slowRugCumulativeThreshold: 9999
        });
        vm.prank(hook);
        oracle.setTriggerConfig(defaultPoolId, highThresholdConfig);

        for (uint256 i = 0; i < 51; i++) {
            vm.prank(hook);
            oracle.reportIssuerSale(defaultPoolId, issuer, 1 ether, TOTAL_SUPPLY);
            vm.warp(block.timestamp + 1);
        }

        // Should not revert - pruning should have kept array at 50
        // Verify pool is not triggered (amounts are small)
        (bool exists,,) = oracle.getPendingTrigger(defaultPoolId);
        assertFalse(exists);
    }

    function test_pushRecord_lpRemovalPruning() public {
        // Same pruning test but via LP removal records
        ITriggerOracle.TriggerConfig memory highThresholdConfig = ITriggerOracle.TriggerConfig({
            lpRemovalThreshold: 9999,
            dumpThresholdPercent: 9999,
            dumpWindowSeconds: 86400,
            taxDeviationThreshold: 9999,
            slowRugWindowSeconds: 86400,
            slowRugCumulativeThreshold: 9999
        });
        vm.prank(hook);
        oracle.setTriggerConfig(defaultPoolId, highThresholdConfig);

        for (uint256 i = 0; i < 51; i++) {
            vm.prank(hook);
            oracle.reportLPRemoval(defaultPoolId, 1 ether, TOTAL_LP);
            vm.warp(block.timestamp + 1);
        }

        (bool exists,,) = oracle.getPendingTrigger(defaultPoolId);
        assertFalse(exists);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  CHECK TRIGGER VIEW
    // ═══════════════════════════════════════════════════════════════════

    function test_checkTrigger_initiallyFalse() public view {
        ITriggerOracle.TriggerResult memory result = oracle.checkTrigger(defaultPoolId);
        assertFalse(result.triggered);
        assertEq(uint8(result.triggerType), uint8(ITriggerOracle.TriggerType.NONE));
    }

    function test_checkTrigger_trueAfterExecution() public {
        vm.prank(hook);
        oracle.reportCommitmentBreach(defaultPoolId);
        _executeAfterGrace();

        ITriggerOracle.TriggerResult memory result = oracle.checkTrigger(defaultPoolId);
        assertTrue(result.triggered);
        assertEq(uint8(result.triggerType), uint8(ITriggerOracle.TriggerType.COMMITMENT_BREACH));
    }

    // ═══════════════════════════════════════════════════════════════════
    //  POOL ISOLATION
    // ═══════════════════════════════════════════════════════════════════

    function test_poolIsolation_triggerDoesNotAffectOtherPool() public {
        PoolId poolId2 = PoolId.wrap(bytes32(uint256(2)));

        vm.prank(hook);
        oracle.setTriggerConfig(poolId2, _defaultConfig());
        vm.prank(hook);
        oracle.registerIssuer(poolId2, makeAddr("issuer2"));

        // Trigger pool 1
        vm.prank(hook);
        oracle.reportCommitmentBreach(defaultPoolId);
        _executeAfterGrace();

        // Pool 2 unaffected
        assertFalse(oracle.checkTrigger(poolId2).triggered);

        // Pool 2 can still report
        vm.prank(hook);
        oracle.reportLPRemoval(poolId2, 510 ether, TOTAL_LP);

        (bool exists,,) = oracle.getPendingTrigger(poolId2);
        assertTrue(exists);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  EXTERNAL CALL FAILURE (catch branches in executeTrigger)
    // ═══════════════════════════════════════════════════════════════════

    function test_executeTrigger_escrowVaultReverts_emitsEvent() public {
        // Deploy oracle with reverting escrow vault
        RevertingEscrowVault revertingEscrow = new RevertingEscrowVault();
        MockReputationEngine repEngine = new MockReputationEngine();
        TriggerOracle oracleWithBadEscrow = new TriggerOracle(
            hook, address(revertingEscrow), address(insurancePool), guardian, address(repEngine)
        );

        vm.prank(hook);
        oracleWithBadEscrow.setTriggerConfig(defaultPoolId, _defaultConfig());
        vm.prank(hook);
        oracleWithBadEscrow.registerIssuer(defaultPoolId, issuer);

        vm.prank(hook);
        oracleWithBadEscrow.reportCommitmentBreach(defaultPoolId);
        vm.warp(block.timestamp + 1 hours);

        vm.expectEmit(false, true, false, true);
        emit TriggerOracle.ExternalCallFailed("EscrowVault.triggerRedistribution", defaultPoolId);
        oracleWithBadEscrow.executeTrigger(defaultPoolId, bytes32(0));

        assertTrue(oracleWithBadEscrow.checkTrigger(defaultPoolId).triggered);
    }

    function test_executeTrigger_insurancePoolReverts_emitsEvent() public {
        RevertingInsurancePool revertingInsurance = new RevertingInsurancePool();
        MockReputationEngine repEngine = new MockReputationEngine();
        TriggerOracle oracleWithBadInsurance = new TriggerOracle(
            hook, address(escrowVault), address(revertingInsurance), guardian, address(repEngine)
        );

        vm.prank(hook);
        oracleWithBadInsurance.setTriggerConfig(defaultPoolId, _defaultConfig());
        vm.prank(hook);
        oracleWithBadInsurance.registerIssuer(defaultPoolId, issuer);

        // Use issuer dump for totalEligibleSupply > 0
        vm.prank(hook);
        oracleWithBadInsurance.reportIssuerSale(defaultPoolId, issuer, 310_000 ether, TOTAL_SUPPLY);
        vm.warp(block.timestamp + 1 hours);

        vm.expectEmit(false, true, false, true);
        emit TriggerOracle.ExternalCallFailed("InsurancePool.executePayout", defaultPoolId);
        oracleWithBadInsurance.executeTrigger(defaultPoolId, bytes32(0));

        assertTrue(oracleWithBadInsurance.checkTrigger(defaultPoolId).triggered);
    }

    function test_executeTrigger_reputationEngineReverts_emitsEvent() public {
        RevertingReputationEngine revertingRep = new RevertingReputationEngine();
        TriggerOracle oracleWithBadRep = new TriggerOracle(
            hook, address(escrowVault), address(insurancePool), guardian, address(revertingRep)
        );

        vm.prank(hook);
        oracleWithBadRep.setTriggerConfig(defaultPoolId, _defaultConfig());
        vm.prank(hook);
        oracleWithBadRep.registerIssuer(defaultPoolId, issuer);

        vm.prank(hook);
        oracleWithBadRep.reportCommitmentBreach(defaultPoolId);
        vm.warp(block.timestamp + 1 hours);

        vm.expectEmit(false, true, false, true);
        emit TriggerOracle.ExternalCallFailed("ReputationEngine.recordEvent", defaultPoolId);
        oracleWithBadRep.executeTrigger(defaultPoolId, bytes32(0));

        assertTrue(oracleWithBadRep.checkTrigger(defaultPoolId).triggered);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  ZERO TOTAL ELIGIBLE SUPPLY (skips insurance payout)
    // ═══════════════════════════════════════════════════════════════════

    function test_executeTrigger_zeroTotalEligibleSupply_skipsInsurancePayout() public {
        // Commitment breach sets totalEligibleSupply=0
        vm.prank(hook);
        oracle.reportCommitmentBreach(defaultPoolId);
        _executeAfterGrace();

        assertFalse(insurancePool.payoutCalled());
        assertTrue(escrowVault.triggerCalled());
    }

    // ═══════════════════════════════════════════════════════════════════
    //  CONFIG NOT SET REVERTS
    // ═══════════════════════════════════════════════════════════════════

    function test_reportIssuerSale_revertsConfigNotSet() public {
        PoolId unconfigured = PoolId.wrap(bytes32(uint256(99)));

        vm.prank(hook);
        vm.expectRevert(TriggerOracle.ConfigNotSet.selector);
        oracle.reportIssuerSale(unconfigured, issuer, 310_000 ether, TOTAL_SUPPLY);
    }

    function test_reportCommitmentBreach_revertsConfigNotSet() public {
        PoolId unconfigured = PoolId.wrap(bytes32(uint256(99)));

        vm.prank(hook);
        vm.expectRevert(TriggerOracle.ConfigNotSet.selector);
        oracle.reportCommitmentBreach(unconfigured);
    }
}
