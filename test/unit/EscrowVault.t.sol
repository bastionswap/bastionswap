// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {EscrowVault} from "../../src/core/EscrowVault.sol";
import {IEscrowVault} from "../../src/interfaces/IEscrowVault.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

// ─── Mock Token ───────────────────────────────────────────────────────────────

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock", "MCK", 18) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// ─── Test Contract ────────────────────────────────────────────────────────────

contract EscrowVaultTest is Test {
    EscrowVault public vault;
    MockERC20 public token;

    address public hook;
    address public oracle;
    address public insurancePool;
    address public issuer;

    PoolId public defaultPoolId;
    uint256 public defaultEscrowId;

    uint256 constant ESCROW_AMOUNT = 100 ether;

    function setUp() public {
        hook = makeAddr("hook");
        oracle = makeAddr("oracle");
        insurancePool = makeAddr("insurancePool");
        issuer = makeAddr("issuer");

        vault = new EscrowVault(hook, oracle, insurancePool);
        token = new MockERC20();

        defaultPoolId = PoolId.wrap(bytes32(uint256(1)));
        defaultEscrowId = _computeEscrowId(defaultPoolId, issuer);

        // Mint tokens to hook and approve vault
        token.mint(hook, 1000 ether);
        vm.prank(hook);
        token.approve(address(vault), type(uint256).max);
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
            defaultPoolId, issuer, address(token), ESCROW_AMOUNT, _defaultSchedule(), _defaultCommitment()
        );
    }

    // ═══════════════════════════════════════════════════════════════════
    //  CREATION TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_createEscrow_happyPath() public {
        uint256 escrowId = _createDefaultEscrow();

        assertEq(escrowId, defaultEscrowId);
        assertEq(token.balanceOf(address(vault)), ESCROW_AMOUNT);

        IEscrowVault.EscrowStatus memory status = vault.getEscrowStatus(escrowId);
        assertEq(status.totalLocked, ESCROW_AMOUNT);
        assertEq(status.released, 0);
        assertEq(status.remaining, ESCROW_AMOUNT);
    }

    function test_createEscrow_emitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit IEscrowVault.EscrowCreated(defaultEscrowId, defaultPoolId, issuer, ESCROW_AMOUNT);
        _createDefaultEscrow();
    }

    function test_createEscrow_revertsNotHook() public {
        vm.expectRevert(EscrowVault.OnlyHook.selector);
        vault.createEscrow(
            defaultPoolId, issuer, address(token), ESCROW_AMOUNT, _defaultSchedule(), _defaultCommitment()
        );
    }

    function test_createEscrow_revertsZeroAmount() public {
        vm.prank(hook);
        vm.expectRevert(EscrowVault.ZeroAmount.selector);
        vault.createEscrow(defaultPoolId, issuer, address(token), 0, _defaultSchedule(), _defaultCommitment());
    }

    function test_createEscrow_revertsDuplicate() public {
        _createDefaultEscrow();

        vm.prank(hook);
        vm.expectRevert(EscrowVault.EscrowAlreadyExists.selector);
        vault.createEscrow(
            defaultPoolId, issuer, address(token), ESCROW_AMOUNT, _defaultSchedule(), _defaultCommitment()
        );
    }

    function test_createEscrow_revertsEmptySchedule() public {
        IEscrowVault.VestingStep[] memory empty = new IEscrowVault.VestingStep[](0);

        vm.prank(hook);
        vm.expectRevert(EscrowVault.EmptySchedule.selector);
        vault.createEscrow(defaultPoolId, issuer, address(token), ESCROW_AMOUNT, empty, _defaultCommitment());
    }

    function test_createEscrow_revertsScheduleTimesNotIncreasing() public {
        IEscrowVault.VestingStep[] memory schedule = new IEscrowVault.VestingStep[](2);
        schedule[0] = IEscrowVault.VestingStep({timeOffset: 30 days, basisPoints: 5000});
        schedule[1] = IEscrowVault.VestingStep({timeOffset: 7 days, basisPoints: 10000});

        vm.prank(hook);
        vm.expectRevert(EscrowVault.ScheduleTimesNotIncreasing.selector);
        vault.createEscrow(defaultPoolId, issuer, address(token), ESCROW_AMOUNT, schedule, _defaultCommitment());
    }

    function test_createEscrow_revertsScheduleBpsNotIncreasing() public {
        IEscrowVault.VestingStep[] memory schedule = new IEscrowVault.VestingStep[](2);
        schedule[0] = IEscrowVault.VestingStep({timeOffset: 7 days, basisPoints: 5000});
        schedule[1] = IEscrowVault.VestingStep({timeOffset: 30 days, basisPoints: 3000});

        vm.prank(hook);
        vm.expectRevert(EscrowVault.ScheduleBpsNotIncreasing.selector);
        vault.createEscrow(defaultPoolId, issuer, address(token), ESCROW_AMOUNT, schedule, _defaultCommitment());
    }

    function test_createEscrow_revertsScheduleBpsExceedsMax() public {
        IEscrowVault.VestingStep[] memory schedule = new IEscrowVault.VestingStep[](1);
        schedule[0] = IEscrowVault.VestingStep({timeOffset: 7 days, basisPoints: 10001});

        vm.prank(hook);
        vm.expectRevert(EscrowVault.ScheduleBpsExceedsMax.selector);
        vault.createEscrow(defaultPoolId, issuer, address(token), ESCROW_AMOUNT, schedule, _defaultCommitment());
    }

    function test_createEscrow_revertsScheduleFinalBpsNot10000() public {
        IEscrowVault.VestingStep[] memory schedule = new IEscrowVault.VestingStep[](1);
        schedule[0] = IEscrowVault.VestingStep({timeOffset: 7 days, basisPoints: 5000});

        vm.prank(hook);
        vm.expectRevert(EscrowVault.ScheduleFinalBpsNot10000.selector);
        vault.createEscrow(defaultPoolId, issuer, address(token), ESCROW_AMOUNT, schedule, _defaultCommitment());
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
        vault.createEscrow(defaultPoolId, issuer, address(token), ESCROW_AMOUNT, schedule, _defaultCommitment());
    }

    // ═══════════════════════════════════════════════════════════════════
    //  VESTING & RELEASE TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_calculateVestedAmount_beforeFirstStep() public {
        _createDefaultEscrow();

        // Before any vesting step
        vm.warp(block.timestamp + 3 days);
        assertEq(vault.calculateVestedAmount(defaultEscrowId), 0);
    }

    function test_calculateVestedAmount_atFirstStep() public {
        _createDefaultEscrow();

        vm.warp(block.timestamp + 7 days);
        // 10% of 100 ether = 10 ether
        assertEq(vault.calculateVestedAmount(defaultEscrowId), 10 ether);
    }

    function test_calculateVestedAmount_atSecondStep() public {
        _createDefaultEscrow();

        vm.warp(block.timestamp + 30 days);
        // 30% of 100 ether = 30 ether
        assertEq(vault.calculateVestedAmount(defaultEscrowId), 30 ether);
    }

    function test_calculateVestedAmount_atFinalStep() public {
        _createDefaultEscrow();

        vm.warp(block.timestamp + 90 days);
        assertEq(vault.calculateVestedAmount(defaultEscrowId), 100 ether);
    }

    function test_calculateVestedAmount_betweenSteps() public {
        _createDefaultEscrow();

        // Between step 1 (7d) and step 2 (30d) - should still be 10%
        vm.warp(block.timestamp + 15 days);
        assertEq(vault.calculateVestedAmount(defaultEscrowId), 10 ether);
    }

    function test_releaseVested_happyPath() public {
        // Use no daily limit for simpler test
        IEscrowVault.IssuerCommitment memory commitment = IEscrowVault.IssuerCommitment({
            dailyWithdrawLimit: 0,
            lockDuration: 0,
            maxSellPercent: 200
        });

        vm.prank(hook);
        uint256 escrowId = vault.createEscrow(
            defaultPoolId, issuer, address(token), ESCROW_AMOUNT, _defaultSchedule(), commitment
        );

        vm.warp(block.timestamp + 7 days);

        uint256 released = vault.releaseVested(escrowId);
        assertEq(released, 10 ether);
        assertEq(token.balanceOf(issuer), 10 ether);

        IEscrowVault.EscrowStatus memory status = vault.getEscrowStatus(escrowId);
        assertEq(status.released, 10 ether);
        assertEq(status.remaining, 90 ether);
    }

    function test_releaseVested_multiStepRelease() public {
        IEscrowVault.IssuerCommitment memory commitment = IEscrowVault.IssuerCommitment({
            dailyWithdrawLimit: 0,
            lockDuration: 0,
            maxSellPercent: 200
        });

        vm.prank(hook);
        uint256 escrowId = vault.createEscrow(
            defaultPoolId, issuer, address(token), ESCROW_AMOUNT, _defaultSchedule(), commitment
        );

        // Release at 7 days
        vm.warp(block.timestamp + 7 days);
        vault.releaseVested(escrowId);
        assertEq(token.balanceOf(issuer), 10 ether);

        // Release at 30 days (should release an additional 20 ether)
        vm.warp(block.timestamp + 23 days);
        uint256 released = vault.releaseVested(escrowId);
        assertEq(released, 20 ether);
        assertEq(token.balanceOf(issuer), 30 ether);
    }

    function test_releaseVested_revertsNothingToRelease() public {
        _createDefaultEscrow();

        // Before any vesting
        vm.expectRevert(EscrowVault.NothingToRelease.selector);
        vault.releaseVested(defaultEscrowId);
    }

    function test_releaseVested_revertsWhenTriggered() public {
        _createDefaultEscrow();

        vm.warp(block.timestamp + 7 days);

        // Trigger redistribution first
        vm.prank(oracle);
        vault.triggerRedistribution(defaultEscrowId, 1);

        vm.expectRevert(EscrowVault.EscrowTriggered.selector);
        vault.releaseVested(defaultEscrowId);
    }

    function test_releaseVested_revertsNotFound() public {
        vm.expectRevert(EscrowVault.EscrowNotFound.selector);
        vault.releaseVested(999);
    }

    function test_releaseVested_roundingDown() public {
        // Use an amount that doesn't divide evenly by 10000
        uint256 oddAmount = 33;

        token.mint(hook, oddAmount);

        IEscrowVault.IssuerCommitment memory commitment = IEscrowVault.IssuerCommitment({
            dailyWithdrawLimit: 0,
            lockDuration: 0,
            maxSellPercent: 200
        });

        PoolId poolId2 = PoolId.wrap(bytes32(uint256(42)));

        vm.prank(hook);
        uint256 escrowId = vault.createEscrow(poolId2, issuer, address(token), oddAmount, _defaultSchedule(), commitment);

        vm.warp(block.timestamp + 7 days);

        // 10% of 33 = 3.3 => should round down to 3
        uint256 released = vault.releaseVested(escrowId);
        assertEq(released, 3);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  DAILY LIMIT TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_dailyLimit_withinLimit() public {
        _createDefaultEscrow();

        // dailyWithdrawLimit = 500 bps = 5% = 5 ether of 100 ether
        vm.warp(block.timestamp + 7 days);

        // 10 ether vested, but daily limit is 5 ether
        uint256 released = vault.releaseVested(defaultEscrowId);
        assertEq(released, 5 ether);
    }

    function test_dailyLimit_exceedsLimit() public {
        _createDefaultEscrow();

        vm.warp(block.timestamp + 7 days);

        // First release: 5 ether (daily max)
        vault.releaseVested(defaultEscrowId);

        // Second release same day: should revert
        vm.expectRevert(EscrowVault.DailyLimitExceeded.selector);
        vault.releaseVested(defaultEscrowId);
    }

    function test_dailyLimit_resetsNextDay() public {
        _createDefaultEscrow();

        vm.warp(block.timestamp + 7 days);

        // First day: release 5 ether
        vault.releaseVested(defaultEscrowId);
        assertEq(token.balanceOf(issuer), 5 ether);

        // Next day: can release another 5 ether
        vm.warp(block.timestamp + 1 days);
        vault.releaseVested(defaultEscrowId);
        assertEq(token.balanceOf(issuer), 10 ether);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  TRIGGER REDISTRIBUTION TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_triggerRedistribution_fullAmount() public {
        _createDefaultEscrow();

        vm.prank(oracle);
        uint256 redistributed = vault.triggerRedistribution(defaultEscrowId, 1);

        assertEq(redistributed, ESCROW_AMOUNT);
        assertEq(token.balanceOf(insurancePool), ESCROW_AMOUNT);
        assertEq(token.balanceOf(address(vault)), 0);
    }

    function test_triggerRedistribution_afterPartialRelease() public {
        IEscrowVault.IssuerCommitment memory commitment = IEscrowVault.IssuerCommitment({
            dailyWithdrawLimit: 0,
            lockDuration: 0,
            maxSellPercent: 200
        });

        vm.prank(hook);
        uint256 escrowId = vault.createEscrow(
            defaultPoolId, issuer, address(token), ESCROW_AMOUNT, _defaultSchedule(), commitment
        );

        // Release 10 ether at 7 days
        vm.warp(block.timestamp + 7 days);
        vault.releaseVested(escrowId);

        // Trigger - should redistribute remaining 90 ether
        vm.prank(oracle);
        uint256 redistributed = vault.triggerRedistribution(escrowId, 2);

        assertEq(redistributed, 90 ether);
        assertEq(token.balanceOf(insurancePool), 90 ether);
    }

    function test_triggerRedistribution_emitsEvent() public {
        _createDefaultEscrow();

        vm.expectEmit(true, false, false, true);
        emit IEscrowVault.Redistributed(defaultEscrowId, 1, ESCROW_AMOUNT);

        vm.prank(oracle);
        vault.triggerRedistribution(defaultEscrowId, 1);
    }

    function test_triggerRedistribution_revertsNotOracle() public {
        _createDefaultEscrow();

        vm.expectRevert(EscrowVault.OnlyTriggerOracle.selector);
        vault.triggerRedistribution(defaultEscrowId, 1);
    }

    function test_triggerRedistribution_revertsAlreadyTriggered() public {
        _createDefaultEscrow();

        vm.prank(oracle);
        vault.triggerRedistribution(defaultEscrowId, 1);

        vm.prank(oracle);
        vm.expectRevert(EscrowVault.EscrowTriggered.selector);
        vault.triggerRedistribution(defaultEscrowId, 2);
    }

    function test_triggerRedistribution_revertsNotFound() public {
        vm.prank(oracle);
        vm.expectRevert(EscrowVault.EscrowNotFound.selector);
        vault.triggerRedistribution(999, 1);
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
            vault.createEscrow(defaultPoolId, issuer, address(token), ESCROW_AMOUNT, _defaultSchedule(), commitment);

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
        vault.triggerRedistribution(defaultEscrowId, 1);

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
            vault.createEscrow(defaultPoolId, issuer, address(token), ESCROW_AMOUNT, _defaultSchedule(), commitment);

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
        assertEq(vault.calculateVestedAmount(escrowId), 0);

        // At 10 days: effectiveElapsed = 10-3 = 7 days >= 7 days first step => 10%
        vm.warp(block.timestamp + 3 days);
        assertEq(vault.calculateVestedAmount(escrowId), 10 ether);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  STATUS TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_getEscrowStatus_initial() public {
        _createDefaultEscrow();

        IEscrowVault.EscrowStatus memory status = vault.getEscrowStatus(defaultEscrowId);
        assertEq(status.totalLocked, ESCROW_AMOUNT);
        assertEq(status.released, 0);
        assertEq(status.remaining, ESCROW_AMOUNT);
        // Next unlock should be at createdAt + 7 days (first step)
        assertEq(status.nextUnlockTime, block.timestamp + 7 days);
    }

    function test_getEscrowStatus_afterPartialRelease() public {
        IEscrowVault.IssuerCommitment memory commitment = IEscrowVault.IssuerCommitment({
            dailyWithdrawLimit: 0,
            lockDuration: 0,
            maxSellPercent: 200
        });

        vm.prank(hook);
        uint256 escrowId = vault.createEscrow(
            defaultPoolId, issuer, address(token), ESCROW_AMOUNT, _defaultSchedule(), commitment
        );

        vm.warp(block.timestamp + 7 days);
        vault.releaseVested(escrowId);

        IEscrowVault.EscrowStatus memory status = vault.getEscrowStatus(escrowId);
        assertEq(status.totalLocked, ESCROW_AMOUNT);
        assertEq(status.released, 10 ether);
        assertEq(status.remaining, 90 ether);
        // Next unlock is at 30 days from creation
    }

    function test_getEscrowStatus_fullyVested() public {
        IEscrowVault.IssuerCommitment memory commitment = IEscrowVault.IssuerCommitment({
            dailyWithdrawLimit: 0,
            lockDuration: 0,
            maxSellPercent: 200
        });

        vm.prank(hook);
        uint256 escrowId = vault.createEscrow(
            defaultPoolId, issuer, address(token), ESCROW_AMOUNT, _defaultSchedule(), commitment
        );

        vm.warp(block.timestamp + 90 days);

        IEscrowVault.EscrowStatus memory status = vault.getEscrowStatus(escrowId);
        assertEq(status.nextUnlockTime, 0); // Fully vested
    }

    function test_getEscrowStatus_afterTrigger() public {
        _createDefaultEscrow();

        vm.prank(oracle);
        vault.triggerRedistribution(defaultEscrowId, 1);

        IEscrowVault.EscrowStatus memory status = vault.getEscrowStatus(defaultEscrowId);
        assertEq(status.remaining, 0);
        assertEq(status.nextUnlockTime, 0);
    }

    function test_getEscrowStatus_revertsNotFound() public {
        vm.expectRevert(EscrowVault.EscrowNotFound.selector);
        vault.getEscrowStatus(999);
    }
}
