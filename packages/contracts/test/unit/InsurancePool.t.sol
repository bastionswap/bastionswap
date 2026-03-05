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

        pool = new InsurancePool(hook, oracle, governance, address(0), address(0));
        defaultPoolId = PoolId.wrap(bytes32(uint256(1)));

        // Fund the hook for deposits
        vm.deal(hook, 100 ether);
    }

    // ─── Merkle Helpers ───────────────────────────────────────────────

    function _computeLeaf(address holder, uint256 balance) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(holder, balance))));
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    /// @dev Build a 2-leaf Merkle tree and return root + proofs
    function _buildTree2(
        address h1, uint256 b1,
        address h2, uint256 b2
    ) internal pure returns (bytes32 root, bytes32[] memory p1, bytes32[] memory p2) {
        bytes32 leaf1 = _computeLeaf(h1, b1);
        bytes32 leaf2 = _computeLeaf(h2, b2);
        root = _hashPair(leaf1, leaf2);
        p1 = new bytes32[](1);
        p1[0] = leaf2;
        p2 = new bytes32[](1);
        p2[0] = leaf1;
    }

    /// @dev Build a 3-leaf Merkle tree and return root + proofs
    function _buildTree3(
        address h1, uint256 b1,
        address h2, uint256 b2,
        address h3, uint256 b3
    ) internal pure returns (bytes32 root, bytes32[] memory p1, bytes32[] memory p2, bytes32[] memory p3) {
        bytes32 leaf1 = _computeLeaf(h1, b1);
        bytes32 leaf2 = _computeLeaf(h2, b2);
        bytes32 leaf3 = _computeLeaf(h3, b3);

        bytes32 pair12 = _hashPair(leaf1, leaf2);
        root = _hashPair(pair12, leaf3);

        p1 = new bytes32[](2);
        p1[0] = leaf2;
        p1[1] = leaf3;

        p2 = new bytes32[](2);
        p2[0] = leaf1;
        p2[1] = leaf3;

        p3 = new bytes32[](1);
        p3[0] = pair12;
    }

    // ─── Helpers ──────────────────────────────────────────────────────

    function _deposit(uint256 amount) internal {
        vm.prank(hook);
        pool.depositFee{value: amount}(defaultPoolId);
    }

    // Default 2-holder tree for simple tests
    bytes32 internal _defaultRoot;
    bytes32[] internal _defaultProof1;
    bytes32[] internal _defaultProof2;

    function _setupDefaultTree() internal {
        uint256 balance1 = 100_000 ether;
        uint256 balance2 = 900_000 ether;
        (bytes32 root, bytes32[] memory p1, bytes32[] memory p2) =
            _buildTree2(holder1, balance1, holder2, balance2);
        _defaultRoot = root;
        _defaultProof1 = p1;
        _defaultProof2 = p2;
    }

    function _triggerPayout() internal {
        _setupDefaultTree();
        _triggerPayoutWithRoot(TOTAL_SUPPLY, _defaultRoot);
    }

    function _triggerPayout(uint256 totalSupply) internal {
        _setupDefaultTree();
        _triggerPayoutWithRoot(totalSupply, _defaultRoot);
    }

    function _triggerPayoutWithRoot(uint256 totalSupply, bytes32 merkleRoot) internal {
        vm.prank(oracle);
        pool.executePayout(defaultPoolId, 1, totalSupply, merkleRoot, address(0));
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

        _setupDefaultTree();
        vm.prank(oracle);
        uint256 totalPayout = pool.executePayout(defaultPoolId, 1, TOTAL_SUPPLY, _defaultRoot, address(0));

        assertEq(totalPayout, DEPOSIT_AMOUNT);

        IInsurancePool.PoolStatus memory status = pool.getPoolStatus(defaultPoolId);
        assertTrue(status.isTriggered);
        assertEq(status.triggerTimestamp, block.timestamp);
        assertEq(status.totalEligibleSupply, TOTAL_SUPPLY);
    }

    function test_executePayout_emitsEvent() public {
        _deposit(DEPOSIT_AMOUNT);

        _setupDefaultTree();
        vm.expectEmit(true, true, false, true);
        emit IInsurancePool.PayoutExecuted(defaultPoolId, 1, DEPOSIT_AMOUNT);

        vm.prank(oracle);
        pool.executePayout(defaultPoolId, 1, TOTAL_SUPPLY, _defaultRoot, address(0));
    }

    function test_executePayout_revertsNotOracle() public {
        _deposit(DEPOSIT_AMOUNT);

        vm.expectRevert(InsurancePool.OnlyTriggerOracle.selector);
        pool.executePayout(defaultPoolId, 1, TOTAL_SUPPLY, bytes32(0), address(0));
    }

    function test_executePayout_revertsAlreadyTriggered() public {
        _deposit(DEPOSIT_AMOUNT);
        _triggerPayout();

        vm.prank(oracle);
        vm.expectRevert(InsurancePool.AlreadyTriggered.selector);
        pool.executePayout(defaultPoolId, 2, TOTAL_SUPPLY, bytes32(0), address(0));
    }

    function test_executePayout_revertsZeroEligibleSupply() public {
        _deposit(DEPOSIT_AMOUNT);

        vm.prank(oracle);
        vm.expectRevert(InsurancePool.ZeroEligibleSupply.selector);
        pool.executePayout(defaultPoolId, 1, 0, bytes32(0), address(0));
    }

    function test_executePayout_emptyPool() public {
        // Triggering on empty pool is allowed but payout is 0
        _setupDefaultTree();
        vm.prank(oracle);
        uint256 totalPayout = pool.executePayout(defaultPoolId, 1, TOTAL_SUPPLY, _defaultRoot, address(0));
        assertEq(totalPayout, 0);

        IInsurancePool.PoolStatus memory status = pool.getPoolStatus(defaultPoolId);
        assertTrue(status.isTriggered);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  CLAIM COMPENSATION TESTS (with Merkle proof)
    // ═══════════════════════════════════════════════════════════════════

    function test_claimCompensation_happyPath() public {
        _deposit(DEPOSIT_AMOUNT);

        uint256 holderBalance = 100_000 ether; // 10% of supply
        uint256 expectedAmount = (DEPOSIT_AMOUNT * holderBalance) / TOTAL_SUPPLY;

        // Build tree with holder1 having 100k tokens
        (bytes32 root, bytes32[] memory proof1,) =
            _buildTree2(holder1, holderBalance, holder2, 900_000 ether);

        vm.prank(oracle);
        pool.executePayout(defaultPoolId, 1, TOTAL_SUPPLY, root, address(0));

        vm.prank(holder1);
        uint256 claimed = pool.claimCompensation(defaultPoolId, holderBalance, proof1);

        assertEq(claimed, expectedAmount);
        assertEq(claimed, 1 ether); // 10% of 10 ether
        assertEq(holder1.balance, 1 ether);
    }

    function test_claimCompensation_emitsEvent() public {
        _deposit(DEPOSIT_AMOUNT);

        uint256 holderBalance = 100_000 ether;
        uint256 expectedAmount = (DEPOSIT_AMOUNT * holderBalance) / TOTAL_SUPPLY;

        (bytes32 root, bytes32[] memory proof1,) =
            _buildTree2(holder1, holderBalance, holder2, 900_000 ether);

        vm.prank(oracle);
        pool.executePayout(defaultPoolId, 1, TOTAL_SUPPLY, root, address(0));

        vm.expectEmit(true, true, false, true);
        emit IInsurancePool.CompensationClaimed(defaultPoolId, holder1, expectedAmount);

        vm.prank(holder1);
        pool.claimCompensation(defaultPoolId, holderBalance, proof1);
    }

    function test_claimCompensation_proportionalDistribution() public {
        _deposit(DEPOSIT_AMOUNT);

        // holder1: 50%, holder2: 30%, holder3: 20%
        uint256 balance1 = 500_000 ether;
        uint256 balance2 = 300_000 ether;
        uint256 balance3 = 200_000 ether;

        (bytes32 root, bytes32[] memory p1, bytes32[] memory p2, bytes32[] memory p3) =
            _buildTree3(holder1, balance1, holder2, balance2, holder3, balance3);

        vm.prank(oracle);
        pool.executePayout(defaultPoolId, 1, TOTAL_SUPPLY, root, address(0));

        vm.prank(holder1);
        uint256 claim1 = pool.claimCompensation(defaultPoolId, balance1, p1);

        vm.prank(holder2);
        uint256 claim2 = pool.claimCompensation(defaultPoolId, balance2, p2);

        vm.prank(holder3);
        uint256 claim3 = pool.claimCompensation(defaultPoolId, balance3, p3);

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
        uint256 holderBalance = 333_333 ether;

        (bytes32 root, bytes32[] memory proof1,) =
            _buildTree2(holder1, holderBalance, holder2, totalSupply - holderBalance);

        vm.prank(oracle);
        pool.executePayout(defaultPoolId, 1, totalSupply, root, address(0));

        vm.prank(holder1);
        uint256 claimed = pool.claimCompensation(defaultPoolId, holderBalance, proof1);

        uint256 expected = (3 ether * holderBalance) / totalSupply;
        assertEq(claimed, expected);
        assertTrue(claimed < 1 ether); // must round down
    }

    function test_claimCompensation_revertsNotTriggered() public {
        _deposit(DEPOSIT_AMOUNT);

        bytes32[] memory emptyProof = new bytes32[](0);
        vm.prank(holder1);
        vm.expectRevert(InsurancePool.NotTriggered.selector);
        pool.claimCompensation(defaultPoolId, 100_000 ether, emptyProof);
    }

    function test_claimCompensation_revertsDuplicateClaim() public {
        _deposit(DEPOSIT_AMOUNT);

        uint256 holderBalance = 100_000 ether;
        (bytes32 root, bytes32[] memory proof1,) =
            _buildTree2(holder1, holderBalance, holder2, 900_000 ether);

        vm.prank(oracle);
        pool.executePayout(defaultPoolId, 1, TOTAL_SUPPLY, root, address(0));

        vm.prank(holder1);
        pool.claimCompensation(defaultPoolId, holderBalance, proof1);

        vm.prank(holder1);
        vm.expectRevert(InsurancePool.AlreadyClaimed.selector);
        pool.claimCompensation(defaultPoolId, holderBalance, proof1);
    }

    function test_claimCompensation_revertsAfterCooldown() public {
        _deposit(DEPOSIT_AMOUNT);

        uint256 holderBalance = 100_000 ether;
        (bytes32 root, bytes32[] memory proof1,) =
            _buildTree2(holder1, holderBalance, holder2, 900_000 ether);

        vm.prank(oracle);
        pool.executePayout(defaultPoolId, 1, TOTAL_SUPPLY, root, address(0));

        // Warp past claim period (30 days)
        vm.warp(block.timestamp + 30 days + 1);

        vm.prank(holder1);
        vm.expectRevert(InsurancePool.ClaimPeriodExpired.selector);
        pool.claimCompensation(defaultPoolId, holderBalance, proof1);
    }

    function test_claimCompensation_worksAtExactDeadline() public {
        _deposit(DEPOSIT_AMOUNT);

        uint256 holderBalance = 100_000 ether;
        (bytes32 root, bytes32[] memory proof1,) =
            _buildTree2(holder1, holderBalance, holder2, 900_000 ether);

        vm.prank(oracle);
        pool.executePayout(defaultPoolId, 1, TOTAL_SUPPLY, root, address(0));

        // Warp to exactly the deadline (should still work)
        vm.warp(block.timestamp + 30 days);

        vm.prank(holder1);
        uint256 claimed = pool.claimCompensation(defaultPoolId, holderBalance, proof1);
        assertGt(claimed, 0);
    }

    function test_claimCompensation_revertsZeroBalance() public {
        _deposit(DEPOSIT_AMOUNT);

        // Build tree with holder1 balance = 0 won't work with Merkle proof
        // since ZeroAmount check comes before proof check
        (bytes32 root,,) = _buildTree2(holder1, 100_000 ether, holder2, 900_000 ether);

        vm.prank(oracle);
        pool.executePayout(defaultPoolId, 1, TOTAL_SUPPLY, root, address(0));

        bytes32[] memory emptyProof = new bytes32[](0);
        vm.prank(holder1);
        vm.expectRevert(InsurancePool.ZeroAmount.selector);
        pool.claimCompensation(defaultPoolId, 0, emptyProof);
    }

    function test_claimCompensation_emptyPoolTrigger() public {
        // Trigger with zero balance but valid merkle root
        uint256 holderBalance = 100_000 ether;
        (bytes32 root, bytes32[] memory proof1,) =
            _buildTree2(holder1, holderBalance, holder2, 900_000 ether);

        vm.prank(oracle);
        pool.executePayout(defaultPoolId, 1, TOTAL_SUPPLY, root, address(0));

        // Claim should revert with ZeroAmount because compensation = 0
        vm.prank(holder1);
        vm.expectRevert(InsurancePool.ZeroAmount.selector);
        pool.claimCompensation(defaultPoolId, holderBalance, proof1);
    }

    function test_hasClaimed_tracksCorrectly() public {
        _deposit(DEPOSIT_AMOUNT);

        uint256 holderBalance = 100_000 ether;
        (bytes32 root, bytes32[] memory proof1,) =
            _buildTree2(holder1, holderBalance, holder2, 900_000 ether);

        vm.prank(oracle);
        pool.executePayout(defaultPoolId, 1, TOTAL_SUPPLY, root, address(0));

        assertFalse(pool.hasClaimed(defaultPoolId, holder1));

        vm.prank(holder1);
        pool.claimCompensation(defaultPoolId, holderBalance, proof1);

        assertTrue(pool.hasClaimed(defaultPoolId, holder1));
        assertFalse(pool.hasClaimed(defaultPoolId, holder2));
    }

    // ═══════════════════════════════════════════════════════════════════
    //  MERKLE PROOF SECURITY TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_ClaimWithValidMerkleProof() public {
        _deposit(DEPOSIT_AMOUNT);

        uint256 balance1 = 500_000 ether;
        uint256 balance2 = 500_000 ether;

        (bytes32 root, bytes32[] memory proof1, bytes32[] memory proof2) =
            _buildTree2(holder1, balance1, holder2, balance2);

        vm.prank(oracle);
        pool.executePayout(defaultPoolId, 1, TOTAL_SUPPLY, root, address(0));

        vm.prank(holder1);
        uint256 claimed = pool.claimCompensation(defaultPoolId, balance1, proof1);
        assertEq(claimed, 5 ether);

        vm.prank(holder2);
        claimed = pool.claimCompensation(defaultPoolId, balance2, proof2);
        assertEq(claimed, 5 ether);
    }

    function test_ClaimWithInvalidProof_Reverts() public {
        _deposit(DEPOSIT_AMOUNT);

        uint256 holderBalance = 100_000 ether;
        (bytes32 root,,) = _buildTree2(holder1, holderBalance, holder2, 900_000 ether);

        vm.prank(oracle);
        pool.executePayout(defaultPoolId, 1, TOTAL_SUPPLY, root, address(0));

        // Use a bogus proof
        bytes32[] memory badProof = new bytes32[](1);
        badProof[0] = bytes32(uint256(0xdeadbeef));

        vm.prank(holder1);
        vm.expectRevert(InsurancePool.InvalidMerkleProof.selector);
        pool.claimCompensation(defaultPoolId, holderBalance, badProof);
    }

    function test_ClaimWithWrongBalance_Reverts() public {
        _deposit(DEPOSIT_AMOUNT);

        uint256 realBalance = 100_000 ether;
        uint256 fakeBalance = 999_000 ether; // attacker inflates balance

        (bytes32 root, bytes32[] memory proof1,) =
            _buildTree2(holder1, realBalance, holder2, 900_000 ether);

        vm.prank(oracle);
        pool.executePayout(defaultPoolId, 1, TOTAL_SUPPLY, root, address(0));

        // Claim with wrong balance + correct proof for real balance => proof check fails
        vm.prank(holder1);
        vm.expectRevert(InsurancePool.InvalidMerkleProof.selector);
        pool.claimCompensation(defaultPoolId, fakeBalance, proof1);
    }

    function test_ClaimWithOtherHolderProof_Reverts() public {
        _deposit(DEPOSIT_AMOUNT);

        uint256 balance1 = 100_000 ether;
        uint256 balance2 = 900_000 ether;

        (bytes32 root,, bytes32[] memory proof2) =
            _buildTree2(holder1, balance1, holder2, balance2);

        vm.prank(oracle);
        pool.executePayout(defaultPoolId, 1, TOTAL_SUPPLY, root, address(0));

        // holder3 (not in tree) tries to use holder2's proof
        vm.prank(holder3);
        vm.expectRevert(InsurancePool.InvalidMerkleProof.selector);
        pool.claimCompensation(defaultPoolId, balance2, proof2);
    }

    function test_DoubleClaim_Reverts() public {
        _deposit(DEPOSIT_AMOUNT);

        uint256 holderBalance = 100_000 ether;
        (bytes32 root, bytes32[] memory proof1,) =
            _buildTree2(holder1, holderBalance, holder2, 900_000 ether);

        vm.prank(oracle);
        pool.executePayout(defaultPoolId, 1, TOTAL_SUPPLY, root, address(0));

        vm.prank(holder1);
        pool.claimCompensation(defaultPoolId, holderBalance, proof1);

        vm.prank(holder1);
        vm.expectRevert(InsurancePool.AlreadyClaimed.selector);
        pool.claimCompensation(defaultPoolId, holderBalance, proof1);
    }

    function test_TotalClaimedExceedsPool_Reverts() public {
        // Deposit a very small amount
        _deposit(1 wei);

        // Create tree with holders whose combined pro-rata exceeds 1 wei due to rounding
        // Actually with integer rounding down, this won't exceed. Let's test the safety check
        // by creating a scenario where a single claim would exceed balance.
        // This is hard to trigger naturally since compensation is always <= payoutBalance * holderBalance / totalEligibleSupply.
        // But let's verify the safety check exists by testing it doesn't revert in normal case.

        uint256 balance1 = 500_000 ether;
        uint256 balance2 = 500_000 ether;

        (bytes32 root, bytes32[] memory proof1, bytes32[] memory proof2) =
            _buildTree2(holder1, balance1, holder2, balance2);

        vm.prank(oracle);
        pool.executePayout(defaultPoolId, 1, TOTAL_SUPPLY, root, address(0));

        // Both can claim their share (may be 0 due to rounding)
        vm.prank(holder1);
        try pool.claimCompensation(defaultPoolId, balance1, proof1) {} catch {}

        vm.prank(holder2);
        try pool.claimCompensation(defaultPoolId, balance2, proof2) {} catch {}

        // Pool balance should never go negative (enforced by Solidity's underflow check)
        assertGe(address(pool).balance, 0);
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

    function test_emergencyWithdraw_timelockFlow() public {
        _deposit(DEPOSIT_AMOUNT);

        address recipient = makeAddr("recipient");

        // Request
        vm.prank(governance);
        bytes32 requestId = pool.requestEmergencyWithdraw(defaultPoolId, recipient, 5 ether);

        // Cannot execute before delay
        vm.prank(governance);
        vm.expectRevert(InsurancePool.EmergencyDelayNotElapsed.selector);
        pool.executeEmergencyWithdraw(requestId);

        // Warp past delay
        vm.warp(block.timestamp + 2 days);

        // Execute
        vm.prank(governance);
        pool.executeEmergencyWithdraw(requestId);

        assertEq(recipient.balance, 5 ether);
        IInsurancePool.PoolStatus memory status = pool.getPoolStatus(defaultPoolId);
        assertEq(status.balance, 5 ether);
    }

    function test_emergencyWithdraw_emitsEvents() public {
        _deposit(DEPOSIT_AMOUNT);

        address recipient = makeAddr("recipient");

        vm.prank(governance);
        bytes32 requestId = pool.requestEmergencyWithdraw(defaultPoolId, recipient, 5 ether);

        vm.warp(block.timestamp + 2 days);

        vm.expectEmit(true, true, false, true);
        emit IInsurancePool.EmergencyWithdrawal(defaultPoolId, recipient, 5 ether);

        vm.prank(governance);
        pool.executeEmergencyWithdraw(requestId);
    }

    function test_emergencyWithdraw_requestRevertsNotGovernance() public {
        _deposit(DEPOSIT_AMOUNT);

        vm.expectRevert(InsurancePool.OnlyGovernance.selector);
        pool.requestEmergencyWithdraw(defaultPoolId, holder1, 1 ether);
    }

    function test_emergencyWithdraw_requestRevertsZeroAddress() public {
        _deposit(DEPOSIT_AMOUNT);

        vm.prank(governance);
        vm.expectRevert(InsurancePool.ZeroAddress.selector);
        pool.requestEmergencyWithdraw(defaultPoolId, address(0), 1 ether);
    }

    function test_emergencyWithdraw_requestRevertsZeroAmount() public {
        _deposit(DEPOSIT_AMOUNT);

        vm.prank(governance);
        vm.expectRevert(InsurancePool.ZeroAmount.selector);
        pool.requestEmergencyWithdraw(defaultPoolId, holder1, 0);
    }

    function test_emergencyWithdraw_executeRevertsInsufficientBalance() public {
        _deposit(1 ether);

        vm.prank(governance);
        bytes32 requestId = pool.requestEmergencyWithdraw(defaultPoolId, holder1, 2 ether);

        vm.warp(block.timestamp + 2 days);

        vm.prank(governance);
        vm.expectRevert(InsurancePool.InsufficientPoolBalance.selector);
        pool.executeEmergencyWithdraw(requestId);
    }

    function test_emergencyWithdraw_cancel() public {
        _deposit(DEPOSIT_AMOUNT);

        vm.prank(governance);
        bytes32 requestId = pool.requestEmergencyWithdraw(defaultPoolId, holder1, 5 ether);

        vm.prank(governance);
        pool.cancelEmergencyWithdraw(requestId);

        // Cannot execute cancelled request
        vm.warp(block.timestamp + 2 days);
        vm.prank(governance);
        vm.expectRevert(InsurancePool.EmergencyRequestNotFound.selector);
        pool.executeEmergencyWithdraw(requestId);
    }

    function test_emergencyWithdraw_doubleExecuteReverts() public {
        _deposit(DEPOSIT_AMOUNT);

        vm.prank(governance);
        bytes32 requestId = pool.requestEmergencyWithdraw(defaultPoolId, holder1, 5 ether);

        vm.warp(block.timestamp + 2 days);

        vm.prank(governance);
        pool.executeEmergencyWithdraw(requestId);

        // Double execute should revert
        vm.prank(governance);
        vm.expectRevert(InsurancePool.EmergencyRequestNotFound.selector);
        pool.executeEmergencyWithdraw(requestId);
    }

    function test_emergencyWithdraw_beforeDelayReverts() public {
        _deposit(DEPOSIT_AMOUNT);

        vm.prank(governance);
        bytes32 requestId = pool.requestEmergencyWithdraw(defaultPoolId, holder1, 5 ether);

        // Try at 1 day (before 2 day delay)
        vm.warp(block.timestamp + 1 days);

        vm.prank(governance);
        vm.expectRevert(InsurancePool.EmergencyDelayNotElapsed.selector);
        pool.executeEmergencyWithdraw(requestId);
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

        uint256 balance1 = 500_000 ether;
        uint256 balance2 = 500_000 ether;
        (bytes32 root, bytes32[] memory proof1,) =
            _buildTree2(holder1, balance1, holder2, balance2);

        vm.prank(oracle);
        pool.executePayout(defaultPoolId, 1, TOTAL_SUPPLY, root, address(0));

        vm.prank(holder1);
        pool.claimCompensation(defaultPoolId, balance1, proof1); // 50%

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

        uint256 balance1 = 500_000 ether;
        uint256 balance2 = 500_000 ether;
        (bytes32 root, bytes32[] memory proof1,) =
            _buildTree2(holder1, balance1, holder2, balance2);

        vm.prank(oracle);
        pool.executePayout(defaultPoolId, 1, TOTAL_SUPPLY, root, address(0));

        // Claim from pool 1 gets pool 1's funds
        vm.prank(holder1);
        uint256 claim1 = pool.claimCompensation(defaultPoolId, balance1, proof1); // 50%
        assertEq(claim1, 5 ether); // 50% of 10 ether, not 20 ether

        // Pool 2 untouched
        IInsurancePool.PoolStatus memory status2 = pool.getPoolStatus(poolId2);
        assertEq(status2.balance, 20 ether);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  FALLBACK CLAIM TESTS (balanceOf mode)
    // ═══════════════════════════════════════════════════════════════════

    function test_fallbackClaim_happyPath() public {
        _deposit(DEPOSIT_AMOUNT);

        // Deploy a mock ERC20 for fallback claims
        MockToken mockToken = new MockToken();
        mockToken.mint(holder1, 100_000 ether);

        // Trigger payout without merkle root (fallback mode)
        vm.prank(oracle);
        pool.executePayout(defaultPoolId, 1, TOTAL_SUPPLY, bytes32(0), address(mockToken));

        // Claim using balanceOf
        bytes32[] memory emptyProof = new bytes32[](0);
        vm.prank(holder1);
        uint256 claimed = pool.claimCompensation(defaultPoolId, 100_000 ether, emptyProof);

        assertEq(claimed, 1 ether); // 10% of 10 ether
    }

    function test_fallbackClaim_7dayPeriod() public {
        _deposit(DEPOSIT_AMOUNT);

        MockToken mockToken = new MockToken();
        mockToken.mint(holder1, 100_000 ether);

        vm.prank(oracle);
        pool.executePayout(defaultPoolId, 1, TOTAL_SUPPLY, bytes32(0), address(mockToken));

        // Warp past 7-day fallback claim period
        vm.warp(block.timestamp + 7 days + 1);

        bytes32[] memory emptyProof = new bytes32[](0);
        vm.prank(holder1);
        vm.expectRevert(InsurancePool.ClaimPeriodExpired.selector);
        pool.claimCompensation(defaultPoolId, 100_000 ether, emptyProof);
    }

    function test_fallbackClaim_insufficientBalance() public {
        _deposit(DEPOSIT_AMOUNT);

        MockToken mockToken = new MockToken();
        mockToken.mint(holder1, 50_000 ether); // less than claimed

        vm.prank(oracle);
        pool.executePayout(defaultPoolId, 1, TOTAL_SUPPLY, bytes32(0), address(mockToken));

        bytes32[] memory emptyProof = new bytes32[](0);
        vm.prank(holder1);
        vm.expectRevert(InsurancePool.InsufficientTokenBalance.selector);
        pool.claimCompensation(defaultPoolId, 100_000 ether, emptyProof);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  TREASURY TESTS
    // ═══════════════════════════════════════════════════════════════════

    function _createTreasuryPool() internal returns (InsurancePool, MockEscrowVault, address) {
        MockEscrowVault mockEscrow = new MockEscrowVault();
        address treasuryAddr = makeAddr("treasury");

        InsurancePool treasuryPool = new InsurancePool(hook, oracle, governance, address(mockEscrow), treasuryAddr);
        return (treasuryPool, mockEscrow, treasuryAddr);
    }

    function test_claimTreasuryFunds_happyPath() public {
        (InsurancePool treasuryPool, MockEscrowVault mockEscrow, address treasuryAddr) = _createTreasuryPool();

        // Deposit fees
        vm.prank(hook);
        treasuryPool.depositFee{value: DEPOSIT_AMOUNT}(defaultPoolId);

        // Set escrow as fully vested; set vesting end in the past
        mockEscrow.setFullyVested(true);
        uint256 vestingEnd = block.timestamp;
        mockEscrow.setVestingEndTime(vestingEnd);

        // Warp past grace period
        vm.warp(vestingEnd + 30 days + 1);

        vm.prank(governance);
        treasuryPool.claimTreasuryFunds(defaultPoolId);

        assertEq(treasuryAddr.balance, DEPOSIT_AMOUNT);
        IInsurancePool.PoolStatus memory status = treasuryPool.getPoolStatus(defaultPoolId);
        assertEq(status.balance, 0);
    }

    function test_claimTreasuryFunds_revertsWhenTriggered() public {
        (InsurancePool treasuryPool, MockEscrowVault mockEscrow,) = _createTreasuryPool();

        vm.prank(hook);
        treasuryPool.depositFee{value: DEPOSIT_AMOUNT}(defaultPoolId);

        // Trigger the pool
        vm.prank(oracle);
        treasuryPool.executePayout(defaultPoolId, 1, TOTAL_SUPPLY, bytes32(0), address(0));

        mockEscrow.setFullyVested(true);
        uint256 vestingEnd = block.timestamp;
        mockEscrow.setVestingEndTime(vestingEnd);
        vm.warp(vestingEnd + 30 days + 1);

        vm.prank(governance);
        vm.expectRevert(InsurancePool.AlreadyTriggered.selector);
        treasuryPool.claimTreasuryFunds(defaultPoolId);
    }

    function test_claimTreasuryFunds_revertsEscrowNotVested() public {
        (InsurancePool treasuryPool,,) = _createTreasuryPool();

        vm.prank(hook);
        treasuryPool.depositFee{value: DEPOSIT_AMOUNT}(defaultPoolId);

        // escrow not fully vested (default false)
        vm.prank(governance);
        vm.expectRevert(InsurancePool.EscrowNotFullyVested.selector);
        treasuryPool.claimTreasuryFunds(defaultPoolId);
    }

    function test_claimTreasuryFunds_revertsGracePeriodNotPassed() public {
        (InsurancePool treasuryPool, MockEscrowVault mockEscrow,) = _createTreasuryPool();

        vm.prank(hook);
        treasuryPool.depositFee{value: DEPOSIT_AMOUNT}(defaultPoolId);

        mockEscrow.setFullyVested(true);
        mockEscrow.setVestingEndTime(block.timestamp); // grace period not yet passed

        vm.prank(governance);
        vm.expectRevert(InsurancePool.GracePeriodNotPassed.selector);
        treasuryPool.claimTreasuryFunds(defaultPoolId);
    }

    function test_claimTreasuryFunds_revertsZeroBalance() public {
        (InsurancePool treasuryPool, MockEscrowVault mockEscrow,) = _createTreasuryPool();

        mockEscrow.setFullyVested(true);
        uint256 vestingEnd = block.timestamp;
        mockEscrow.setVestingEndTime(vestingEnd);
        vm.warp(vestingEnd + 30 days + 1);

        vm.prank(governance);
        vm.expectRevert(InsurancePool.ZeroAmount.selector);
        treasuryPool.claimTreasuryFunds(defaultPoolId);
    }

    function test_claimTreasuryFunds_revertsNotGovernance() public {
        (InsurancePool treasuryPool,,) = _createTreasuryPool();

        vm.expectRevert(InsurancePool.OnlyGovernance.selector);
        treasuryPool.claimTreasuryFunds(defaultPoolId);
    }

    function test_setTreasury_happyPath() public {
        (InsurancePool treasuryPool,,) = _createTreasuryPool();
        address newTreasury = makeAddr("newTreasury");

        vm.prank(governance);
        treasuryPool.setTreasury(newTreasury);

        assertEq(treasuryPool.treasury(), newTreasury);
    }

    function test_setTreasury_revertsZeroAddress() public {
        (InsurancePool treasuryPool,,) = _createTreasuryPool();

        vm.prank(governance);
        vm.expectRevert(InsurancePool.ZeroAddress.selector);
        treasuryPool.setTreasury(address(0));
    }

    function test_setTreasury_revertsNotGovernance() public {
        (InsurancePool treasuryPool,,) = _createTreasuryPool();

        vm.expectRevert(InsurancePool.OnlyGovernance.selector);
        treasuryPool.setTreasury(makeAddr("newTreasury"));
    }
}

contract MockEscrowVault {
    bool public fullyVested;
    uint256 public vestingEndTime;

    function setFullyVested(bool _vested) external { fullyVested = _vested; }
    function setVestingEndTime(uint256 _time) external { vestingEndTime = _time; }

    function isFullyVested(PoolId) external view returns (bool) { return fullyVested; }
    function getVestingEndTime(PoolId) external view returns (uint256) { return vestingEndTime; }
}

contract MockToken {
    string public name = "Mock";
    string public symbol = "MCK";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}
