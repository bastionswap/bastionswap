// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.26;

import "forge-std/Test.sol";
import {InsurancePool} from "../../src/core/InsurancePool.sol";
import {TriggerOracle} from "../../src/core/TriggerOracle.sol";
import {ITriggerOracle} from "../../src/interfaces/ITriggerOracle.sol";
import {IInsurancePool} from "../../src/interfaces/IInsurancePool.sol";
import {IEscrowVault} from "../../src/interfaces/IEscrowVault.sol";
import {IReputationEngine} from "../../src/interfaces/IReputationEngine.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

contract GovernanceParamsTest is Test {
    InsurancePool pool;
    TriggerOracle oracle;

    address governance = makeAddr("governance");
    address hook = makeAddr("hook");
    address triggerOracleAddr = makeAddr("triggerOracle");
    address escrowVault = makeAddr("escrowVault");
    address guardian = makeAddr("guardian");
    address reputationEngine;
    address treasury = makeAddr("treasury");
    address nonGovernance = makeAddr("nonGovernance");

    function setUp() public {
        // Deploy mock reputation engine
        reputationEngine = address(new MockRepEngine());

        pool = new InsurancePool(hook, triggerOracleAddr, governance, escrowVault, treasury);
        oracle = new TriggerOracle(hook, escrowVault, address(pool), guardian, reputationEngine, governance);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  INSURANCE POOL — transferGovernance
    // ═══════════════════════════════════════════════════════════════════

    function test_pool_transferGovernance_success() public {
        address newGov = makeAddr("newGov");
        vm.prank(governance);
        vm.expectEmit(true, true, false, false);
        emit IInsurancePool.GovernanceTransferred(governance, newGov);
        pool.transferGovernance(newGov);
        assertEq(pool.GOVERNANCE(), newGov);
    }

    function test_pool_transferGovernance_revertsNotGovernance() public {
        vm.prank(nonGovernance);
        vm.expectRevert(InsurancePool.OnlyGovernance.selector);
        pool.transferGovernance(makeAddr("x"));
    }

    function test_pool_transferGovernance_revertsZeroAddress() public {
        vm.prank(governance);
        vm.expectRevert(InsurancePool.ZeroAddress.selector);
        pool.transferGovernance(address(0));
    }

    // ═══════════════════════════════════════════════════════════════════
    //  INSURANCE POOL — merkleClaimPeriod
    // ═══════════════════════════════════════════════════════════════════

    function test_pool_merkleClaimPeriod_default() public view {
        assertEq(pool.merkleClaimPeriod(), 30 days);
    }

    function test_pool_setMerkleClaimPeriod_success() public {
        vm.prank(governance);
        vm.expectEmit(false, false, false, true);
        emit IInsurancePool.MerkleClaimPeriodUpdated(60 days);
        pool.setMerkleClaimPeriod(60 days);
        assertEq(pool.merkleClaimPeriod(), 60 days);
    }

    function test_pool_setMerkleClaimPeriod_revertsTooLow() public {
        vm.prank(governance);
        vm.expectRevert(InsurancePool.InvalidDuration.selector);
        pool.setMerkleClaimPeriod(13 days);
    }

    function test_pool_setMerkleClaimPeriod_revertsTooHigh() public {
        vm.prank(governance);
        vm.expectRevert(InsurancePool.InvalidDuration.selector);
        pool.setMerkleClaimPeriod(91 days);
    }

    function test_pool_setMerkleClaimPeriod_revertsNotGovernance() public {
        vm.prank(nonGovernance);
        vm.expectRevert(InsurancePool.OnlyGovernance.selector);
        pool.setMerkleClaimPeriod(60 days);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  INSURANCE POOL — fallbackClaimPeriod
    // ═══════════════════════════════════════════════════════════════════

    function test_pool_fallbackClaimPeriod_default() public view {
        assertEq(pool.fallbackClaimPeriod(), 7 days);
    }

    function test_pool_setFallbackClaimPeriod_success() public {
        vm.prank(governance);
        vm.expectEmit(false, false, false, true);
        emit IInsurancePool.FallbackClaimPeriodUpdated(14 days);
        pool.setFallbackClaimPeriod(14 days);
        assertEq(pool.fallbackClaimPeriod(), 14 days);
    }

    function test_pool_setFallbackClaimPeriod_revertsTooLow() public {
        vm.prank(governance);
        vm.expectRevert(InsurancePool.InvalidDuration.selector);
        pool.setFallbackClaimPeriod(2 days);
    }

    function test_pool_setFallbackClaimPeriod_revertsTooHigh() public {
        vm.prank(governance);
        vm.expectRevert(InsurancePool.InvalidDuration.selector);
        pool.setFallbackClaimPeriod(31 days);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  INSURANCE POOL — emergencyTimelock
    // ═══════════════════════════════════════════════════════════════════

    function test_pool_emergencyTimelock_default() public view {
        assertEq(pool.emergencyTimelock(), 2 days);
    }

    function test_pool_setEmergencyTimelock_success() public {
        vm.prank(governance);
        vm.expectEmit(false, false, false, true);
        emit IInsurancePool.EmergencyTimelockUpdated(5 days);
        pool.setEmergencyTimelock(5 days);
        assertEq(pool.emergencyTimelock(), 5 days);
    }

    function test_pool_setEmergencyTimelock_revertsTooLow() public {
        vm.prank(governance);
        vm.expectRevert(InsurancePool.InvalidDuration.selector);
        pool.setEmergencyTimelock(23 hours);
    }

    function test_pool_setEmergencyTimelock_revertsTooHigh() public {
        vm.prank(governance);
        vm.expectRevert(InsurancePool.InvalidDuration.selector);
        pool.setEmergencyTimelock(8 days);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  INSURANCE POOL — issuerRewardBps
    // ═══════════════════════════════════════════════════════════════════

    function test_pool_issuerRewardBps_default() public view {
        assertEq(pool.issuerRewardBps(), 1000);
    }

    function test_pool_setIssuerRewardBps_success() public {
        vm.prank(governance);
        vm.expectEmit(false, false, false, true);
        emit IInsurancePool.IssuerRewardBpsUpdated(2000);
        pool.setIssuerRewardBps(2000);
        assertEq(pool.issuerRewardBps(), 2000);
    }

    function test_pool_setIssuerRewardBps_allowsZero() public {
        vm.prank(governance);
        pool.setIssuerRewardBps(0);
        assertEq(pool.issuerRewardBps(), 0);
    }

    function test_pool_setIssuerRewardBps_revertsTooHigh() public {
        vm.prank(governance);
        vm.expectRevert(InsurancePool.FeeRateTooHigh.selector);
        pool.setIssuerRewardBps(3001);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  TRIGGER ORACLE — transferGovernance
    // ═══════════════════════════════════════════════════════════════════

    function test_oracle_transferGovernance_success() public {
        address newGov = makeAddr("newGov");
        vm.prank(governance);
        vm.expectEmit(true, true, false, false);
        emit ITriggerOracle.GovernanceTransferred(governance, newGov);
        oracle.transferGovernance(newGov);
        assertEq(oracle.GOVERNANCE(), newGov);
    }

    function test_oracle_transferGovernance_revertsNotGovernance() public {
        vm.prank(nonGovernance);
        vm.expectRevert(TriggerOracle.OnlyGovernance.selector);
        oracle.transferGovernance(makeAddr("x"));
    }

    // ═══════════════════════════════════════════════════════════════════
    //  TRIGGER ORACLE — gracePeriod
    // ═══════════════════════════════════════════════════════════════════

    function test_oracle_gracePeriod_default() public view {
        assertEq(oracle.gracePeriod(), 1 hours);
    }

    function test_oracle_setGracePeriod_success() public {
        vm.prank(governance);
        vm.expectEmit(false, false, false, true);
        emit ITriggerOracle.GracePeriodUpdated(2 hours);
        oracle.setGracePeriod(2 hours);
        assertEq(oracle.gracePeriod(), 2 hours);
    }

    function test_oracle_setGracePeriod_revertsTooLow() public {
        vm.prank(governance);
        vm.expectRevert(TriggerOracle.InvalidDuration.selector);
        oracle.setGracePeriod(14 minutes);
    }

    function test_oracle_setGracePeriod_revertsTooHigh() public {
        vm.prank(governance);
        vm.expectRevert(TriggerOracle.InvalidDuration.selector);
        oracle.setGracePeriod(25 hours);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  TRIGGER ORACLE — maxPauseDuration
    // ═══════════════════════════════════════════════════════════════════

    function test_oracle_maxPauseDuration_default() public view {
        assertEq(oracle.maxPauseDuration(), 7 days);
    }

    function test_oracle_setMaxPauseDuration_success() public {
        vm.prank(governance);
        vm.expectEmit(false, false, false, true);
        emit ITriggerOracle.MaxPauseDurationUpdated(10 days);
        oracle.setMaxPauseDuration(10 days);
        assertEq(oracle.maxPauseDuration(), 10 days);
    }

    function test_oracle_setMaxPauseDuration_revertsTooLow() public {
        vm.prank(governance);
        vm.expectRevert(TriggerOracle.InvalidDuration.selector);
        oracle.setMaxPauseDuration(23 hours);
    }

    function test_oracle_setMaxPauseDuration_revertsTooHigh() public {
        vm.prank(governance);
        vm.expectRevert(TriggerOracle.InvalidDuration.selector);
        oracle.setMaxPauseDuration(15 days);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  TRIGGER ORACLE — stableLpMinAge
    // ═══════════════════════════════════════════════════════════════════

    function test_oracle_stableLpMinAge_default() public view {
        assertEq(oracle.stableLpMinAge(), 1 hours);
    }

    function test_oracle_setStableLpMinAge_success() public {
        vm.prank(governance);
        vm.expectEmit(false, false, false, true);
        emit ITriggerOracle.StableLpMinAgeUpdated(3 hours);
        oracle.setStableLpMinAge(3 hours);
        assertEq(oracle.stableLpMinAge(), 3 hours);
    }

    function test_oracle_setStableLpMinAge_revertsTooLow() public {
        vm.prank(governance);
        vm.expectRevert(TriggerOracle.InvalidDuration.selector);
        oracle.setStableLpMinAge(29 minutes);
    }

    function test_oracle_setStableLpMinAge_revertsTooHigh() public {
        vm.prank(governance);
        vm.expectRevert(TriggerOracle.InvalidDuration.selector);
        oracle.setStableLpMinAge(7 hours);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  TRIGGER ORACLE — guardianSubmissionDeadline
    // ═══════════════════════════════════════════════════════════════════

    function test_oracle_guardianSubmissionDeadline_default() public view {
        assertEq(oracle.guardianSubmissionDeadline(), 24 hours);
    }

    function test_oracle_setGuardianSubmissionDeadline_success() public {
        vm.prank(governance);
        vm.expectEmit(false, false, false, true);
        emit ITriggerOracle.GuardianSubmissionDeadlineUpdated(48 hours);
        oracle.setGuardianSubmissionDeadline(48 hours);
        assertEq(oracle.guardianSubmissionDeadline(), 48 hours);
    }

    function test_oracle_setGuardianSubmissionDeadline_revertsTooLow() public {
        vm.prank(governance);
        vm.expectRevert(TriggerOracle.InvalidDuration.selector);
        oracle.setGuardianSubmissionDeadline(5 hours);
    }

    function test_oracle_setGuardianSubmissionDeadline_revertsTooHigh() public {
        vm.prank(governance);
        vm.expectRevert(TriggerOracle.InvalidDuration.selector);
        oracle.setGuardianSubmissionDeadline(73 hours);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  TRIGGER ORACLE — guardian
    // ═══════════════════════════════════════════════════════════════════

    function test_oracle_setGuardian_success() public {
        address newGuardian = makeAddr("newGuardian");
        vm.prank(governance);
        vm.expectEmit(true, false, false, false);
        emit ITriggerOracle.GuardianUpdated(newGuardian);
        oracle.setGuardian(newGuardian);
        assertEq(oracle.guardian(), newGuardian);
    }

    function test_oracle_setGuardian_revertsZeroAddress() public {
        vm.prank(governance);
        vm.expectRevert(TriggerOracle.ZeroAddress.selector);
        oracle.setGuardian(address(0));
    }

    function test_oracle_setGuardian_revertsNotGovernance() public {
        vm.prank(nonGovernance);
        vm.expectRevert(TriggerOracle.OnlyGovernance.selector);
        oracle.setGuardian(makeAddr("x"));
    }

    // ═══════════════════════════════════════════════════════════════════
    //  TRIGGER ORACLE — defaultTriggerConfig
    // ═══════════════════════════════════════════════════════════════════

    function test_oracle_defaultTriggerConfig_initialized() public view {
        (
            uint16 lpRemoval,
            uint16 dumpThreshold,
            uint40 dumpWindow,
            uint16 taxDeviation,
            uint40 slowRugWindow,
            uint16 slowRugThreshold
        ) = oracle.defaultTriggerConfig();
        assertEq(lpRemoval, 5000);
        assertEq(dumpThreshold, 3000);
        assertEq(dumpWindow, 86400);
        assertEq(taxDeviation, 500);
        assertEq(slowRugWindow, 86400);
        assertEq(slowRugThreshold, 8000);
    }

    function test_oracle_setDefaultTriggerConfig_success() public {
        ITriggerOracle.TriggerConfig memory config = ITriggerOracle.TriggerConfig({
            lpRemovalThreshold: 4000,
            dumpThresholdPercent: 2000,
            dumpWindowSeconds: 43200,
            taxDeviationThreshold: 300,
            slowRugWindowSeconds: 172800,
            slowRugCumulativeThreshold: 7000
        });
        vm.prank(governance);
        oracle.setDefaultTriggerConfig(config);

        (uint16 lpRemoval,,,,, ) = oracle.defaultTriggerConfig();
        assertEq(lpRemoval, 4000);
    }

    function test_oracle_setDefaultTriggerConfig_revertsNotGovernance() public {
        ITriggerOracle.TriggerConfig memory config = ITriggerOracle.TriggerConfig({
            lpRemovalThreshold: 4000,
            dumpThresholdPercent: 2000,
            dumpWindowSeconds: 43200,
            taxDeviationThreshold: 300,
            slowRugWindowSeconds: 172800,
            slowRugCumulativeThreshold: 7000
        });
        vm.prank(nonGovernance);
        vm.expectRevert(TriggerOracle.OnlyGovernance.selector);
        oracle.setDefaultTriggerConfig(config);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  TRIGGER ORACLE — updatePoolTriggerConfig
    // ═══════════════════════════════════════════════════════════════════

    function test_oracle_updatePoolTriggerConfig_success() public {
        PoolId poolId = PoolId.wrap(bytes32(uint256(1)));

        ITriggerOracle.TriggerConfig memory config = ITriggerOracle.TriggerConfig({
            lpRemovalThreshold: 6000,
            dumpThresholdPercent: 4000,
            dumpWindowSeconds: 86400,
            taxDeviationThreshold: 500,
            slowRugWindowSeconds: 86400,
            slowRugCumulativeThreshold: 9000
        });
        vm.prank(governance);
        oracle.updatePoolTriggerConfig(poolId, config);

        ITriggerOracle.TriggerConfig memory stored = oracle.getTriggerConfig(poolId);
        assertEq(stored.lpRemovalThreshold, 6000);
        assertTrue(oracle.isConfigSet(poolId));
    }

    function test_oracle_updatePoolTriggerConfig_revertsNotGovernance() public {
        PoolId poolId = PoolId.wrap(bytes32(uint256(1)));
        ITriggerOracle.TriggerConfig memory config = ITriggerOracle.TriggerConfig({
            lpRemovalThreshold: 6000,
            dumpThresholdPercent: 4000,
            dumpWindowSeconds: 86400,
            taxDeviationThreshold: 500,
            slowRugWindowSeconds: 86400,
            slowRugCumulativeThreshold: 9000
        });
        vm.prank(nonGovernance);
        vm.expectRevert(TriggerOracle.OnlyGovernance.selector);
        oracle.updatePoolTriggerConfig(poolId, config);
    }
}

// Minimal mock for IReputationEngine
contract MockRepEngine is IReputationEngine {
    function recordEvent(address, EventType, bytes calldata) external {}
    function getScore(address) external pure returns (uint256) { return 100; }
    function encodeScoreData(address) external pure returns (bytes memory) { return ""; }
    function decodeScoreData(bytes calldata) external pure returns (uint256, uint16, uint16, uint16) { return (0, 0, 0, 0); }
}
