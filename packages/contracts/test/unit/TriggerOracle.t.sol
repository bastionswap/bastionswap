// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {TriggerOracle} from "../../src/core/TriggerOracle.sol";
import {ITriggerOracle} from "../../src/interfaces/ITriggerOracle.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

// ─── Mock Contracts ───────────────────────────────────────────────────────────

contract MockEscrowVault {
    uint256 public lastEscrowId;
    uint8 public lastTriggerType;
    bool public triggerCalled;

    function triggerForceRemoval(uint256 escrowId, uint8 triggerType) external {
        lastEscrowId = escrowId;
        lastTriggerType = triggerType;
        triggerCalled = true;
    }
}

contract RevertingEscrowVault {
    function triggerForceRemoval(uint256, uint8) external pure {
        revert("escrow vault revert");
    }
}

contract MockInsurancePool {
    PoolId public lastPoolId;
    uint8 public lastTriggerType;
    uint256 public lastTotalSupply;
    bool public payoutCalled;

    function executePayout(PoolId poolId, uint8 triggerType, uint256 totalEligibleSupply, address)
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
    function executePayout(PoolId, uint8, uint256, address) external pure returns (uint256) {
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
    address public governance;
    address public issuer;
    address public bot;

    PoolId public defaultPoolId;
    PoolKey public defaultPoolKey;

    uint256 constant TOTAL_SUPPLY = 1_000_000 ether;

    function setUp() public {
        hook = makeAddr("hook");
        guardian = makeAddr("guardian");
        governance = makeAddr("governance");
        issuer = makeAddr("issuer");
        bot = makeAddr("bot");

        escrowVault = new MockEscrowVault();
        insurancePool = new MockInsurancePool();

        MockReputationEngine reputationEngine = new MockReputationEngine();
        oracle = new TriggerOracle(hook, address(escrowVault), address(insurancePool), guardian, address(reputationEngine), governance);

        defaultPoolId = PoolId.wrap(bytes32(uint256(1)));

        // Build a dummy PoolKey for executeTrigger calls
        defaultPoolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(0xBEEF)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });

        // Setup: register config and issuer
        _setDefaultConfig();
        _registerIssuer();
    }

    // ─── Helpers ──────────────────────────────────────────────────────

    function _defaultConfig() internal pure returns (ITriggerOracle.TriggerConfig memory) {
        return ITriggerOracle.TriggerConfig({
            dailyLpRemovalBps: 1000, // 10%
            weeklyLpRemovalBps: 3000, // 30%
            dumpThresholdPercent: 300, // 3%
            dumpWindowSeconds: 86400, // 24h
            taxDeviationThreshold: 500, // 5%
            weeklyDumpWindowSeconds: 604800, // 7d
            weeklyDumpThresholdPercent: 1500 // 15%
        });
    }

    function _setDefaultConfig() internal {
        vm.prank(hook);
        oracle.setTriggerConfig(defaultPoolId, _defaultConfig());
    }

    function _registerIssuer() internal {
        vm.prank(hook);
        oracle.registerIssuer(defaultPoolId, issuer, TOTAL_SUPPLY, address(0xBEEF));
    }

    // ═══════════════════════════════════════════════════════════════════
    //  EXECUTE TRIGGER TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_executeTrigger_byHook_succeeds() public {
        vm.prank(hook);
        oracle.executeTrigger(defaultPoolId, defaultPoolKey, ITriggerOracle.TriggerType.RUG_PULL, TOTAL_SUPPLY);

        ITriggerOracle.TriggerResult memory result = oracle.checkTrigger(defaultPoolId);
        assertTrue(result.triggered);
        assertEq(uint8(result.triggerType), uint8(ITriggerOracle.TriggerType.RUG_PULL));
    }

    function test_executeTrigger_byNonHook_reverts() public {
        vm.expectRevert(TriggerOracle.OnlyHook.selector);
        oracle.executeTrigger(defaultPoolId, defaultPoolKey, ITriggerOracle.TriggerType.RUG_PULL, TOTAL_SUPPLY);
    }

    function test_executeTrigger_alreadyTriggered_reverts() public {
        vm.prank(hook);
        oracle.executeTrigger(defaultPoolId, defaultPoolKey, ITriggerOracle.TriggerType.RUG_PULL, TOTAL_SUPPLY);

        vm.prank(hook);
        vm.expectRevert(TriggerOracle.AlreadyTriggered.selector);
        oracle.executeTrigger(defaultPoolId, defaultPoolKey, ITriggerOracle.TriggerType.ISSUER_DUMP, TOTAL_SUPPLY);
    }

    function test_executeTrigger_configNotSet_reverts() public {
        PoolId unconfigured = PoolId.wrap(bytes32(uint256(99)));

        vm.prank(hook);
        vm.expectRevert(TriggerOracle.ConfigNotSet.selector);
        oracle.executeTrigger(unconfigured, defaultPoolKey, ITriggerOracle.TriggerType.RUG_PULL, TOTAL_SUPPLY);
    }

    function test_executeTrigger_propagatesToEscrowVault() public {
        vm.prank(hook);
        oracle.executeTrigger(defaultPoolId, defaultPoolKey, ITriggerOracle.TriggerType.RUG_PULL, TOTAL_SUPPLY);

        assertTrue(escrowVault.triggerCalled());
        assertEq(escrowVault.lastTriggerType(), uint8(ITriggerOracle.TriggerType.RUG_PULL));
    }

    function test_executeTrigger_propagatesToInsurancePool() public {
        vm.prank(hook);
        oracle.executeTrigger(defaultPoolId, defaultPoolKey, ITriggerOracle.TriggerType.ISSUER_DUMP, TOTAL_SUPPLY);

        assertTrue(insurancePool.payoutCalled());
        assertEq(insurancePool.lastTriggerType(), uint8(ITriggerOracle.TriggerType.ISSUER_DUMP));
        assertEq(insurancePool.lastTotalSupply(), TOTAL_SUPPLY);
    }

    function test_executeTrigger_zeroSupply_skipsInsurancePayout() public {
        vm.prank(hook);
        oracle.executeTrigger(defaultPoolId, defaultPoolKey, ITriggerOracle.TriggerType.COMMITMENT_BREACH, 0);

        assertFalse(insurancePool.payoutCalled());
        assertTrue(escrowVault.triggerCalled());
    }

    function test_executeTrigger_emitsEvents() public {
        vm.expectEmit(true, true, false, true);
        emit ITriggerOracle.TriggerDetected(
            defaultPoolId, ITriggerOracle.TriggerType.RUG_PULL, ""
        );

        vm.prank(hook);
        oracle.executeTrigger(defaultPoolId, defaultPoolKey, ITriggerOracle.TriggerType.RUG_PULL, TOTAL_SUPPLY);
    }

    function test_executeTrigger_paused_reverts() public {
        vm.prank(guardian);
        oracle.pause();

        vm.prank(hook);
        vm.expectRevert(TriggerOracle.IsPaused.selector);
        oracle.executeTrigger(defaultPoolId, defaultPoolKey, ITriggerOracle.TriggerType.RUG_PULL, TOTAL_SUPPLY);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  COMMITMENT BREACH TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_reportCommitmentBreach_triggers() public {
        vm.prank(hook);
        oracle.reportCommitmentBreach(defaultPoolId);

        ITriggerOracle.TriggerResult memory result = oracle.checkTrigger(defaultPoolId);
        assertTrue(result.triggered);
        assertEq(uint8(result.triggerType), uint8(ITriggerOracle.TriggerType.COMMITMENT_BREACH));
    }

    function test_reportCommitmentBreach_revertsNotHook() public {
        vm.expectRevert(TriggerOracle.OnlyHook.selector);
        oracle.reportCommitmentBreach(defaultPoolId);
    }

    function test_reportCommitmentBreach_ignoredAfterTriggered() public {
        // Trigger pool via executeTrigger
        vm.prank(hook);
        oracle.executeTrigger(defaultPoolId, defaultPoolKey, ITriggerOracle.TriggerType.RUG_PULL, TOTAL_SUPPLY);

        // Subsequent commitment breach should be silently ignored
        vm.prank(hook);
        oracle.reportCommitmentBreach(defaultPoolId);

        // Trigger type unchanged (RUG_PULL, not COMMITMENT_BREACH)
        ITriggerOracle.TriggerResult memory result = oracle.checkTrigger(defaultPoolId);
        assertEq(uint8(result.triggerType), uint8(ITriggerOracle.TriggerType.RUG_PULL));
    }

    function test_reportCommitmentBreach_revertsConfigNotSet() public {
        PoolId unconfigured = PoolId.wrap(bytes32(uint256(99)));

        vm.prank(hook);
        vm.expectRevert(TriggerOracle.ConfigNotSet.selector);
        oracle.reportCommitmentBreach(unconfigured);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  TRIGGER EXECUTION & PROPAGATION TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_trigger_propagatesToEscrowVault() public {
        vm.prank(hook);
        oracle.reportCommitmentBreach(defaultPoolId);

        assertTrue(escrowVault.triggerCalled());
        assertEq(escrowVault.lastTriggerType(), uint8(ITriggerOracle.TriggerType.COMMITMENT_BREACH));
    }

    function test_trigger_emitsEvents() public {
        vm.expectEmit(true, true, false, true);
        emit ITriggerOracle.TriggerDetected(
            defaultPoolId, ITriggerOracle.TriggerType.COMMITMENT_BREACH, ""
        );

        vm.prank(hook);
        oracle.reportCommitmentBreach(defaultPoolId);
    }

    function test_trigger_zeroTotalEligibleSupply_skipsInsurancePayout() public {
        // Commitment breach sets totalEligibleSupply=0, so insurance pool should NOT be called
        vm.prank(hook);
        oracle.reportCommitmentBreach(defaultPoolId);

        assertFalse(insurancePool.payoutCalled());
        assertTrue(escrowVault.triggerCalled());
    }

    // ═══════════════════════════════════════════════════════════════════
    //  PAUSE / UNPAUSE TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_pause_blocksReports() public {
        vm.prank(guardian);
        oracle.pause();

        vm.prank(hook);
        vm.expectRevert(TriggerOracle.IsPaused.selector);
        oracle.reportCommitmentBreach(defaultPoolId);
    }

    function test_unpause_resumesOperation() public {
        vm.prank(guardian);
        oracle.pause();
        assertTrue(oracle.paused());

        vm.prank(guardian);
        oracle.unpause();
        assertFalse(oracle.paused());

        // Should trigger immediately after unpausing
        vm.prank(hook);
        oracle.reportCommitmentBreach(defaultPoolId);

        assertTrue(oracle.checkTrigger(defaultPoolId).triggered);
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
        assertEq(cfg.dailyLpRemovalBps, 1000);
        assertEq(cfg.weeklyLpRemovalBps, 3000);
        assertEq(cfg.dumpThresholdPercent, 300);
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
        oracle.registerIssuer(defaultPoolId, address(0), TOTAL_SUPPLY, address(0xBEEF));
    }

    function test_registerIssuer_revertsNotHook() public {
        vm.expectRevert(TriggerOracle.OnlyHook.selector);
        oracle.registerIssuer(defaultPoolId, issuer, TOTAL_SUPPLY, address(0xBEEF));
    }

    function test_isConfigSet() public view {
        assertTrue(oracle.isConfigSet(defaultPoolId));

        PoolId unconfigured = PoolId.wrap(bytes32(uint256(99)));
        assertFalse(oracle.isConfigSet(unconfigured));
    }

    // ═══════════════════════════════════════════════════════════════════
    //  CHECK TRIGGER VIEW
    // ═══════════════════════════════════════════════════════════════════

    function test_checkTrigger_initiallyFalse() public view {
        ITriggerOracle.TriggerResult memory result = oracle.checkTrigger(defaultPoolId);
        assertFalse(result.triggered);
        assertEq(uint8(result.triggerType), uint8(ITriggerOracle.TriggerType.NONE));
    }

    function test_checkTrigger_trueAfterImmediate() public {
        vm.prank(hook);
        oracle.reportCommitmentBreach(defaultPoolId);

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
        oracle.registerIssuer(poolId2, makeAddr("issuer2"), TOTAL_SUPPLY, address(0xBEEF));

        // Trigger pool 1 immediately
        vm.prank(hook);
        oracle.reportCommitmentBreach(defaultPoolId);
        assertTrue(oracle.checkTrigger(defaultPoolId).triggered);

        // Pool 2 unaffected
        assertFalse(oracle.checkTrigger(poolId2).triggered);

        // Pool 2 can still be triggered via executeTrigger
        vm.prank(hook);
        oracle.executeTrigger(poolId2, defaultPoolKey, ITriggerOracle.TriggerType.RUG_PULL, TOTAL_SUPPLY);

        assertTrue(oracle.checkTrigger(poolId2).triggered);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  EXTERNAL CALL FAILURE (catch branches in _executeImmediate)
    // ═══════════════════════════════════════════════════════════════════

    function test_trigger_escrowVaultReverts_revertsEntireTrigger() public {
        // Deploy oracle with reverting escrow vault
        // H-03 fix: EscrowVault failure must revert the entire trigger to prevent state inconsistency
        RevertingEscrowVault revertingEscrow = new RevertingEscrowVault();
        MockReputationEngine repEngine = new MockReputationEngine();
        TriggerOracle oracleWithBadEscrow = new TriggerOracle(
            hook, address(revertingEscrow), address(insurancePool), guardian, address(repEngine), governance
        );

        vm.prank(hook);
        oracleWithBadEscrow.setTriggerConfig(defaultPoolId, _defaultConfig());
        vm.prank(hook);
        oracleWithBadEscrow.registerIssuer(defaultPoolId, issuer, TOTAL_SUPPLY, address(0xBEEF));

        // Entire trigger must revert when EscrowVault fails (no silent continue)
        vm.prank(hook);
        vm.expectRevert();
        oracleWithBadEscrow.reportCommitmentBreach(defaultPoolId);

        // Pool should NOT be marked as triggered (entire tx rolled back)
        assertFalse(oracleWithBadEscrow.checkTrigger(defaultPoolId).triggered);
    }

    function test_trigger_insurancePoolReverts_emitsEvent() public {
        RevertingInsurancePool revertingInsurance = new RevertingInsurancePool();
        MockReputationEngine repEngine = new MockReputationEngine();
        TriggerOracle oracleWithBadInsurance = new TriggerOracle(
            hook, address(escrowVault), address(revertingInsurance), guardian, address(repEngine), governance
        );

        vm.prank(hook);
        oracleWithBadInsurance.setTriggerConfig(defaultPoolId, _defaultConfig());
        vm.prank(hook);
        oracleWithBadInsurance.registerIssuer(defaultPoolId, issuer, TOTAL_SUPPLY, address(0xBEEF));

        // Use executeTrigger with totalEligibleSupply > 0 (triggers insurance pool call)
        vm.expectEmit(false, true, false, true);
        emit TriggerOracle.ExternalCallFailed("InsurancePool.executePayout", defaultPoolId);

        vm.prank(hook);
        oracleWithBadInsurance.executeTrigger(defaultPoolId, defaultPoolKey, ITriggerOracle.TriggerType.ISSUER_DUMP, TOTAL_SUPPLY);

        assertTrue(oracleWithBadInsurance.checkTrigger(defaultPoolId).triggered);
    }

    function test_trigger_reputationEngineReverts_emitsEvent() public {
        RevertingReputationEngine revertingRep = new RevertingReputationEngine();
        TriggerOracle oracleWithBadRep = new TriggerOracle(
            hook, address(escrowVault), address(insurancePool), guardian, address(revertingRep), governance
        );

        vm.prank(hook);
        oracleWithBadRep.setTriggerConfig(defaultPoolId, _defaultConfig());
        vm.prank(hook);
        oracleWithBadRep.registerIssuer(defaultPoolId, issuer, TOTAL_SUPPLY, address(0xBEEF));

        vm.expectEmit(false, true, false, true);
        emit TriggerOracle.ExternalCallFailed("ReputationEngine.recordEvent", defaultPoolId);

        vm.prank(hook);
        oracleWithBadRep.reportCommitmentBreach(defaultPoolId);

        assertTrue(oracleWithBadRep.checkTrigger(defaultPoolId).triggered);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  RISK-1: PAUSE AUTO-EXPIRY TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_pause_auto_expires_after_7_days() public {
        vm.prank(guardian);
        oracle.pause();
        assertTrue(oracle.paused());

        // Still paused after 6 days
        vm.warp(block.timestamp + 6 days);
        assertTrue(oracle.paused());

        // Auto-expires after 7 days
        vm.warp(block.timestamp + 1 days + 1);
        assertFalse(oracle.paused());

        // Operations should work again without explicit unpause
        vm.prank(hook);
        oracle.reportCommitmentBreach(defaultPoolId);
        assertTrue(oracle.checkTrigger(defaultPoolId).triggered);
    }

    function test_pause_blocks_operations_within_duration() public {
        vm.prank(guardian);
        oracle.pause();

        // executeTrigger blocked while paused
        vm.prank(hook);
        vm.expectRevert(TriggerOracle.IsPaused.selector);
        oracle.executeTrigger(defaultPoolId, defaultPoolKey, ITriggerOracle.TriggerType.RUG_PULL, TOTAL_SUPPLY);

        // reportCommitmentBreach blocked while paused
        vm.prank(hook);
        vm.expectRevert(TriggerOracle.IsPaused.selector);
        oracle.reportCommitmentBreach(defaultPoolId);
    }

    function test_unpause_clears_pausedUntil() public {
        vm.prank(guardian);
        oracle.pause();
        assertGt(oracle.pausedUntil(), 0);

        vm.prank(guardian);
        oracle.unpause();
        assertEq(oracle.pausedUntil(), 0);
        assertFalse(oracle.paused());
    }

    // ═══════════════════════════════════════════════════════════════════
    //  RISK-5: TOTAL SUPPLY SNAPSHOT TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_initial_supply_snapshot_stored() public view {
        uint256 initialSupply = oracle.getInitialTotalSupply(defaultPoolId);
        assertEq(initialSupply, TOTAL_SUPPLY);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  GOVERNANCE PARAMETER TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_setMaxPauseDuration_updatesValue() public {
        vm.prank(governance);
        oracle.setMaxPauseDuration(14 days);
        assertEq(oracle.maxPauseDuration(), 14 days);
    }

    function test_setMaxPauseDuration_revertsOutOfRange() public {
        vm.prank(governance);
        vm.expectRevert(TriggerOracle.InvalidDuration.selector);
        oracle.setMaxPauseDuration(0);

        vm.prank(governance);
        vm.expectRevert(TriggerOracle.InvalidDuration.selector);
        oracle.setMaxPauseDuration(15 days);
    }

    function test_setMaxPauseDuration_revertsNotGovernance() public {
        vm.expectRevert(TriggerOracle.OnlyGovernance.selector);
        oracle.setMaxPauseDuration(7 days);
    }

    function test_setGuardian_updatesGuardian() public {
        address newGuardian = makeAddr("newGuardian");
        vm.prank(governance);
        oracle.setGuardian(newGuardian);
        assertEq(oracle.guardian(), newGuardian);
    }

    function test_setGuardian_revertsZeroAddress() public {
        vm.prank(governance);
        vm.expectRevert(TriggerOracle.ZeroAddress.selector);
        oracle.setGuardian(address(0));
    }

    function test_setGuardian_revertsNotGovernance() public {
        vm.expectRevert(TriggerOracle.OnlyGovernance.selector);
        oracle.setGuardian(makeAddr("newGuardian"));
    }

    function test_setDefaultTriggerConfig_updatesConfig() public {
        ITriggerOracle.TriggerConfig memory newCfg = _defaultConfig();
        newCfg.dailyLpRemovalBps = 1500;

        vm.prank(governance);
        oracle.setDefaultTriggerConfig(newCfg);

        ITriggerOracle.TriggerConfig memory stored = oracle.getDefaultTriggerConfig();
        assertEq(stored.dailyLpRemovalBps, 1500);
    }

    function test_setDefaultTriggerConfig_revertsNotGovernance() public {
        vm.expectRevert(TriggerOracle.OnlyGovernance.selector);
        oracle.setDefaultTriggerConfig(_defaultConfig());
    }

    function test_updatePoolTriggerConfig_updatesConfig() public {
        // Use an unregistered pool (M-01 fix: registered pools cannot be updated)
        PoolId unregisteredPool = PoolId.wrap(bytes32(uint256(999)));
        ITriggerOracle.TriggerConfig memory newCfg = _defaultConfig();
        newCfg.dumpThresholdPercent = 2000;

        vm.prank(governance);
        oracle.updatePoolTriggerConfig(unregisteredPool, newCfg);

        ITriggerOracle.TriggerConfig memory stored = oracle.getTriggerConfig(unregisteredPool);
        assertEq(stored.dumpThresholdPercent, 2000);
    }

    function test_updatePoolTriggerConfig_revertsRegisteredPool() public {
        // M-01 fix: registered pools cannot have config updated by governance
        vm.prank(governance);
        vm.expectRevert(TriggerOracle.PoolAlreadyRegistered.selector);
        oracle.updatePoolTriggerConfig(defaultPoolId, _defaultConfig());
    }

    function test_updatePoolTriggerConfig_revertsNotGovernance() public {
        vm.expectRevert(TriggerOracle.OnlyGovernance.selector);
        oracle.updatePoolTriggerConfig(defaultPoolId, _defaultConfig());
    }

    function test_transferGovernance_updatesGovernance() public {
        address newGov = makeAddr("newGov");
        vm.prank(governance);
        oracle.transferGovernance(newGov);
        assertEq(oracle.GOVERNANCE(), newGov);
    }

    function test_transferGovernance_revertsZeroAddress() public {
        vm.prank(governance);
        vm.expectRevert(TriggerOracle.ZeroAddress.selector);
        oracle.transferGovernance(address(0));
    }

    function test_transferGovernance_revertsNotGovernance() public {
        vm.expectRevert(TriggerOracle.OnlyGovernance.selector);
        oracle.transferGovernance(makeAddr("anyone"));
    }
}
