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

// ─── Mock BastionHook (for triggerForceRemoval calls) ────────────────────────

contract MockBastionHook {
    bool public forceRemoveCalled;
    PoolId public lastPoolId;
    bool public shouldRevert;

    function forceRemoveIssuerLP(PoolId poolId) external {
        if (shouldRevert) revert("MockHook: forced revert");
        forceRemoveCalled = true;
        lastPoolId = poolId;
    }

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }
}

// ─── Test Contract ────────────────────────────────────────────────────────────

contract EscrowVaultTest is Test {
    EscrowVault public vault;
    MockBastionHook public mockHook;

    address public hook;
    address public oracle;
    address public issuer;

    PoolId public defaultPoolId;
    uint256 public defaultEscrowId;

    uint128 constant ESCROW_LIQUIDITY = 100e18;

    // Default: 7 day lock + 83 day vesting = 90 day total
    uint40 constant DEFAULT_LOCK = 7 days;
    uint40 constant DEFAULT_VESTING = 83 days;

    function setUp() public {
        mockHook = new MockBastionHook();
        hook = address(mockHook);
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

    function _defaultCommitment() internal pure returns (IEscrowVault.IssuerCommitment memory) {
        return IEscrowVault.IssuerCommitment({
            dailyWithdrawLimit: 500, // 5%
            maxSellPercent: 200 // 2%
        });
    }

    function _createDefaultEscrow() internal returns (uint256) {
        vm.prank(hook);
        return vault.createEscrow(
            defaultPoolId, issuer, ESCROW_LIQUIDITY, DEFAULT_LOCK, DEFAULT_VESTING, _defaultCommitment()
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
        emit IEscrowVault.EscrowCreated(defaultEscrowId, defaultPoolId, issuer, ESCROW_LIQUIDITY, DEFAULT_LOCK, DEFAULT_VESTING);
        _createDefaultEscrow();
    }

    function test_createEscrow_revertsNotHook() public {
        vm.expectRevert(EscrowVault.OnlyHook.selector);
        vault.createEscrow(
            defaultPoolId, issuer, ESCROW_LIQUIDITY, DEFAULT_LOCK, DEFAULT_VESTING, _defaultCommitment()
        );
    }

    function test_createEscrow_revertsZeroAmount() public {
        vm.prank(hook);
        vm.expectRevert(EscrowVault.ZeroAmount.selector);
        vault.createEscrow(defaultPoolId, issuer, 0, DEFAULT_LOCK, DEFAULT_VESTING, _defaultCommitment());
    }

    function test_createEscrow_revertsDuplicate() public {
        _createDefaultEscrow();

        vm.prank(hook);
        vm.expectRevert(EscrowVault.EscrowAlreadyExists.selector);
        vault.createEscrow(
            defaultPoolId, issuer, ESCROW_LIQUIDITY, DEFAULT_LOCK, DEFAULT_VESTING, _defaultCommitment()
        );
    }

    function test_createEscrow_revertsLockDurationTooShort() public {
        vm.prank(hook);
        vm.expectRevert(EscrowVault.LockDurationTooShort.selector);
        vault.createEscrow(defaultPoolId, issuer, ESCROW_LIQUIDITY, 3 days, DEFAULT_VESTING, _defaultCommitment());
    }

    function test_createEscrow_revertsVestingDurationTooShort() public {
        vm.prank(hook);
        vm.expectRevert(EscrowVault.VestingDurationTooShort.selector);
        vault.createEscrow(defaultPoolId, issuer, ESCROW_LIQUIDITY, DEFAULT_LOCK, 3 days, _defaultCommitment());
    }

    // ═══════════════════════════════════════════════════════════════════
    //  VESTING CALCULATION TESTS (linear vesting)
    // ═══════════════════════════════════════════════════════════════════

    function test_calculateVestedLiquidity_duringLock() public {
        _createDefaultEscrow();

        // During lock period (7 days)
        vm.warp(block.timestamp + 3 days);
        assertEq(vault.calculateVestedLiquidity(defaultEscrowId), 0);
    }

    function test_calculateVestedLiquidity_atLockEnd() public {
        _createDefaultEscrow();

        // Right at lock end — vestingElapsed = 0
        vm.warp(block.timestamp + 7 days);
        assertEq(vault.calculateVestedLiquidity(defaultEscrowId), 0);
    }

    function test_calculateVestedLiquidity_halfVesting() public {
        _createDefaultEscrow();

        // Lock (7d) + half of vesting (41.5d) = 48.5d
        vm.warp(block.timestamp + 7 days + 41.5 days);
        uint128 vested = vault.calculateVestedLiquidity(defaultEscrowId);
        // 50% of 100e18 = 50e18 (approximately)
        assertEq(vested, uint128((uint256(ESCROW_LIQUIDITY) * 41.5 days) / DEFAULT_VESTING));
    }

    function test_calculateVestedLiquidity_fullyVested() public {
        _createDefaultEscrow();

        // Lock (7d) + vesting (83d) = 90d
        vm.warp(block.timestamp + 90 days);
        assertEq(vault.calculateVestedLiquidity(defaultEscrowId), ESCROW_LIQUIDITY);
    }

    function test_calculateVestedLiquidity_afterFullVesting() public {
        _createDefaultEscrow();

        vm.warp(block.timestamp + 180 days);
        assertEq(vault.calculateVestedLiquidity(defaultEscrowId), ESCROW_LIQUIDITY);
    }

    function test_calculateVestedLiquidity_linearProgression() public {
        _createDefaultEscrow();

        // At lock + 1/4 vesting
        vm.warp(block.timestamp + 7 days + DEFAULT_VESTING / 4);
        uint128 vested = vault.calculateVestedLiquidity(defaultEscrowId);
        assertEq(vested, ESCROW_LIQUIDITY / 4);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  RECORD LP REMOVAL TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_recordLPRemoval_happyPath() public {
        IEscrowVault.IssuerCommitment memory commitment = IEscrowVault.IssuerCommitment({
            dailyWithdrawLimit: 0,
            maxSellPercent: 200
        });

        vm.prank(hook);
        uint256 escrowId = vault.createEscrow(
            defaultPoolId, issuer, ESCROW_LIQUIDITY, DEFAULT_LOCK, DEFAULT_VESTING, commitment
        );

        // Warp past lock + full vesting
        vm.warp(block.timestamp + 90 days);

        vm.prank(hook);
        vault.recordLPRemoval(escrowId, 10e18);

        IEscrowVault.EscrowStatus memory status = vault.getEscrowStatus(escrowId);
        assertEq(status.removedLiquidity, 10e18);
        assertEq(status.remainingLiquidity, 90e18);
    }

    function test_recordLPRemoval_partialVesting() public {
        IEscrowVault.IssuerCommitment memory commitment = IEscrowVault.IssuerCommitment({
            dailyWithdrawLimit: 0,
            maxSellPercent: 200
        });

        vm.prank(hook);
        uint256 escrowId = vault.createEscrow(
            defaultPoolId, issuer, ESCROW_LIQUIDITY, DEFAULT_LOCK, DEFAULT_VESTING, commitment
        );

        // Warp to lock + half vesting → ~50% vested
        vm.warp(block.timestamp + 7 days + DEFAULT_VESTING / 2);
        uint128 vested = vault.calculateVestedLiquidity(escrowId);
        assertGt(vested, 0);

        vm.prank(hook);
        vault.recordLPRemoval(escrowId, vested);

        IEscrowVault.EscrowStatus memory status = vault.getEscrowStatus(escrowId);
        assertEq(status.removedLiquidity, vested);
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

        vm.warp(block.timestamp + 90 days);

        vm.expectRevert(EscrowVault.OnlyHook.selector);
        vault.recordLPRemoval(defaultEscrowId, 10e18);
    }

    function test_recordLPRemoval_revertsWhenTriggered() public {
        _createDefaultEscrow();

        vm.warp(block.timestamp + 90 days);

        vm.prank(oracle);
        vault.triggerForceRemoval(defaultEscrowId, 1);

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
            maxSellPercent: 200
        });

        vm.prank(hook);
        uint256 escrowId = vault.createEscrow(
            defaultPoolId, issuer, ESCROW_LIQUIDITY, DEFAULT_LOCK, DEFAULT_VESTING, commitment
        );

        vm.warp(block.timestamp + 90 days);

        vm.expectEmit(true, false, false, true);
        emit IEscrowVault.LPRemovalRecorded(escrowId, 10e18);

        vm.prank(hook);
        vault.recordLPRemoval(escrowId, 10e18);
    }

    function test_recordLPRemoval_exceedsRemovable_reverts() public {
        IEscrowVault.IssuerCommitment memory commitment = IEscrowVault.IssuerCommitment({
            dailyWithdrawLimit: 0,
            maxSellPercent: 200
        });

        vm.prank(hook);
        uint256 escrowId = vault.createEscrow(
            defaultPoolId, issuer, ESCROW_LIQUIDITY, DEFAULT_LOCK, DEFAULT_VESTING, commitment
        );

        // Warp to lock + 1/10 vesting → 10% vested = 10e18
        vm.warp(block.timestamp + 7 days + DEFAULT_VESTING / 10);
        uint128 vested = vault.calculateVestedLiquidity(escrowId);

        vm.prank(hook);
        vm.expectRevert(EscrowVault.NothingToRelease.selector);
        vault.recordLPRemoval(escrowId, vested + 1);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  DAILY LIMIT TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_dailyLimit_withinLimit() public {
        _createDefaultEscrow();

        // dailyWithdrawLimit = 500 bps = 5% = 5e18 of 100e18
        // Warp past full vesting so enough is vested
        vm.warp(block.timestamp + 90 days);

        vm.prank(hook);
        vault.recordLPRemoval(defaultEscrowId, 5e18);

        IEscrowVault.EscrowStatus memory status = vault.getEscrowStatus(defaultEscrowId);
        assertEq(status.removedLiquidity, 5e18);
    }

    function test_dailyLimit_exceedsLimit() public {
        _createDefaultEscrow();

        vm.warp(block.timestamp + 90 days);

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

        vm.warp(block.timestamp + 90 days);

        // First day: remove 5e18
        vm.prank(hook);
        vault.recordLPRemoval(defaultEscrowId, 5e18);

        // Next day: can remove another 5e18
        vm.warp(block.timestamp + 1 days);
        vm.prank(hook);
        vault.recordLPRemoval(defaultEscrowId, 5e18);

        IEscrowVault.EscrowStatus memory status = vault.getEscrowStatus(defaultEscrowId);
        assertEq(status.removedLiquidity, 10e18);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  TRIGGER LOCKDOWN TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_triggerForceRemoval_setsTriggered() public {
        _createDefaultEscrow();

        vm.prank(oracle);
        vault.triggerForceRemoval(defaultEscrowId, 1);

        assertEq(vault.getRemovableLiquidity(defaultEscrowId), 0);
    }

    function test_triggerForceRemoval_emitsEvent() public {
        _createDefaultEscrow();

        vm.expectEmit(true, true, false, true);
        emit IEscrowVault.ForceRemoval(defaultEscrowId, 1, ESCROW_LIQUIDITY);

        vm.prank(oracle);
        vault.triggerForceRemoval(defaultEscrowId, 1);
    }

    function test_triggerForceRemoval_callsHook() public {
        _createDefaultEscrow();

        vm.prank(oracle);
        vault.triggerForceRemoval(defaultEscrowId, 1);

        assertTrue(mockHook.forceRemoveCalled());
    }

    function test_triggerForceRemoval_persistsOnHookFailure() public {
        _createDefaultEscrow();

        mockHook.setShouldRevert(true);

        vm.prank(oracle);
        vault.triggerForceRemoval(defaultEscrowId, 1);

        assertEq(vault.getRemovableLiquidity(defaultEscrowId), 0);
    }

    function test_triggerForceRemoval_revertsNotOracle() public {
        _createDefaultEscrow();

        vm.expectRevert(EscrowVault.OnlyTriggerOracle.selector);
        vault.triggerForceRemoval(defaultEscrowId, 1);
    }

    function test_triggerForceRemoval_revertsAlreadyTriggered() public {
        _createDefaultEscrow();

        vm.prank(oracle);
        vault.triggerForceRemoval(defaultEscrowId, 1);

        vm.prank(oracle);
        vm.expectRevert(EscrowVault.EscrowTriggered.selector);
        vault.triggerForceRemoval(defaultEscrowId, 2);
    }

    function test_triggerForceRemoval_revertsNotFound() public {
        vm.prank(oracle);
        vm.expectRevert(EscrowVault.EscrowNotFound.selector);
        vault.triggerForceRemoval(999, 1);
    }

    function test_triggerForceRemoval_blocksRemoval() public {
        IEscrowVault.IssuerCommitment memory commitment = IEscrowVault.IssuerCommitment({
            dailyWithdrawLimit: 0,
            maxSellPercent: 200
        });

        vm.prank(hook);
        uint256 escrowId = vault.createEscrow(
            defaultPoolId, issuer, ESCROW_LIQUIDITY, DEFAULT_LOCK, DEFAULT_VESTING, commitment
        );

        vm.warp(block.timestamp + 90 days);

        vm.prank(oracle);
        vault.triggerForceRemoval(escrowId, 1);

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
            maxSellPercent: 200
        });

        vm.prank(hook);
        uint256 escrowId = vault.createEscrow(
            defaultPoolId, issuer, ESCROW_LIQUIDITY, DEFAULT_LOCK, DEFAULT_VESTING, commitment
        );

        vm.warp(block.timestamp + 90 days);
        assertEq(vault.getRemovableLiquidity(escrowId), ESCROW_LIQUIDITY);
    }

    function test_getRemovableLiquidity_afterPartialRemoval() public {
        IEscrowVault.IssuerCommitment memory commitment = IEscrowVault.IssuerCommitment({
            dailyWithdrawLimit: 0,
            maxSellPercent: 200
        });

        vm.prank(hook);
        uint256 escrowId = vault.createEscrow(
            defaultPoolId, issuer, ESCROW_LIQUIDITY, DEFAULT_LOCK, DEFAULT_VESTING, commitment
        );

        vm.warp(block.timestamp + 90 days);
        vm.prank(hook);
        vault.recordLPRemoval(escrowId, 50e18);

        assertEq(vault.getRemovableLiquidity(escrowId), 50e18);
    }

    function test_getRemovableLiquidity_zeroAfterTrigger() public {
        _createDefaultEscrow();

        vm.warp(block.timestamp + 90 days);

        vm.prank(oracle);
        vault.triggerForceRemoval(defaultEscrowId, 1);

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
        assertEq(address(vault).balance, 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  COMMITMENT TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_setCommitment_stricter() public {
        _createDefaultEscrow();

        IEscrowVault.IssuerCommitment memory stricter = IEscrowVault.IssuerCommitment({
            dailyWithdrawLimit: 300, // 3% (was 5%)
            maxSellPercent: 200
        });

        vm.prank(issuer);
        vault.setCommitment(defaultEscrowId, stricter);
    }

    function test_setCommitment_emitsEvent() public {
        _createDefaultEscrow();

        IEscrowVault.IssuerCommitment memory stricter = IEscrowVault.IssuerCommitment({
            dailyWithdrawLimit: 300,
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
            maxSellPercent: 200
        });

        vm.expectRevert(EscrowVault.OnlyIssuer.selector);
        vault.setCommitment(defaultEscrowId, stricter);
    }

    function test_setCommitment_revertsLooserDailyLimit() public {
        _createDefaultEscrow();

        IEscrowVault.IssuerCommitment memory looser = IEscrowVault.IssuerCommitment({
            dailyWithdrawLimit: 800, // 8% (was 5%) — looser
            maxSellPercent: 200
        });

        vm.prank(issuer);
        vm.expectRevert(EscrowVault.CommitmentNotStricter.selector);
        vault.setCommitment(defaultEscrowId, looser);
    }

    function test_setCommitment_revertsLooserMaxSellPercent() public {
        _createDefaultEscrow();

        IEscrowVault.IssuerCommitment memory looser = IEscrowVault.IssuerCommitment({
            dailyWithdrawLimit: 500,
            maxSellPercent: 500 // 5% (was 2%) — looser
        });

        vm.prank(issuer);
        vm.expectRevert(EscrowVault.CommitmentNotStricter.selector);
        vault.setCommitment(defaultEscrowId, looser);
    }

    function test_setCommitment_revertsIdentical() public {
        _createDefaultEscrow();

        IEscrowVault.IssuerCommitment memory same = _defaultCommitment();

        vm.prank(issuer);
        vm.expectRevert(EscrowVault.CommitmentNotStricter.selector);
        vault.setCommitment(defaultEscrowId, same);
    }

    function test_setCommitment_revertsWhenTriggered() public {
        _createDefaultEscrow();

        vm.prank(oracle);
        vault.triggerForceRemoval(defaultEscrowId, 1);

        IEscrowVault.IssuerCommitment memory stricter = IEscrowVault.IssuerCommitment({
            dailyWithdrawLimit: 300,
            maxSellPercent: 200
        });

        vm.prank(issuer);
        vm.expectRevert(EscrowVault.EscrowTriggered.selector);
        vault.setCommitment(defaultEscrowId, stricter);
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
        // Next unlock should be at createdAt + lockDuration
        assertEq(status.nextUnlockTime, block.timestamp + 7 days);
    }

    function test_getEscrowStatus_afterLockPeriod() public {
        _createDefaultEscrow();

        vm.warp(block.timestamp + 8 days);

        IEscrowVault.EscrowStatus memory status = vault.getEscrowStatus(defaultEscrowId);
        assertEq(status.nextUnlockTime, 0); // Already past lock
    }

    function test_getEscrowStatus_fullyVested() public {
        IEscrowVault.IssuerCommitment memory commitment = IEscrowVault.IssuerCommitment({
            dailyWithdrawLimit: 0,
            maxSellPercent: 200
        });

        vm.prank(hook);
        uint256 escrowId = vault.createEscrow(
            defaultPoolId, issuer, ESCROW_LIQUIDITY, DEFAULT_LOCK, DEFAULT_VESTING, commitment
        );

        vm.warp(block.timestamp + 90 days);

        IEscrowVault.EscrowStatus memory status = vault.getEscrowStatus(escrowId);
        assertEq(status.nextUnlockTime, 0);
    }

    function test_getEscrowStatus_afterTrigger() public {
        _createDefaultEscrow();

        vm.prank(oracle);
        vault.triggerForceRemoval(defaultEscrowId, 1);

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
        IEscrowVault.IssuerCommitment memory noDailyLimit = IEscrowVault.IssuerCommitment({
            dailyWithdrawLimit: 0,
            maxSellPercent: 200
        });
        PoolId pid = PoolId.wrap(bytes32(uint256(42)));
        vm.prank(hook);
        uint256 escrowId = vault.createEscrow(pid, issuer, ESCROW_LIQUIDITY, DEFAULT_LOCK, DEFAULT_VESTING, noDailyLimit);

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
        uint256 endTime = vault.getVestingEndTime(defaultPoolId);
        assertEq(endTime, startTs + 7 days + 83 days);
    }

    function test_getVestingEndTime_customDurations() public {
        uint256 startTs = block.timestamp;
        vm.prank(hook);
        vault.createEscrow(defaultPoolId, issuer, ESCROW_LIQUIDITY, 30 days, 150 days, _defaultCommitment());

        uint256 endTime = vault.getVestingEndTime(defaultPoolId);
        assertEq(endTime, startTs + 30 days + 150 days);
    }

    function test_getVestingEndTime_zeroForNonexistent() public view {
        PoolId unknownPool = PoolId.wrap(bytes32(uint256(999)));
        assertEq(vault.getVestingEndTime(unknownPool), 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  CUSTOM VESTING — MINIMUM DURATION TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_CustomVesting_MinDuration_7Days() public {
        vm.prank(hook);
        vault.createEscrow(defaultPoolId, issuer, ESCROW_LIQUIDITY, 7 days, 7 days, _defaultCommitment());
        // Should succeed — exactly 7 days each
    }

    function test_CustomVesting_BelowMinLock_Reverts() public {
        vm.prank(hook);
        vm.expectRevert(EscrowVault.LockDurationTooShort.selector);
        vault.createEscrow(defaultPoolId, issuer, ESCROW_LIQUIDITY, 3 days, 7 days, _defaultCommitment());
    }

    function test_CustomVesting_BelowMinVesting_Reverts() public {
        vm.prank(hook);
        vm.expectRevert(EscrowVault.VestingDurationTooShort.selector);
        vault.createEscrow(defaultPoolId, issuer, ESCROW_LIQUIDITY, 7 days, 1 days, _defaultCommitment());
    }

    // ═══════════════════════════════════════════════════════════════════
    //  isStricterThanDefault TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_IsStricter_DefaultSchedule_True() public {
        _createDefaultEscrow();
        assertTrue(vault.isStricterThanDefault(defaultEscrowId));
        assertEq(vault.getVestingStrictnessLevel(defaultEscrowId), 1); // same
    }

    function test_IsStricter_LongerDuration_True() public {
        vm.prank(hook);
        uint256 escrowId = vault.createEscrow(
            defaultPoolId, issuer, ESCROW_LIQUIDITY, 30 days, 150 days, _defaultCommitment()
        );

        assertTrue(vault.isStricterThanDefault(escrowId));
        assertEq(vault.getVestingStrictnessLevel(escrowId), 2); // stricter
    }

    function test_IsStricter_ShorterDuration_False() public {
        vm.prank(hook);
        uint256 escrowId = vault.createEscrow(
            defaultPoolId, issuer, ESCROW_LIQUIDITY, 7 days, 7 days, _defaultCommitment()
        );

        assertFalse(vault.isStricterThanDefault(escrowId));
        assertEq(vault.getVestingStrictnessLevel(escrowId), 0); // looser (14d < 90d)
    }

    // ═══════════════════════════════════════════════════════════════════
    //  getEscrowInfo TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_getEscrowInfo() public {
        _createDefaultEscrow();

        (uint40 createdAt, uint40 lockDur, uint40 vestDur, IEscrowVault.IssuerCommitment memory commitment) =
            vault.getEscrowInfo(defaultEscrowId);

        assertEq(createdAt, uint40(block.timestamp));
        assertEq(lockDur, DEFAULT_LOCK);
        assertEq(vestDur, DEFAULT_VESTING);
        assertEq(commitment.dailyWithdrawLimit, 500);
        assertEq(commitment.maxSellPercent, 200);
    }
}
