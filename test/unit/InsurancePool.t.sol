// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {InsurancePool} from "../../src/core/InsurancePool.sol";
import {IInsurancePool} from "../../src/interfaces/IInsurancePool.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

contract InsurancePoolTest is Test {
    InsurancePool public pool;

    address public hook;
    address public oracle;
    address public governance;

    address public holder1;
    address public holder2;
    address public holder3;

    PoolId public defaultPoolId;

    uint256 constant DEPOSIT_AMOUNT = 10 ether;
    uint256 constant TOTAL_SUPPLY = 1_000_000 ether;

    function setUp() public {
        hook = makeAddr("hook");
        oracle = makeAddr("oracle");
        governance = makeAddr("governance");
        holder1 = makeAddr("holder1");
        holder2 = makeAddr("holder2");
        holder3 = makeAddr("holder3");

        pool = new InsurancePool(hook, oracle, governance);
        defaultPoolId = PoolId.wrap(bytes32(uint256(1)));

        // Fund the hook for deposits
        vm.deal(hook, 100 ether);
    }

    // ─── Helpers ──────────────────────────────────────────────────────

    function _deposit(uint256 amount) internal {
        vm.prank(hook);
        pool.depositFee{value: amount}(defaultPoolId);
    }

    function _triggerPayout() internal {
        _triggerPayout(TOTAL_SUPPLY);
    }

    function _triggerPayout(uint256 totalSupply) internal {
        vm.prank(oracle);
        pool.executePayout(defaultPoolId, 1, totalSupply);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  FEE DEPOSIT TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_depositFee_happyPath() public {
        _deposit(DEPOSIT_AMOUNT);

        IInsurancePool.PoolStatus memory status = pool.getPoolStatus(defaultPoolId);
        assertEq(status.balance, DEPOSIT_AMOUNT);
        assertEq(address(pool).balance, DEPOSIT_AMOUNT);
    }

    function test_depositFee_multipleDeposits() public {
        _deposit(1 ether);
        _deposit(2 ether);
        _deposit(3 ether);

        IInsurancePool.PoolStatus memory status = pool.getPoolStatus(defaultPoolId);
        assertEq(status.balance, 6 ether);
    }

    function test_depositFee_emitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit IInsurancePool.FeeDeposited(defaultPoolId, DEPOSIT_AMOUNT);

        _deposit(DEPOSIT_AMOUNT);
    }

    function test_depositFee_revertsNotHook() public {
        vm.deal(address(this), 1 ether);
        vm.expectRevert(InsurancePool.OnlyHook.selector);
        pool.depositFee{value: 1 ether}(defaultPoolId);
    }

    function test_depositFee_revertsZeroAmount() public {
        vm.prank(hook);
        vm.expectRevert(InsurancePool.ZeroAmount.selector);
        pool.depositFee{value: 0}(defaultPoolId);
    }

    function test_depositFee_isolatedPools() public {
        PoolId poolId2 = PoolId.wrap(bytes32(uint256(2)));

        _deposit(5 ether);

        vm.prank(hook);
        pool.depositFee{value: 3 ether}(poolId2);

        IInsurancePool.PoolStatus memory status1 = pool.getPoolStatus(defaultPoolId);
        IInsurancePool.PoolStatus memory status2 = pool.getPoolStatus(poolId2);

        assertEq(status1.balance, 5 ether);
        assertEq(status2.balance, 3 ether);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  TRIGGER / EXECUTE PAYOUT TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_executePayout_happyPath() public {
        _deposit(DEPOSIT_AMOUNT);

        vm.prank(oracle);
        uint256 totalPayout = pool.executePayout(defaultPoolId, 1, TOTAL_SUPPLY);

        assertEq(totalPayout, DEPOSIT_AMOUNT);

        IInsurancePool.PoolStatus memory status = pool.getPoolStatus(defaultPoolId);
        assertTrue(status.isTriggered);
        assertEq(status.triggerTimestamp, block.timestamp);
        assertEq(status.totalEligibleSupply, TOTAL_SUPPLY);
    }

    function test_executePayout_emitsEvent() public {
        _deposit(DEPOSIT_AMOUNT);

        vm.expectEmit(true, false, false, true);
        emit IInsurancePool.PayoutExecuted(defaultPoolId, 1, DEPOSIT_AMOUNT);

        vm.prank(oracle);
        pool.executePayout(defaultPoolId, 1, TOTAL_SUPPLY);
    }

    function test_executePayout_revertsNotOracle() public {
        _deposit(DEPOSIT_AMOUNT);

        vm.expectRevert(InsurancePool.OnlyTriggerOracle.selector);
        pool.executePayout(defaultPoolId, 1, TOTAL_SUPPLY);
    }

    function test_executePayout_revertsAlreadyTriggered() public {
        _deposit(DEPOSIT_AMOUNT);
        _triggerPayout();

        vm.prank(oracle);
        vm.expectRevert(InsurancePool.AlreadyTriggered.selector);
        pool.executePayout(defaultPoolId, 2, TOTAL_SUPPLY);
    }

    function test_executePayout_revertsZeroEligibleSupply() public {
        _deposit(DEPOSIT_AMOUNT);

        vm.prank(oracle);
        vm.expectRevert(InsurancePool.ZeroEligibleSupply.selector);
        pool.executePayout(defaultPoolId, 1, 0);
    }

    function test_executePayout_emptyPool() public {
        // Triggering on empty pool is allowed but payout is 0
        vm.prank(oracle);
        uint256 totalPayout = pool.executePayout(defaultPoolId, 1, TOTAL_SUPPLY);
        assertEq(totalPayout, 0);

        IInsurancePool.PoolStatus memory status = pool.getPoolStatus(defaultPoolId);
        assertTrue(status.isTriggered);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  CLAIM COMPENSATION TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_claimCompensation_happyPath() public {
        _deposit(DEPOSIT_AMOUNT);
        _triggerPayout();

        uint256 holderBalance = 100_000 ether; // 10% of supply
        uint256 expectedAmount = (DEPOSIT_AMOUNT * holderBalance) / TOTAL_SUPPLY;

        vm.prank(holder1);
        uint256 claimed = pool.claimCompensation(defaultPoolId, holderBalance);

        assertEq(claimed, expectedAmount);
        assertEq(claimed, 1 ether); // 10% of 10 ether
        assertEq(holder1.balance, 1 ether);
    }

    function test_claimCompensation_emitsEvent() public {
        _deposit(DEPOSIT_AMOUNT);
        _triggerPayout();

        uint256 holderBalance = 100_000 ether;
        uint256 expectedAmount = (DEPOSIT_AMOUNT * holderBalance) / TOTAL_SUPPLY;

        vm.expectEmit(true, true, false, true);
        emit IInsurancePool.CompensationClaimed(defaultPoolId, holder1, expectedAmount);

        vm.prank(holder1);
        pool.claimCompensation(defaultPoolId, holderBalance);
    }

    function test_claimCompensation_proportionalDistribution() public {
        _deposit(DEPOSIT_AMOUNT);
        _triggerPayout();

        // holder1: 50% of supply
        uint256 balance1 = 500_000 ether;
        // holder2: 30% of supply
        uint256 balance2 = 300_000 ether;
        // holder3: 20% of supply
        uint256 balance3 = 200_000 ether;

        vm.prank(holder1);
        uint256 claim1 = pool.claimCompensation(defaultPoolId, balance1);

        vm.prank(holder2);
        uint256 claim2 = pool.claimCompensation(defaultPoolId, balance2);

        vm.prank(holder3);
        uint256 claim3 = pool.claimCompensation(defaultPoolId, balance3);

        assertEq(claim1, 5 ether); // 50%
        assertEq(claim2, 3 ether); // 30%
        assertEq(claim3, 2 ether); // 20%

        // All funds distributed
        assertEq(claim1 + claim2 + claim3, DEPOSIT_AMOUNT);
        assertEq(address(pool).balance, 0);
    }

    function test_claimCompensation_roundingDown() public {
        // Use 3 ether to create rounding scenario
        _deposit(3 ether);

        uint256 totalSupply = 1_000_000 ether;
        _triggerPayout(totalSupply);

        // 333_333 out of 1_000_000 = 33.3333%
        // 3 ether * 333_333 / 1_000_000 = 0.999999 ether (rounds down)
        uint256 holderBalance = 333_333 ether;

        vm.prank(holder1);
        uint256 claimed = pool.claimCompensation(defaultPoolId, holderBalance);

        uint256 expected = (3 ether * holderBalance) / totalSupply;
        assertEq(claimed, expected);
        assertTrue(claimed < 1 ether); // must round down
    }

    function test_claimCompensation_revertsNotTriggered() public {
        _deposit(DEPOSIT_AMOUNT);

        vm.prank(holder1);
        vm.expectRevert(InsurancePool.NotTriggered.selector);
        pool.claimCompensation(defaultPoolId, 100_000 ether);
    }

    function test_claimCompensation_revertsDuplicateClaim() public {
        _deposit(DEPOSIT_AMOUNT);
        _triggerPayout();

        vm.prank(holder1);
        pool.claimCompensation(defaultPoolId, 100_000 ether);

        vm.prank(holder1);
        vm.expectRevert(InsurancePool.AlreadyClaimed.selector);
        pool.claimCompensation(defaultPoolId, 100_000 ether);
    }

    function test_claimCompensation_revertsAfterCooldown() public {
        _deposit(DEPOSIT_AMOUNT);
        _triggerPayout();

        // Warp past claim period (30 days)
        vm.warp(block.timestamp + 30 days + 1);

        vm.prank(holder1);
        vm.expectRevert(InsurancePool.ClaimPeriodExpired.selector);
        pool.claimCompensation(defaultPoolId, 100_000 ether);
    }

    function test_claimCompensation_worksAtExactDeadline() public {
        _deposit(DEPOSIT_AMOUNT);
        _triggerPayout();

        // Warp to exactly the deadline (should still work)
        vm.warp(block.timestamp + 30 days);

        vm.prank(holder1);
        uint256 claimed = pool.claimCompensation(defaultPoolId, 100_000 ether);
        assertGt(claimed, 0);
    }

    function test_claimCompensation_revertsZeroBalance() public {
        _deposit(DEPOSIT_AMOUNT);
        _triggerPayout();

        vm.prank(holder1);
        vm.expectRevert(InsurancePool.ZeroAmount.selector);
        pool.claimCompensation(defaultPoolId, 0);
    }

    function test_claimCompensation_emptyPoolTrigger() public {
        // Trigger with zero balance
        vm.prank(oracle);
        pool.executePayout(defaultPoolId, 1, TOTAL_SUPPLY);

        // Claim should revert with ZeroAmount because compensation = 0
        vm.prank(holder1);
        vm.expectRevert(InsurancePool.ZeroAmount.selector);
        pool.claimCompensation(defaultPoolId, 100_000 ether);
    }

    function test_hasClaimed_tracksCorrectly() public {
        _deposit(DEPOSIT_AMOUNT);
        _triggerPayout();

        assertFalse(pool.hasClaimed(defaultPoolId, holder1));

        vm.prank(holder1);
        pool.claimCompensation(defaultPoolId, 100_000 ether);

        assertTrue(pool.hasClaimed(defaultPoolId, holder1));
        assertFalse(pool.hasClaimed(defaultPoolId, holder2));
    }

    // ═══════════════════════════════════════════════════════════════════
    //  CALCULATE COMPENSATION TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_calculateCompensation_returnsCorrectAmount() public {
        _deposit(DEPOSIT_AMOUNT);
        _triggerPayout();

        uint256 amount = pool.calculateCompensation(defaultPoolId, 100_000 ether);
        assertEq(amount, 1 ether); // 10% of 10 ether
    }

    function test_calculateCompensation_returnsZeroIfNotTriggered() public {
        _deposit(DEPOSIT_AMOUNT);

        uint256 amount = pool.calculateCompensation(defaultPoolId, 100_000 ether);
        assertEq(amount, 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  FEE RATE TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_setFeeRate_happyPath() public {
        vm.prank(governance);
        pool.setFeeRate(150); // 1.5%

        assertEq(pool.feeRate(), 150);
    }

    function test_setFeeRate_emitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit IInsurancePool.FeeRateUpdated(100, 150);

        vm.prank(governance);
        pool.setFeeRate(150);
    }

    function test_setFeeRate_revertsNotGovernance() public {
        vm.expectRevert(InsurancePool.OnlyGovernance.selector);
        pool.setFeeRate(150);
    }

    function test_setFeeRate_revertsTooHigh() public {
        vm.prank(governance);
        vm.expectRevert(InsurancePool.FeeRateTooHigh.selector);
        pool.setFeeRate(201); // > 2%
    }

    function test_setFeeRate_allowsMaxRate() public {
        vm.prank(governance);
        pool.setFeeRate(200); // exactly 2%
        assertEq(pool.feeRate(), 200);
    }

    function test_setFeeRate_allowsZero() public {
        vm.prank(governance);
        pool.setFeeRate(0);
        assertEq(pool.feeRate(), 0);
    }

    function test_defaultFeeRate() public view {
        assertEq(pool.feeRate(), 100); // 1%
    }

    // ═══════════════════════════════════════════════════════════════════
    //  EMERGENCY WITHDRAW TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_emergencyWithdraw_happyPath() public {
        _deposit(DEPOSIT_AMOUNT);

        address recipient = makeAddr("recipient");

        vm.prank(governance);
        pool.emergencyWithdraw(defaultPoolId, recipient, 5 ether);

        assertEq(recipient.balance, 5 ether);
        IInsurancePool.PoolStatus memory status = pool.getPoolStatus(defaultPoolId);
        assertEq(status.balance, 5 ether);
    }

    function test_emergencyWithdraw_emitsEvent() public {
        _deposit(DEPOSIT_AMOUNT);

        address recipient = makeAddr("recipient");

        vm.expectEmit(true, true, false, true);
        emit IInsurancePool.EmergencyWithdrawal(defaultPoolId, recipient, 5 ether);

        vm.prank(governance);
        pool.emergencyWithdraw(defaultPoolId, recipient, 5 ether);
    }

    function test_emergencyWithdraw_revertsNotGovernance() public {
        _deposit(DEPOSIT_AMOUNT);

        vm.expectRevert(InsurancePool.OnlyGovernance.selector);
        pool.emergencyWithdraw(defaultPoolId, holder1, 1 ether);
    }

    function test_emergencyWithdraw_revertsZeroAddress() public {
        _deposit(DEPOSIT_AMOUNT);

        vm.prank(governance);
        vm.expectRevert(InsurancePool.ZeroAddress.selector);
        pool.emergencyWithdraw(defaultPoolId, address(0), 1 ether);
    }

    function test_emergencyWithdraw_revertsZeroAmount() public {
        _deposit(DEPOSIT_AMOUNT);

        vm.prank(governance);
        vm.expectRevert(InsurancePool.ZeroAmount.selector);
        pool.emergencyWithdraw(defaultPoolId, holder1, 0);
    }

    function test_emergencyWithdraw_revertsInsufficientBalance() public {
        _deposit(1 ether);

        vm.prank(governance);
        vm.expectRevert(InsurancePool.InsufficientPoolBalance.selector);
        pool.emergencyWithdraw(defaultPoolId, holder1, 2 ether);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  POOL STATUS TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_getPoolStatus_initial() public view {
        IInsurancePool.PoolStatus memory status = pool.getPoolStatus(defaultPoolId);
        assertEq(status.balance, 0);
        assertFalse(status.isTriggered);
        assertEq(status.triggerTimestamp, 0);
        assertEq(status.totalEligibleSupply, 0);
    }

    function test_getPoolStatus_afterDeposit() public {
        _deposit(DEPOSIT_AMOUNT);

        IInsurancePool.PoolStatus memory status = pool.getPoolStatus(defaultPoolId);
        assertEq(status.balance, DEPOSIT_AMOUNT);
        assertFalse(status.isTriggered);
    }

    function test_getPoolStatus_afterTrigger() public {
        _deposit(DEPOSIT_AMOUNT);
        _triggerPayout();

        IInsurancePool.PoolStatus memory status = pool.getPoolStatus(defaultPoolId);
        assertEq(status.balance, DEPOSIT_AMOUNT); // not yet claimed
        assertTrue(status.isTriggered);
        assertEq(status.totalEligibleSupply, TOTAL_SUPPLY);
    }

    function test_getPoolStatus_afterClaims() public {
        _deposit(DEPOSIT_AMOUNT);
        _triggerPayout();

        vm.prank(holder1);
        pool.claimCompensation(defaultPoolId, 500_000 ether); // 50%

        IInsurancePool.PoolStatus memory status = pool.getPoolStatus(defaultPoolId);
        assertEq(status.balance, 5 ether); // 50% remaining
    }

    // ═══════════════════════════════════════════════════════════════════
    //  POOL ISOLATION TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_poolIsolation_triggerDoesNotAffectOther() public {
        PoolId poolId2 = PoolId.wrap(bytes32(uint256(2)));

        _deposit(5 ether);

        vm.prank(hook);
        pool.depositFee{value: 3 ether}(poolId2);

        // Trigger only pool 1
        _triggerPayout();

        IInsurancePool.PoolStatus memory status1 = pool.getPoolStatus(defaultPoolId);
        IInsurancePool.PoolStatus memory status2 = pool.getPoolStatus(poolId2);

        assertTrue(status1.isTriggered);
        assertFalse(status2.isTriggered);
        assertEq(status2.balance, 3 ether);
    }

    function test_poolIsolation_claimFromCorrectPool() public {
        PoolId poolId2 = PoolId.wrap(bytes32(uint256(2)));

        _deposit(10 ether);

        vm.prank(hook);
        pool.depositFee{value: 20 ether}(poolId2);

        _triggerPayout();

        // Claim from pool 1 gets pool 1's funds
        vm.prank(holder1);
        uint256 claim1 = pool.claimCompensation(defaultPoolId, 500_000 ether); // 50%
        assertEq(claim1, 5 ether); // 50% of 10 ether, not 20 ether

        // Pool 2 untouched
        IInsurancePool.PoolStatus memory status2 = pool.getPoolStatus(poolId2);
        assertEq(status2.balance, 20 ether);
    }
}
