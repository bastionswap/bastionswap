// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {EscrowVault} from "../../src/core/EscrowVault.sol";
import {IEscrowVault} from "../../src/interfaces/IEscrowVault.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

// ─── Mock ReputationEngine ───────────────────────────────────────────────────

contract MockReputationEngine {
    function recordEvent(address, uint8, bytes calldata) external {}
    function getScore(address) external pure returns (uint256) { return 500; }
}

// ─── Test Contract ────────────────────────────────────────────────────────────

contract EscrowVaultTest is Test {
    EscrowVault public vault;

    address public hook;
    address public oracle;
    address public issuer;

    PoolId public defaultPoolId;
    uint256 public defaultEscrowId;

    uint128 constant ESCROW_LIQUIDITY = 100e18;

    function setUp() public {
        hook = makeAddr("hook");
        oracle = makeAddr("oracle");
        issuer = makeAddr("issuer");

        MockReputationEngine mockReputation = new MockReputationEngine();
        vault = new EscrowVault(hook, oracle, address(mockReputation));

        defaultPoolId = PoolId.wrap(bytes32(uint256(1)));
        defaultEscrowId = _computeEscrowId(defaultPoolId, issuer);
    }

    // ─── Helpers ──────────────────────────────────────────────────────

    function _computeEscrowId(PoolId poolId, address _issuer) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(poolId, _issuer)));
    }

    function _defaultSchedule() internal pure returns (IEscrowVault.VestingStep[] memory) {
        IEscrowVault.VestingStep[] memory schedule = new IEscrowVault.VestingStep[](3);
        schedule[0] = IEscrowVault.VestingStep({timeOffset: 7 days, basisPoints: 1000}); // 10%
        schedule[1] = IEscrowVault.VestingStep({timeOffset: 30 days, basisPoints: 3000}); // 30%
        schedule[2] = IEscrowVault.VestingStep({timeOffset: 90 days, basisPoints: 10000}); // 100%
        return schedule;
    }

    function _defaultCommitment() internal pure returns (IEscrowVault.IssuerCommitment memory) {
        return IEscrowVault.IssuerCommitment({
            dailyWithdrawLimit: 500, // 5%
            lockDuration: 0,
            maxSellPercent: 200 // 2%
        });
    }

    function _createDefaultEscrow() internal returns (uint256) {
        vm.prank(hook);
        return vault.createEscrow(
            defaultPoolId, issuer, ESCROW_LIQUIDITY, _defaultSchedule(), _defaultCommitment()
        );
    }

    // ═══════════════════════════════════════════════════════════════════
    //  CREATION TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_createEscrow_happyPath() public {
        uint256 escrowId = _createDefaultEscrow();

        assertEq(escrowId, defaultEscrowId);

        IEscrowVault.EscrowStatus memory status = vault.getEscrowStatus(escrowId);
        assertEq(status.totalLiquidity, ESCROW_LIQUIDITY);
        assertEq(status.removedLiquidity, 0);
        assertEq(status.remainingLiquidity, ESCROW_LIQUIDITY);
    }

    function test_createEscrow_emitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit IEscrowVault.EscrowCreated(defaultEscrowId, defaultPoolId, issuer, ESCROW_LIQUIDITY);
        _createDefaultEscrow();
    }

    function test_createEscrow_revertsNotHook() public {
        vm.expectRevert(EscrowVault.OnlyHook.selector);
        vault.createEscrow(
            defaultPoolId, issuer, ESCROW_LIQUIDITY, _defaultSchedule(), _defaultCommitment()
        );
    }

    function test_createEscrow_revertsZeroAmount() public {
        vm.prank(hook);
        vm.expectRevert(EscrowVault.ZeroAmount.selector);
        vault.createEscrow(defaultPoolId, issuer, 0, _defaultSchedule(), _defaultCommitment());
    }

    function test_createEscrow_revertsDuplicate() public {
        _createDefaultEscrow();

        vm.prank(hook);
        vm.expectRevert(EscrowVault.EscrowAlreadyExists.selector);
        vault.createEscrow(
            defaultPoolId, issuer, ESCROW_LIQUIDITY, _defaultSchedule(), _defaultCommitment()
        );
    }

    function test_createEscrow_revertsEmptySchedule() public {
        IEscrowVault.VestingStep[] memory empty = new IEscrowVault.VestingStep[](0);

        vm.prank(hook);
        vm.expectRevert(EscrowVault.EmptySchedule.selector);
        vault.createEscrow(defaultPoolId, issuer, ESCROW_LIQUIDITY, empty, _defaultCommitment());
    }

    function test_createEscrow_revertsScheduleTimesNotIncreasing() public {
        IEscrowVault.VestingStep[] memory schedule = new IEscrowVault.VestingStep[](2);
        schedule[0] = IEscrowVault.VestingStep({timeOffset: 30 days, basisPoints: 5000});
        schedule[1] = IEscrowVault.VestingStep({timeOffset: 7 days, basisPoints: 10000});

        vm.prank(hook);
        vm.expectRevert(EscrowVault.ScheduleTimesNotIncreasing.selector);
        vault.createEscrow(defaultPoolId, issuer, ESCROW_LIQUIDITY, schedule, _defaultCommitment());
    }

    function test_createEscrow_revertsScheduleBpsNotIncreasing() public {
        IEscrowVault.VestingStep[] memory schedule = new IEscrowVault.VestingStep[](2);
        schedule[0] = IEscrowVault.VestingStep({timeOffset: 7 days, basisPoints: 5000});
        schedule[1] = IEscrowVault.VestingStep({timeOffset: 30 days, basisPoints: 3000});

        vm.prank(hook);
        vm.expectRevert(EscrowVault.ScheduleBpsNotIncreasing.selector);
        vault.createEscrow(defaultPoolId, issuer, ESCROW_LIQUIDITY, schedule, _defaultCommitment());
    }

    function test_createEscrow_revertsScheduleBpsExceedsMax() public {
        IEscrowVault.VestingStep[] memory schedule = new IEscrowVault.VestingStep[](1);
        schedule[0] = IEscrowVault.VestingStep({timeOffset: 7 days, basisPoints: 10001});

        vm.prank(hook);
        vm.expectRevert(EscrowVault.ScheduleBpsExceedsMax.selector);
        vault.createEscrow(defaultPoolId, issuer, ESCROW_LIQUIDITY, schedule, _defaultCommitment());
    }

    function test_createEscrow_revertsScheduleFinalBpsNot10000() public {
        IEscrowVault.VestingStep[] memory schedule = new IEscrowVault.VestingStep[](1);
        schedule[0] = IEscrowVault.VestingStep({timeOffset: 7 days, basisPoints: 5000});

        vm.prank(hook);
        vm.expectRevert(EscrowVault.ScheduleFinalBpsNot10000.selector);
        vault.createEscrow(defaultPoolId, issuer, ESCROW_LIQUIDITY, schedule, _defaultCommitment());
    }

    function test_createEscrow_revertsScheduleTooLong() public {
        IEscrowVault.VestingStep[] memory schedule = new IEscrowVault.VestingStep[](11);
        for (uint256 i; i < 11; ++i) {
            schedule[i] = IEscrowVault.VestingStep({
                timeOffset: uint40((i + 1) * 1 days),
                basisPoints: uint16((i + 1) * 909)
            });
        }
        // Fix last to be 10000
        schedule[10].basisPoints = 10000;

        vm.prank(hook);
        vm.expectRevert(EscrowVault.ScheduleTooLong.selector);
        vault.createEscrow(defaultPoolId, issuer, ESCROW_LIQUIDITY, schedule, _defaultCommitment());
    }

    // ═══════════════════════════════════════════════════════════════════
    //  VESTING CALCULATION TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_calculateVestedLiquidity_beforeFirstStep() public {
        _createDefaultEscrow();

        // Before any vesting step
        vm.warp(block.timestamp + 3 days);
        assertEq(vault.calculateVestedLiquidity(defaultEscrowId), 0);
    }

    function test_calculateVestedLiquidity_atFirstStep() public {
        _createDefaultEscrow();

        vm.warp(block.timestamp + 7 days);
        // 10% of 100e18 = 10e18
        assertEq(vault.calculateVestedLiquidity(defaultEscrowId), 10e18);
    }

    function test_calculateVestedLiquidity_atSecondStep() public {
        _createDefaultEscrow();

        vm.warp(block.timestamp + 30 days);
        // 30% of 100e18 = 30e18
        assertEq(vault.calculateVestedLiquidity(defaultEscrowId), 30e18);
    }

    function test_calculateVestedLiquidity_atFinalStep() public {
        _createDefaultEscrow();

        vm.warp(block.timestamp + 90 days);
        assertEq(vault.calculateVestedLiquidity(defaultEscrowId), 100e18);
    }

    function test_calculateVestedLiquidity_betweenSteps() public {
        _createDefaultEscrow();

        // Between step 1 (7d) and step 2 (30d) - should still be 10%
        vm.warp(block.timestamp + 15 days);
        assertEq(vault.calculateVestedLiquidity(defaultEscrowId), 10e18);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  RECORD LP REMOVAL TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_recordLPRemoval_happyPath() public {
        // Use no daily limit for simpler test
        IEscrowVault.IssuerCommitment memory commitment = IEscrowVault.IssuerCommitment({
            dailyWithdrawLimit: 0,
            lockDuration: 0,
            maxSellPercent: 200
        });

        vm.prank(hook);
        uint256 escrowId = vault.createEscrow(
            defaultPoolId, issuer, ESCROW_LIQUIDITY, _defaultSchedule(), commitment
        );

        vm.warp(block.timestamp + 7 days);

        // 10e18 vested, remove 10e18
        vm.prank(hook);
        vault.recordLPRemoval(escrowId, 10e18);

        IEscrowVault.EscrowStatus memory status = vault.getEscrowStatus(escrowId);
        assertEq(status.removedLiquidity, 10e18);
        assertEq(status.remainingLiquidity, 90e18);
    }

    function test_recordLPRemoval_multiStepRemoval() public {
        IEscrowVault.IssuerCommitment memory commitment = IEscrowVault.IssuerCommitment({
            dailyWithdrawLimit: 0,
            lockDuration: 0,
            maxSellPercent: 200
        });

        vm.prank(hook);
        uint256 escrowId = vault.createEscrow(
            defaultPoolId, issuer, ESCROW_LIQUIDITY, _defaultSchedule(), commitment
        );

        // Remove at 7 days (10% vested = 10e18)
        vm.warp(block.timestamp + 7 days);
        vm.prank(hook);
        vault.recordLPRemoval(escrowId, 10e18);

        IEscrowVault.EscrowStatus memory status = vault.getEscrowStatus(escrowId);
        assertEq(status.removedLiquidity, 10e18);

        // Remove at 30 days (30% vested = 30e18, already removed 10e18, removable = 20e18)
        vm.warp(block.timestamp + 23 days);
        vm.prank(hook);
        vault.recordLPRemoval(escrowId, 20e18);

        status = vault.getEscrowStatus(escrowId);
        assertEq(status.removedLiquidity, 30e18);
    }

    function test_recordLPRemoval_revertsNothingToRelease() public {
        _createDefaultEscrow();

        // Before any vesting
        vm.prank(hook);
        vm.expectRevert(EscrowVault.NothingToRelease.selector);
        vault.recordLPRemoval(defaultEscrowId, 1);
    }

    function test_recordLPRemoval_revertsNotHook() public {
        _createDefaultEscrow();

        vm.warp(block.timestamp + 7 days);

        vm.expectRevert(EscrowVault.OnlyHook.selector);
        vault.recordLPRemoval(defaultEscrowId, 10e18);
    }

    function test_recordLPRemoval_revertsWhenTriggered() public {
        _createDefaultEscrow();

        vm.warp(block.timestamp + 7 days);

        // Trigger lockdown first
        vm.prank(oracle);
        vault.triggerLockdown(defaultEscrowId, 1);

        vm.prank(hook);
        vm.expectRevert(EscrowVault.EscrowTriggered.selector);
        vault.recordLPRemoval(defaultEscrowId, 10e18);
    }

    function test_recordLPRemoval_revertsNotFound() public {
        vm.prank(hook);
        vm.expectRevert(EscrowVault.EscrowNotFound.selector);
        vault.recordLPRemoval(999, 1);
    }

    function test_recordLPRemoval_emitsEvent() public {
        IEscrowVault.IssuerCommitment memory commitment = IEscrowVault.IssuerCommitment({
            dailyWithdrawLimit: 0,
            lockDuration: 0,
            maxSellPercent: 200
        });

        vm.prank(hook);
        uint256 escrowId = vault.createEscrow(
            defaultPoolId, issuer, ESCROW_LIQUIDITY, _defaultSchedule(), commitment
        );

        vm.warp(block.timestamp + 7 days);

        vm.expectEmit(true, false, false, true);
        emit IEscrowVault.LPRemovalRecorded(escrowId, 10e18);

        vm.prank(hook);
        vault.recordLPRemoval(escrowId, 10e18);
    }

    function test_recordLPRemoval_exceedsRemovable_reverts() public {
        IEscrowVault.IssuerCommitment memory commitment = IEscrowVault.IssuerCommitment({
            dailyWithdrawLimit: 0,
            lockDuration: 0,
            maxSellPercent: 200
        });

        vm.prank(hook);
        uint256 escrowId = vault.createEscrow(
            defaultPoolId, issuer, ESCROW_LIQUIDITY, _defaultSchedule(), commitment
        );

        vm.warp(block.timestamp + 7 days);
        // 10e18 vested, try to remove 11e18
        vm.prank(hook);
        vm.expectRevert(EscrowVault.NothingToRelease.selector);
        vault.recordLPRemoval(escrowId, 11e18);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  DAILY LIMIT TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_dailyLimit_withinLimit() public {
        _createDefaultEscrow();

        // dailyWithdrawLimit = 500 bps = 5% = 5e18 of 100e18
        vm.warp(block.timestamp + 7 days);

        // 10e18 vested, but daily limit is 5e18
        vm.prank(hook);
        vault.recordLPRemoval(defaultEscrowId, 5e18);

        IEscrowVault.EscrowStatus memory status = vault.getEscrowStatus(defaultEscrowId);
        assertEq(status.removedLiquidity, 5e18);
    }

    function test_dailyLimit_exceedsLimit() public {
        _createDefaultEscrow();

        vm.warp(block.timestamp + 7 days);

        // First removal: 5e18 (daily max)
        vm.prank(hook);
        vault.recordLPRemoval(defaultEscrowId, 5e18);

        // Second removal same day: should revert
        vm.prank(hook);
        vm.expectRevert(EscrowVault.DailyLimitExceeded.selector);
        vault.recordLPRemoval(defaultEscrowId, 1);
    }

    function test_dailyLimit_resetsNextDay() public {
        _createDefaultEscrow();

        vm.warp(block.timestamp + 7 days);

        // First day: remove 5e18
        vm.prank(hook);
        vault.recordLPRemoval(defaultEscrowId, 5e18);

        IEscrowVault.EscrowStatus memory status = vault.getEscrowStatus(defaultEscrowId);
        assertEq(status.removedLiquidity, 5e18);

        // Next day: can remove another 5e18
        vm.warp(block.timestamp + 1 days);
        vm.prank(hook);
        vault.recordLPRemoval(defaultEscrowId, 5e18);

        status = vault.getEscrowStatus(defaultEscrowId);
        assertEq(status.removedLiquidity, 10e18);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  TRIGGER LOCKDOWN TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_triggerLockdown_setsTriggered() public {
        _createDefaultEscrow();

        vm.prank(oracle);
        vault.triggerLockdown(defaultEscrowId, 1);

        // getRemovableLiquidity should return 0
        assertEq(vault.getRemovableLiquidity(defaultEscrowId), 0);
    }

    function test_triggerLockdown_emitsEvent() public {
        _createDefaultEscrow();

        vm.expectEmit(true, true, false, false);
        emit IEscrowVault.Lockdown(defaultEscrowId, 1);

        vm.prank(oracle);
        vault.triggerLockdown(defaultEscrowId, 1);
    }

    function test_triggerLockdown_revertsNotOracle() public {
        _createDefaultEscrow();

        vm.expectRevert(EscrowVault.OnlyTriggerOracle.selector);
        vault.triggerLockdown(defaultEscrowId, 1);
    }

    function test_triggerLockdown_revertsAlreadyTriggered() public {
        _createDefaultEscrow();

        vm.prank(oracle);
        vault.triggerLockdown(defaultEscrowId, 1);

        vm.prank(oracle);
        vm.expectRevert(EscrowVault.EscrowTriggered.selector);
        vault.triggerLockdown(defaultEscrowId, 2);
    }

    function test_triggerLockdown_revertsNotFound() public {
        vm.prank(oracle);
        vm.expectRevert(EscrowVault.EscrowNotFound.selector);
        vault.triggerLockdown(999, 1);
    }

    function test_triggerLockdown_blocksRemoval() public {
        IEscrowVault.IssuerCommitment memory commitment = IEscrowVault.IssuerCommitment({
            dailyWithdrawLimit: 0,
            lockDuration: 0,
            maxSellPercent: 200
        });

        vm.prank(hook);
        uint256 escrowId = vault.createEscrow(
            defaultPoolId, issuer, ESCROW_LIQUIDITY, _defaultSchedule(), commitment
        );

        vm.warp(block.timestamp + 7 days);

        // Trigger lockdown
        vm.prank(oracle);
        vault.triggerLockdown(escrowId, 1);

        // Attempt removal — should fail
        vm.prank(hook);
        vm.expectRevert(EscrowVault.EscrowTriggered.selector);
        vault.recordLPRemoval(escrowId, 10e18);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  GET REMOVABLE LIQUIDITY TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_getRemovableLiquidity_beforeVesting() public {
        _createDefaultEscrow();
        assertEq(vault.getRemovableLiquidity(defaultEscrowId), 0);
    }

    function test_getRemovableLiquidity_afterVesting() public {
        IEscrowVault.IssuerCommitment memory commitment = IEscrowVault.IssuerCommitment({
            dailyWithdrawLimit: 0,
            lockDuration: 0,
            maxSellPercent: 200
        });

        vm.prank(hook);
        uint256 escrowId = vault.createEscrow(
            defaultPoolId, issuer, ESCROW_LIQUIDITY, _defaultSchedule(), commitment
        );

        vm.warp(block.timestamp + 7 days);
        assertEq(vault.getRemovableLiquidity(escrowId), 10e18);
    }

    function test_getRemovableLiquidity_afterPartialRemoval() public {
        IEscrowVault.IssuerCommitment memory commitment = IEscrowVault.IssuerCommitment({
            dailyWithdrawLimit: 0,
            lockDuration: 0,
            maxSellPercent: 200
        });

        vm.prank(hook);
        uint256 escrowId = vault.createEscrow(
            defaultPoolId, issuer, ESCROW_LIQUIDITY, _defaultSchedule(), commitment
        );

        vm.warp(block.timestamp + 7 days);
        vm.prank(hook);
        vault.recordLPRemoval(escrowId, 5e18);

        assertEq(vault.getRemovableLiquidity(escrowId), 5e18);
    }

    function test_getRemovableLiquidity_zeroAfterTrigger() public {
        _createDefaultEscrow();

        vm.warp(block.timestamp + 90 days);

        vm.prank(oracle);
        vault.triggerLockdown(defaultEscrowId, 1);

        assertEq(vault.getRemovableLiquidity(defaultEscrowId), 0);
    }

    function test_getRemovableLiquidity_zeroForNonexistent() public view {
        assertEq(vault.getRemovableLiquidity(999), 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  VAULT HOLDS NO ASSETS TEST
    // ═══════════════════════════════════════════════════════════════════

    function test_vaultHoldsNoAssets() public {
        _createDefaultEscrow();

        // EscrowVault should have zero ETH balance
        assertEq(address(vault).balance, 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  COMMITMENT TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_setCommitment_stricter() public {
        _createDefaultEscrow();

        IEscrowVault.IssuerCommitment memory stricter = IEscrowVault.IssuerCommitment({
            dailyWithdrawLimit: 300, // 3% (was 5%)
            lockDuration: 0,
            maxSellPercent: 200
        });

        vm.prank(issuer);
        vault.setCommitment(defaultEscrowId, stricter);
    }

    function test_setCommitment_emitsEvent() public {
        _createDefaultEscrow();

        IEscrowVault.IssuerCommitment memory stricter = IEscrowVault.IssuerCommitment({
            dailyWithdrawLimit: 300,
            lockDuration: 0,
            maxSellPercent: 200
        });

        vm.expectEmit(true, false, false, true);
        emit IEscrowVault.CommitmentSet(defaultEscrowId, stricter);

        vm.prank(issuer);
        vault.setCommitment(defaultEscrowId, stricter);
    }

    function test_setCommitment_revertsNotIssuer() public {
        _createDefaultEscrow();

        IEscrowVault.IssuerCommitment memory stricter = IEscrowVault.IssuerCommitment({
            dailyWithdrawLimit: 300,
            lockDuration: 0,
            maxSellPercent: 200
        });

        vm.expectRevert(EscrowVault.OnlyIssuer.selector);
        vault.setCommitment(defaultEscrowId, stricter);
    }

    function test_setCommitment_revertsLooserDailyLimit() public {
        _createDefaultEscrow();

        IEscrowVault.IssuerCommitment memory looser = IEscrowVault.IssuerCommitment({
            dailyWithdrawLimit: 800, // 8% (was 5%) — looser
            lockDuration: 0,
            maxSellPercent: 200
        });

        vm.prank(issuer);
        vm.expectRevert(EscrowVault.CommitmentNotStricter.selector);
        vault.setCommitment(defaultEscrowId, looser);
    }

    function test_setCommitment_revertsLooserLockDuration() public {
        // Create with lockDuration > 0
        IEscrowVault.IssuerCommitment memory commitment = IEscrowVault.IssuerCommitment({
            dailyWithdrawLimit: 500,
            lockDuration: 7 days,
            maxSellPercent: 200
        });

        vm.prank(hook);
        uint256 escrowId =
            vault.createEscrow(defaultPoolId, issuer, ESCROW_LIQUIDITY, _defaultSchedule(), commitment);

        IEscrowVault.IssuerCommitment memory looser = IEscrowVault.IssuerCommitment({
            dailyWithdrawLimit: 500,
            lockDuration: 3 days, // shorter — looser
            maxSellPercent: 200
        });

        vm.prank(issuer);
        vm.expectRevert(EscrowVault.CommitmentNotStricter.selector);
        vault.setCommitment(escrowId, looser);
    }

    function test_setCommitment_revertsLooserMaxSellPercent() public {
        _createDefaultEscrow();

        IEscrowVault.IssuerCommitment memory looser = IEscrowVault.IssuerCommitment({
            dailyWithdrawLimit: 500,
            lockDuration: 0,
            maxSellPercent: 500 // 5% (was 2%) — looser
        });

        vm.prank(issuer);
        vm.expectRevert(EscrowVault.CommitmentNotStricter.selector);
        vault.setCommitment(defaultEscrowId, looser);
    }

    function test_setCommitment_revertsIdentical() public {
        _createDefaultEscrow();

        // Same values — no change, should revert
        IEscrowVault.IssuerCommitment memory same = _defaultCommitment();

        vm.prank(issuer);
        vm.expectRevert(EscrowVault.CommitmentNotStricter.selector);
        vault.setCommitment(defaultEscrowId, same);
    }

    function test_setCommitment_revertsWhenTriggered() public {
        _createDefaultEscrow();

        vm.prank(oracle);
        vault.triggerLockdown(defaultEscrowId, 1);

        IEscrowVault.IssuerCommitment memory stricter = IEscrowVault.IssuerCommitment({
            dailyWithdrawLimit: 300,
            lockDuration: 0,
            maxSellPercent: 200
        });

        vm.prank(issuer);
        vm.expectRevert(EscrowVault.EscrowTriggered.selector);
        vault.setCommitment(defaultEscrowId, stricter);
    }

    function test_setCommitment_lockDurationAffectsVesting() public {
        IEscrowVault.IssuerCommitment memory commitment = IEscrowVault.IssuerCommitment({
            dailyWithdrawLimit: 0,
            lockDuration: 0,
            maxSellPercent: 200
        });

        vm.prank(hook);
        uint256 escrowId =
            vault.createEscrow(defaultPoolId, issuer, ESCROW_LIQUIDITY, _defaultSchedule(), commitment);

        // Tighten lock to 3 days
        IEscrowVault.IssuerCommitment memory stricter = IEscrowVault.IssuerCommitment({
            dailyWithdrawLimit: 0,
            lockDuration: 3 days,
            maxSellPercent: 200
        });

        vm.prank(issuer);
        vault.setCommitment(escrowId, stricter);

        // At 7 days: effectiveElapsed = 7-3 = 4 days < 7 days first step
        vm.warp(block.timestamp + 7 days);
        assertEq(vault.calculateVestedLiquidity(escrowId), 0);

        // At 10 days: effectiveElapsed = 10-3 = 7 days >= 7 days first step => 10%
        vm.warp(block.timestamp + 3 days);
        assertEq(vault.calculateVestedLiquidity(escrowId), 10e18);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  STATUS TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_getEscrowStatus_initial() public {
        _createDefaultEscrow();

        IEscrowVault.EscrowStatus memory status = vault.getEscrowStatus(defaultEscrowId);
        assertEq(status.totalLiquidity, ESCROW_LIQUIDITY);
        assertEq(status.removedLiquidity, 0);
        assertEq(status.remainingLiquidity, ESCROW_LIQUIDITY);
        // Next unlock should be at createdAt + 7 days (first step)
        assertEq(status.nextUnlockTime, block.timestamp + 7 days);
    }

    function test_getEscrowStatus_afterPartialRemoval() public {
        IEscrowVault.IssuerCommitment memory commitment = IEscrowVault.IssuerCommitment({
            dailyWithdrawLimit: 0,
            lockDuration: 0,
            maxSellPercent: 200
        });

        vm.prank(hook);
        uint256 escrowId = vault.createEscrow(
            defaultPoolId, issuer, ESCROW_LIQUIDITY, _defaultSchedule(), commitment
        );

        vm.warp(block.timestamp + 7 days);
        vm.prank(hook);
        vault.recordLPRemoval(escrowId, 10e18);

        IEscrowVault.EscrowStatus memory status = vault.getEscrowStatus(escrowId);
        assertEq(status.totalLiquidity, ESCROW_LIQUIDITY);
        assertEq(status.removedLiquidity, 10e18);
        assertEq(status.remainingLiquidity, 90e18);
    }

    function test_getEscrowStatus_fullyVested() public {
        IEscrowVault.IssuerCommitment memory commitment = IEscrowVault.IssuerCommitment({
            dailyWithdrawLimit: 0,
            lockDuration: 0,
            maxSellPercent: 200
        });

        vm.prank(hook);
        uint256 escrowId = vault.createEscrow(
            defaultPoolId, issuer, ESCROW_LIQUIDITY, _defaultSchedule(), commitment
        );

        vm.warp(block.timestamp + 90 days);

        IEscrowVault.EscrowStatus memory status = vault.getEscrowStatus(escrowId);
        assertEq(status.nextUnlockTime, 0); // Fully vested
    }

    function test_getEscrowStatus_afterTrigger() public {
        _createDefaultEscrow();

        vm.prank(oracle);
        vault.triggerLockdown(defaultEscrowId, 1);

        IEscrowVault.EscrowStatus memory status = vault.getEscrowStatus(defaultEscrowId);
        assertEq(status.remainingLiquidity, 0);
        assertEq(status.nextUnlockTime, 0);
    }

    function test_getEscrowStatus_revertsNotFound() public {
        vm.expectRevert(EscrowVault.EscrowNotFound.selector);
        vault.getEscrowStatus(999);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  isFullyVested TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_isFullyVested_falseBeforeFullRemoval() public {
        _createDefaultEscrow();
        assertFalse(vault.isFullyVested(defaultPoolId));
    }

    function test_isFullyVested_trueAfterFullRemoval() public {
        // Use no daily limit so we can remove everything at once
        IEscrowVault.IssuerCommitment memory noDailyLimit = IEscrowVault.IssuerCommitment({
            dailyWithdrawLimit: 0,
            lockDuration: 0,
            maxSellPercent: 200
        });
        PoolId pid = PoolId.wrap(bytes32(uint256(42)));
        vm.prank(hook);
        uint256 escrowId = vault.createEscrow(pid, issuer, ESCROW_LIQUIDITY, _defaultSchedule(), noDailyLimit);

        // Warp past all vesting (90 days schedule, no lock)
        vm.warp(block.timestamp + 90 days + 1);

        vm.prank(hook);
        vault.recordLPRemoval(escrowId, ESCROW_LIQUIDITY);

        assertTrue(vault.isFullyVested(pid));
    }

    function test_isFullyVested_falseForNonexistent() public view {
        PoolId unknownPool = PoolId.wrap(bytes32(uint256(999)));
        assertFalse(vault.isFullyVested(unknownPool));
    }

    // ═══════════════════════════════════════════════════════════════════
    //  getVestingEndTime TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_getVestingEndTime_returnsCorrectTime() public {
        uint256 startTs = block.timestamp;
        _createDefaultEscrow();
        // Default schedule: last milestone at 90 days, lockDuration = 0
        uint256 endTime = vault.getVestingEndTime(defaultPoolId);
        assertEq(endTime, startTs + 90 days);
    }

    function test_getVestingEndTime_withLockDuration() public {
        uint256 startTs = block.timestamp;
        IEscrowVault.VestingStep[] memory schedule = _defaultSchedule();
        IEscrowVault.IssuerCommitment memory commitment = IEscrowVault.IssuerCommitment({
            dailyWithdrawLimit: 500,
            lockDuration: 30 days,
            maxSellPercent: 200
        });
        vm.prank(hook);
        vault.createEscrow(defaultPoolId, issuer, ESCROW_LIQUIDITY, schedule, commitment);

        uint256 endTime = vault.getVestingEndTime(defaultPoolId);
        assertEq(endTime, startTs + 30 days + 90 days);
    }

    function test_getVestingEndTime_zeroForNonexistent() public view {
        PoolId unknownPool = PoolId.wrap(bytes32(uint256(999)));
        assertEq(vault.getVestingEndTime(unknownPool), 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  CUSTOM VESTING — MINIMUM DURATION TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_CustomVesting_MinDuration_7Days() public {
        IEscrowVault.VestingStep[] memory schedule = new IEscrowVault.VestingStep[](1);
        schedule[0] = IEscrowVault.VestingStep({timeOffset: 7 days, basisPoints: 10000});

        vm.prank(hook);
        vault.createEscrow(defaultPoolId, issuer, ESCROW_LIQUIDITY, schedule, _defaultCommitment());
        // Should succeed — exactly 7 days
    }

    function test_CustomVesting_BelowMinDuration_Reverts() public {
        IEscrowVault.VestingStep[] memory schedule = new IEscrowVault.VestingStep[](1);
        schedule[0] = IEscrowVault.VestingStep({timeOffset: 3 days, basisPoints: 10000});

        vm.prank(hook);
        vm.expectRevert(EscrowVault.VestingBelowMinDuration.selector);
        vault.createEscrow(defaultPoolId, issuer, ESCROW_LIQUIDITY, schedule, _defaultCommitment());
    }

    function test_CustomVesting_1Day_Reverts() public {
        IEscrowVault.VestingStep[] memory schedule = new IEscrowVault.VestingStep[](1);
        schedule[0] = IEscrowVault.VestingStep({timeOffset: 1 days, basisPoints: 10000});

        vm.prank(hook);
        vm.expectRevert(EscrowVault.VestingBelowMinDuration.selector);
        vault.createEscrow(defaultPoolId, issuer, ESCROW_LIQUIDITY, schedule, _defaultCommitment());
    }

    // ═══════════════════════════════════════════════════════════════════
    //  CUSTOM VESTING — FREE SCHEDULE TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_CustomVesting_ShorterThanDefault_Allowed() public {
        IEscrowVault.VestingStep[] memory schedule = new IEscrowVault.VestingStep[](2);
        schedule[0] = IEscrowVault.VestingStep({timeOffset: 7 days, basisPoints: 5000});
        schedule[1] = IEscrowVault.VestingStep({timeOffset: 14 days, basisPoints: 10000});

        vm.prank(hook);
        vault.createEscrow(defaultPoolId, issuer, ESCROW_LIQUIDITY, schedule, _defaultCommitment());
    }

    function test_CustomVesting_LooserThanDefault_Allowed() public {
        IEscrowVault.VestingStep[] memory schedule = new IEscrowVault.VestingStep[](2);
        schedule[0] = IEscrowVault.VestingStep({timeOffset: 7 days, basisPoints: 5000});
        schedule[1] = IEscrowVault.VestingStep({timeOffset: 30 days, basisPoints: 10000});

        vm.prank(hook);
        vault.createEscrow(defaultPoolId, issuer, ESCROW_LIQUIDITY, schedule, _defaultCommitment());
    }

    function test_CustomVesting_LongerThanDefault_Allowed() public {
        IEscrowVault.VestingStep[] memory schedule = new IEscrowVault.VestingStep[](3);
        schedule[0] = IEscrowVault.VestingStep({timeOffset: 14 days, basisPoints: 500});
        schedule[1] = IEscrowVault.VestingStep({timeOffset: 60 days, basisPoints: 2000});
        schedule[2] = IEscrowVault.VestingStep({timeOffset: 180 days, basisPoints: 10000});

        vm.prank(hook);
        vault.createEscrow(defaultPoolId, issuer, ESCROW_LIQUIDITY, schedule, _defaultCommitment());
    }

    function test_CustomVesting_SingleMilestone_Allowed() public {
        IEscrowVault.VestingStep[] memory schedule = new IEscrowVault.VestingStep[](1);
        schedule[0] = IEscrowVault.VestingStep({timeOffset: 30 days, basisPoints: 10000});

        vm.prank(hook);
        vault.createEscrow(defaultPoolId, issuer, ESCROW_LIQUIDITY, schedule, _defaultCommitment());
    }

    function test_CustomVesting_ManyMilestones_Allowed() public {
        IEscrowVault.VestingStep[] memory schedule = new IEscrowVault.VestingStep[](6);
        schedule[0] = IEscrowVault.VestingStep({timeOffset: 7 days, basisPoints: 500});
        schedule[1] = IEscrowVault.VestingStep({timeOffset: 14 days, basisPoints: 1000});
        schedule[2] = IEscrowVault.VestingStep({timeOffset: 30 days, basisPoints: 2000});
        schedule[3] = IEscrowVault.VestingStep({timeOffset: 60 days, basisPoints: 4000});
        schedule[4] = IEscrowVault.VestingStep({timeOffset: 120 days, basisPoints: 7000});
        schedule[5] = IEscrowVault.VestingStep({timeOffset: 180 days, basisPoints: 10000});

        vm.prank(hook);
        vault.createEscrow(defaultPoolId, issuer, ESCROW_LIQUIDITY, schedule, _defaultCommitment());
    }

    // ═══════════════════════════════════════════════════════════════════
    //  isStricterThanDefault TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_IsStricter_DefaultSchedule_True() public {
        // Default schedule [7d→10%, 30d→30%, 90d→100%] — same as default, isStricter returns true
        _createDefaultEscrow();
        assertTrue(vault.isStricterThanDefault(defaultEscrowId));
        assertEq(vault.getVestingStrictnessLevel(defaultEscrowId), 1); // same
    }

    function test_IsStricter_LongerDuration_True() public {
        IEscrowVault.VestingStep[] memory schedule = new IEscrowVault.VestingStep[](3);
        schedule[0] = IEscrowVault.VestingStep({timeOffset: 14 days, basisPoints: 500});
        schedule[1] = IEscrowVault.VestingStep({timeOffset: 60 days, basisPoints: 2000});
        schedule[2] = IEscrowVault.VestingStep({timeOffset: 180 days, basisPoints: 10000});

        vm.prank(hook);
        uint256 escrowId = vault.createEscrow(
            defaultPoolId, issuer, ESCROW_LIQUIDITY, schedule, _defaultCommitment()
        );

        assertTrue(vault.isStricterThanDefault(escrowId));
        assertEq(vault.getVestingStrictnessLevel(escrowId), 2); // stricter
    }

    function test_IsStricter_ShorterDuration_False() public {
        IEscrowVault.VestingStep[] memory schedule = new IEscrowVault.VestingStep[](2);
        schedule[0] = IEscrowVault.VestingStep({timeOffset: 7 days, basisPoints: 5000});
        schedule[1] = IEscrowVault.VestingStep({timeOffset: 14 days, basisPoints: 10000});

        vm.prank(hook);
        uint256 escrowId = vault.createEscrow(
            defaultPoolId, issuer, ESCROW_LIQUIDITY, schedule, _defaultCommitment()
        );

        assertFalse(vault.isStricterThanDefault(escrowId));
        assertEq(vault.getVestingStrictnessLevel(escrowId), 0); // looser (duration < 90d)
    }

    function test_IsStricter_HigherRatios_False() public {
        IEscrowVault.VestingStep[] memory schedule = new IEscrowVault.VestingStep[](3);
        schedule[0] = IEscrowVault.VestingStep({timeOffset: 7 days, basisPoints: 5000}); // 50% > 10%
        schedule[1] = IEscrowVault.VestingStep({timeOffset: 30 days, basisPoints: 8000}); // 80% > 30%
        schedule[2] = IEscrowVault.VestingStep({timeOffset: 90 days, basisPoints: 10000});

        vm.prank(hook);
        uint256 escrowId = vault.createEscrow(
            defaultPoolId, issuer, ESCROW_LIQUIDITY, schedule, _defaultCommitment()
        );

        assertFalse(vault.isStricterThanDefault(escrowId));
        assertEq(vault.getVestingStrictnessLevel(escrowId), 0); // looser (higher % at early milestones)
    }
}
