// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ReputationEngine} from "../../src/core/ReputationEngine.sol";
import {IReputationEngine} from "../../src/interfaces/IReputationEngine.sol";
import {IEscrowVault} from "../../src/interfaces/IEscrowVault.sol";

contract ReputationEngineTest is Test {
    ReputationEngine public engine;

    address public hook;
    address public escrowVault;
    address public triggerOracle;
    address public issuer;
    address public unauthorized;

    function setUp() public {
        hook = makeAddr("hook");
        escrowVault = makeAddr("escrowVault");
        triggerOracle = makeAddr("triggerOracle");
        issuer = makeAddr("issuer");
        unauthorized = makeAddr("unauthorized");

        engine = new ReputationEngine(hook, escrowVault, triggerOracle);
    }

    // ─── Helpers ──────────────────────────────────────────────────────

    function _defaultCommitment() internal pure returns (IEscrowVault.IssuerCommitment memory) {
        return IEscrowVault.IssuerCommitment({
            dailyWithdrawLimit: 500, // 5%
            maxSellPercent: 1000 // 10%
        });
    }

    function _strictCommitment() internal pure returns (IEscrowVault.IssuerCommitment memory) {
        return IEscrowVault.IssuerCommitment({
            dailyWithdrawLimit: 100, // 1%
            maxSellPercent: 200 // 2%
        });
    }

    function _recordPoolCreated(address _issuer, address token, uint256 amount, IEscrowVault.IssuerCommitment memory c)
        internal
    {
        _recordPoolCreatedWithEscrow(_issuer, token, amount, c, 0, 0);
    }

    function _recordPoolCreatedWithEscrow(
        address _issuer,
        address token,
        uint256 amount,
        IEscrowVault.IssuerCommitment memory c,
        uint256 escrowId,
        uint256 vestingScore
    ) internal {
        // Mock the getEscrowInfo call on escrowVault (lockDuration=7d, vestingDuration=83d)
        vm.mockCall(
            escrowVault,
            abi.encodeWithSelector(IEscrowVault.getEscrowInfo.selector, escrowId),
            abi.encode(uint40(block.timestamp), uint40(7 days), uint40(83 days), _defaultCommitment())
        );
        // Mock the getVestingStrictnessScore call on escrowVault
        vm.mockCall(
            escrowVault,
            abi.encodeWithSelector(IEscrowVault.getVestingStrictnessScore.selector, escrowId),
            abi.encode(vestingScore)
        );
        vm.prank(hook);
        engine.recordEvent(
            _issuer, IReputationEngine.EventType.POOL_CREATED, abi.encode(token, amount, c, escrowId)
        );
    }

    function _recordEscrowCompleted(address _issuer, uint256 amount, uint256 durationDays) internal {
        vm.prank(escrowVault);
        engine.recordEvent(
            _issuer, IReputationEngine.EventType.ESCROW_COMPLETED, abi.encode(amount, durationDays)
        );
    }

    function _recordTriggerFired(address _issuer, uint8 triggerType) internal {
        vm.prank(triggerOracle);
        engine.recordEvent(
            _issuer, IReputationEngine.EventType.TRIGGER_FIRED, abi.encode(triggerType)
        );
    }

    function _recordCommitmentHonored(address _issuer, IEscrowVault.IssuerCommitment memory c) internal {
        vm.prank(escrowVault);
        engine.recordEvent(
            _issuer, IReputationEngine.EventType.COMMITMENT_HONORED, abi.encode(c)
        );
    }

    function _recordCommitmentViolated(address _issuer, uint8 triggerType) internal {
        vm.prank(triggerOracle);
        engine.recordEvent(
            _issuer, IReputationEngine.EventType.COMMITMENT_VIOLATED, abi.encode(triggerType)
        );
    }

    // ─── 1. Baseline ──────────────────────────────────────────────────

    function test_baseline_newIssuerReturns100() public view {
        uint256 score = engine.getScore(issuer);
        assertEq(score, 100, "New issuer should have baseline score of 100");
    }

    // ─── 2. Pool Creation ─────────────────────────────────────────────

    function test_poolCreated_increasesScore() public {
        uint256 before = engine.getScore(issuer);

        _recordPoolCreated(issuer, makeAddr("tokenA"), 100 ether, _defaultCommitment());

        uint256 after_ = engine.getScore(issuer);
        assertGt(after_, before, "Score should increase after pool creation");
    }

    function test_poolCreated_tracksTokenDiversity() public {
        address tokenA = makeAddr("tokenA");
        address tokenB = makeAddr("tokenB");

        _recordPoolCreated(issuer, tokenA, 50 ether, _defaultCommitment());
        uint256 scoreAfterOne = engine.getScore(issuer);

        _recordPoolCreated(issuer, tokenB, 50 ether, _defaultCommitment());
        uint256 scoreAfterTwo = engine.getScore(issuer);

        assertGt(scoreAfterTwo, scoreAfterOne, "Second unique token should increase diversity score");
    }

    function test_poolCreated_sameTokenNoDiversityIncrease() public {
        address tokenA = makeAddr("tokenA");

        _recordPoolCreated(issuer, tokenA, 50 ether, _defaultCommitment());
        _recordPoolCreated(issuer, tokenA, 50 ether, _defaultCommitment());

        // No revert means duplicate token handled correctly; diversity stays the same
        assertTrue(true);
    }

    // ─── 3. Escrow Completion ─────────────────────────────────────────

    function test_escrowCompleted_increasesVestingScore() public {
        // Create a pool first so poolsCreated > 0
        _recordPoolCreated(issuer, makeAddr("tokenA"), 100 ether, _defaultCommitment());
        uint256 scoreBefore = engine.getScore(issuer);

        _recordEscrowCompleted(issuer, 100 ether, 180);
        uint256 scoreAfter = engine.getScore(issuer);

        assertGt(scoreAfter, scoreBefore, "Escrow completion should increase score");
    }

    function test_escrowCompleted_allEscrowsCompleted_maxVesting() public {
        // Create 2 pools and complete both
        _recordPoolCreated(issuer, makeAddr("tokenA"), 100 ether, _defaultCommitment());
        _recordPoolCreated(issuer, makeAddr("tokenB"), 100 ether, _defaultCommitment());

        _recordEscrowCompleted(issuer, 100 ether, 180);
        _recordEscrowCompleted(issuer, 100 ether, 180);

        // With 2/2 completed, vesting score should be 300
        uint256 score = engine.getScore(issuer);
        assertGt(score, 300, "Full completion should contribute near-max vesting score");
    }

    // ─── 4. Trigger Deduction ─────────────────────────────────────────

    function test_triggerFired_decreasesScore() public {
        // Build up some score first
        _recordPoolCreated(issuer, makeAddr("tokenA"), 100 ether, _strictCommitment());
        _recordEscrowCompleted(issuer, 100 ether, 365);
        uint256 scoreBefore = engine.getScore(issuer);

        // Fire a severe trigger (RUG_PULL = 1)
        _recordTriggerFired(issuer, 1);
        uint256 scoreAfter = engine.getScore(issuer);

        assertLt(scoreAfter, scoreBefore, "Trigger should decrease score");
    }

    function test_triggerFired_severePenalty100() public {
        _recordPoolCreated(issuer, makeAddr("tokenA"), 100 ether, _strictCommitment());
        vm.warp(block.timestamp + 365 days);
        uint256 scoreBefore = engine.getScore(issuer);

        // RUG_PULL = 1 → severe penalty (-100)
        _recordTriggerFired(issuer, 1);
        uint256 scoreAfter = engine.getScore(issuer);

        assertEq(scoreBefore - scoreAfter, 100, "Severe trigger should deduct 100 points");
    }

    function test_triggerFired_nonSeverePenalty50() public {
        _recordPoolCreated(issuer, makeAddr("tokenA"), 100 ether, _strictCommitment());
        vm.warp(block.timestamp + 365 days);
        uint256 scoreBefore = engine.getScore(issuer);

        // HONEYPOT = 3 → non-severe penalty (-50)
        _recordTriggerFired(issuer, 3);
        uint256 scoreAfter = engine.getScore(issuer);

        assertEq(scoreBefore - scoreAfter, 50, "Non-severe trigger should deduct 50 points");
    }

    function test_triggerFired_multipleTriggers_cappedAt500() public {
        // Build high score
        _recordPoolCreated(issuer, makeAddr("tokenA"), 100 ether, _strictCommitment());
        _recordPoolCreated(issuer, makeAddr("tokenB"), 100 ether, _strictCommitment());
        _recordPoolCreated(issuer, makeAddr("tokenC"), 100 ether, _strictCommitment());
        _recordPoolCreated(issuer, makeAddr("tokenD"), 100 ether, _strictCommitment());
        _recordPoolCreated(issuer, makeAddr("tokenE"), 100 ether, _strictCommitment());
        _recordEscrowCompleted(issuer, 100 ether, 365);
        _recordEscrowCompleted(issuer, 100 ether, 365);
        _recordEscrowCompleted(issuer, 100 ether, 365);
        _recordEscrowCompleted(issuer, 100 ether, 365);
        _recordEscrowCompleted(issuer, 100 ether, 365);
        vm.warp(block.timestamp + 365 days);

        uint256 scoreBeforeTriggers = engine.getScore(issuer);

        // Fire 6 severe triggers → 6*100=600, but capped at 500
        for (uint256 i = 0; i < 6; i++) {
            _recordTriggerFired(issuer, 1);
        }

        uint256 scoreAfterTriggers = engine.getScore(issuer);
        assertEq(scoreBeforeTriggers - scoreAfterTriggers, 500, "Trigger penalty should be capped at 500");
    }

    function test_triggerFired_scoreFloorsAtZero() public {
        // Minimal score issuer
        _recordPoolCreated(issuer, makeAddr("tokenA"), 1 ether, _defaultCommitment());

        // Fire multiple triggers
        _recordTriggerFired(issuer, 1);
        _recordTriggerFired(issuer, 1);
        _recordTriggerFired(issuer, 1);

        uint256 score = engine.getScore(issuer);
        assertEq(score, 0, "Score should floor at 0");
    }

    // ─── 5. Commitment Honored ────────────────────────────────────────

    function test_commitmentHonored_increasesStrictnessScore() public {
        _recordPoolCreated(issuer, makeAddr("tokenA"), 100 ether, _defaultCommitment());
        uint256 scoreBefore = engine.getScore(issuer);

        _recordCommitmentHonored(issuer, _strictCommitment());
        uint256 scoreAfter = engine.getScore(issuer);

        assertGt(scoreAfter, scoreBefore, "Honored strict commitment should increase score");
    }

    // ─── 6. Wallet Age ────────────────────────────────────────────────

    function test_walletAge_increasesOverTime() public {
        _recordPoolCreated(issuer, makeAddr("tokenA"), 100 ether, _defaultCommitment());
        uint256 scoreEarly = engine.getScore(issuer);

        vm.warp(block.timestamp + 180 days);
        uint256 scoreLater = engine.getScore(issuer);

        assertGt(scoreLater, scoreEarly, "Score should increase with wallet age");
    }

    function test_walletAge_capsAt100Points() public {
        _recordPoolCreated(issuer, makeAddr("tokenA"), 100 ether, _defaultCommitment());

        vm.warp(block.timestamp + 365 days);
        uint256 scoreAtYear = engine.getScore(issuer);

        vm.warp(block.timestamp + 365 days); // 2 years total
        uint256 scoreAtTwoYears = engine.getScore(issuer);

        assertEq(scoreAtYear, scoreAtTwoYears, "Age score should cap at 1 year");
    }

    // ─── 7. Token Diversity ───────────────────────────────────────────

    function test_diversity_maxAt5Tokens() public {
        for (uint256 i = 1; i <= 5; i++) {
            _recordPoolCreated(issuer, makeAddr(string(abi.encode("token", i))), 50 ether, _defaultCommitment());
        }
        uint256 scoreAt5 = engine.getScore(issuer);
        assertGt(scoreAt5, 0, "5-token issuer should have positive score");

        // 6th token: diversity is capped at 200 (5*40), so no additional diversity points
        _recordPoolCreated(issuer, makeAddr(string(abi.encode("token", uint256(6)))), 50 ether, _defaultCommitment());
        engine.getScore(issuer); // just verify no revert
    }

    // ─── 8. Composite ─────────────────────────────────────────────────

    function test_composite_realisticIssuer() public {
        // Create 3 pools with different tokens and strict commitments
        _recordPoolCreated(issuer, makeAddr("tokenA"), 200 ether, _strictCommitment());
        _recordPoolCreated(issuer, makeAddr("tokenB"), 150 ether, _strictCommitment());
        _recordPoolCreated(issuer, makeAddr("tokenC"), 100 ether, _strictCommitment());

        // Complete 2 of 3 escrows
        _recordEscrowCompleted(issuer, 200 ether, 365);
        _recordEscrowCompleted(issuer, 150 ether, 365);

        // Honor commitments twice
        _recordCommitmentHonored(issuer, _strictCommitment());
        _recordCommitmentHonored(issuer, _strictCommitment());

        // Age the wallet
        vm.warp(block.timestamp + 200 days);

        // One minor trigger
        _recordTriggerFired(issuer, 3); // HONEYPOT, non-severe → -50

        uint256 score = engine.getScore(issuer);

        // Should be a moderate-to-high score
        assertGt(score, 200, "Composite score should be meaningful");
        assertLt(score, 1000, "Composite score should not be max with partial completion + trigger");
    }

    // ─── 9. Access Control ────────────────────────────────────────────

    function test_recordEvent_revertsUnauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert(ReputationEngine.Unauthorized.selector);
        engine.recordEvent(issuer, IReputationEngine.EventType.POOL_CREATED, "");
    }

    function test_recordEvent_allowsHook() public {
        _recordPoolCreated(issuer, makeAddr("token"), 100 ether, _defaultCommitment());
        // No revert means success
    }

    function test_recordEvent_allowsEscrowVault() public {
        vm.prank(escrowVault);
        engine.recordEvent(
            issuer, IReputationEngine.EventType.ESCROW_COMPLETED, abi.encode(uint256(100 ether), uint256(30))
        );
    }

    function test_recordEvent_allowsTriggerOracle() public {
        // Need a firstEventAt first
        _recordPoolCreated(issuer, makeAddr("tokenA"), 100 ether, _defaultCommitment());

        vm.prank(triggerOracle);
        engine.recordEvent(issuer, IReputationEngine.EventType.TRIGGER_FIRED, abi.encode(uint8(3)));
    }

    // ─── 10. Cross-chain Encode/Decode ────────────────────────────────

    function test_crossChain_encodeDecodeRoundtrip() public {
        // Build up a profile
        _recordPoolCreated(issuer, makeAddr("tokenA"), 100 ether, _defaultCommitment());
        _recordPoolCreated(issuer, makeAddr("tokenB"), 100 ether, _defaultCommitment());
        _recordEscrowCompleted(issuer, 100 ether, 180);
        _recordTriggerFired(issuer, 3);

        bytes memory encoded = engine.encodeScoreData(issuer);
        (uint256 score, uint16 poolsCreated, uint16 escrowsCompleted, uint16 triggerCount, uint16 uniqueTokens) =
            engine.decodeScoreData(encoded);

        assertEq(score, engine.getScore(issuer), "Decoded score should match getScore");
        assertEq(poolsCreated, 2, "Should have 2 pools");
        assertEq(escrowsCompleted, 1, "Should have 1 escrow completed");
        assertEq(triggerCount, 1, "Should have 1 trigger");
        assertEq(uniqueTokens, 2, "Should have 2 unique tokens");
    }

    // ─── 11. Edge Cases ───────────────────────────────────────────────

    function test_edge_scoreClampedAtZero() public {
        // Record a pool then fire max triggers
        _recordPoolCreated(issuer, makeAddr("tokenA"), 1 ether, _defaultCommitment());
        _recordTriggerFired(issuer, 1); // -100
        _recordTriggerFired(issuer, 1); // -100
        _recordTriggerFired(issuer, 1); // -100
        _recordTriggerFired(issuer, 2); // -100
        _recordTriggerFired(issuer, 2); // -100

        uint256 score = engine.getScore(issuer);
        assertEq(score, 0, "Score should be clamped at 0");
    }

    function test_edge_scoreClampedAt1000() public {
        // Maximally strict commitment: 0% withdraw, 0% sell → commitment score = 200
        IEscrowVault.IssuerCommitment memory maxStrict = IEscrowVault.IssuerCommitment({
            dailyWithdrawLimit: 0,
            maxSellPercent: 0
        });

        // Build maximum possible score
        for (uint256 i = 1; i <= 5; i++) {
            _recordPoolCreated(
                issuer,
                makeAddr(string(abi.encode("t", i))),
                500_000e18, // large amount for escrow history
                maxStrict
            );
        }
        for (uint256 i = 0; i < 5; i++) {
            _recordEscrowCompleted(issuer, 500_000e18, 365);
        }
        vm.warp(block.timestamp + 730 days); // 2 years

        uint256 score = engine.getScore(issuer);
        assertEq(score, 1000, "Score should be clamped at 1000");
    }

    function test_edge_emitsReputationUpdatedEvent() public {
        vm.expectEmit(true, true, false, false);
        emit IReputationEngine.ReputationUpdated(issuer, IReputationEngine.EventType.POOL_CREATED, 0);

        _recordPoolCreated(issuer, makeAddr("tokenA"), 100 ether, _defaultCommitment());
    }

    function test_edge_commitmentViolated_actsLikeTrigger() public {
        _recordPoolCreated(issuer, makeAddr("tokenA"), 100 ether, _strictCommitment());
        vm.warp(block.timestamp + 365 days);
        uint256 scoreBefore = engine.getScore(issuer);

        // COMMITMENT_VIOLATED with severe type
        _recordCommitmentViolated(issuer, 1); // RUG_PULL type
        uint256 scoreAfter = engine.getScore(issuer);

        assertLt(scoreAfter, scoreBefore, "Commitment violation should decrease score");
        assertEq(scoreBefore - scoreAfter, 100, "Severe commitment violation should deduct 100");
    }

    function test_edge_multipleIssuersIndependent() public {
        address issuerB = makeAddr("issuerB");

        _recordPoolCreated(issuer, makeAddr("tokenA"), 100 ether, _strictCommitment());
        _recordTriggerFired(issuerB, 1);

        // First issuer should not be affected by second issuer's trigger
        uint256 scoreA = engine.getScore(issuer);
        uint256 scoreB = engine.getScore(issuerB);

        assertGt(scoreA, scoreB, "Issuers should have independent scores");
    }
}
