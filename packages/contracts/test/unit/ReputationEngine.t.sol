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
        vm.prank(hook);
        engine.recordEvent(
            _issuer, IReputationEngine.EventType.POOL_CREATED, abi.encode(token, amount, c, uint256(0))
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

    // ─── 2. Pool Creation — No Score Increase ─────────────────────────

    function test_poolCreated_noScoreIncrease() public {
        uint256 before = engine.getScore(issuer);

        _recordPoolCreated(issuer, makeAddr("tokenA"), 100 ether, _defaultCommitment());

        uint256 after_ = engine.getScore(issuer);
        // Pool creation only sets firstEventAt → wallet age is ~0 at same timestamp
        assertEq(after_, 0, "Pool creation alone should give 0 score (no positive components)");
    }

    function test_spamPoolCreation_noScoreIncrease() public {
        // Create 50 spam pools — score should not increase
        for (uint256 i = 0; i < 50; i++) {
            _recordPoolCreated(
                issuer,
                makeAddr(string(abi.encode("spam", i))),
                1 ether,
                _defaultCommitment()
            );
        }

        uint256 score = engine.getScore(issuer);
        assertEq(score, 0, "50 spam pools should not increase score");
    }

    function test_spamPoolCreation_dilutesVestingScore() public {
        // Create 1 pool and complete it → vesting ratio 1/1 = 300
        _recordPoolCreated(issuer, makeAddr("legit"), 100 ether, _strictCommitment());
        _recordEscrowCompleted(issuer, 100 ether, 365);
        vm.warp(block.timestamp + 365 days);
        uint256 scoreWith1Pool = engine.getScore(issuer);

        // Now create 9 spam pools → vesting ratio drops to 1/10 = 30
        for (uint256 i = 0; i < 9; i++) {
            _recordPoolCreated(issuer, makeAddr(string(abi.encode("spam", i))), 1 ether, _defaultCommitment());
        }
        uint256 scoreWith10Pools = engine.getScore(issuer);

        assertLt(scoreWith10Pools, scoreWith1Pool, "Spam pools should dilute vesting score");
    }

    // ─── 3. Escrow Completion ─────────────────────────────────────────

    function test_escrowCompleted_increasesVestingScore() public {
        _recordPoolCreated(issuer, makeAddr("tokenA"), 100 ether, _defaultCommitment());
        uint256 scoreBefore = engine.getScore(issuer);

        _recordEscrowCompleted(issuer, 100 ether, 180);
        uint256 scoreAfter = engine.getScore(issuer);

        assertGt(scoreAfter, scoreBefore, "Escrow completion should increase score");
    }

    function test_escrowCompleted_allEscrowsCompleted_maxVesting() public {
        _recordPoolCreated(issuer, makeAddr("tokenA"), 100 ether, _defaultCommitment());
        _recordPoolCreated(issuer, makeAddr("tokenB"), 100 ether, _defaultCommitment());

        _recordEscrowCompleted(issuer, 100 ether, 180);
        _recordEscrowCompleted(issuer, 100 ether, 180);

        uint256 score = engine.getScore(issuer);
        // 2/2 completed → vesting = 500, plus escrow history contribution
        assertGt(score, 500, "Full completion should contribute max vesting score");
    }

    function test_escrowCompleted_afterSpam_stillEarnsScore() public {
        // Spammer creates 100 pools
        for (uint256 i = 0; i < 100; i++) {
            _recordPoolCreated(issuer, makeAddr(string(abi.encode("s", i))), 1 ether, _defaultCommitment());
        }
        uint256 scoreBeforeComplete = engine.getScore(issuer);

        // Complete 1 escrow — should still earn SOME score (vesting 1/100 * 300 = 3)
        _recordEscrowCompleted(issuer, 100 ether, 365);
        uint256 scoreAfterComplete = engine.getScore(issuer);

        assertGt(scoreAfterComplete, scoreBeforeComplete, "Escrow completion should increase score even after spam");
        assertLt(scoreAfterComplete, 50, "Score should be low due to terrible vesting ratio");
    }

    // ─── 4. Trigger Deduction ─────────────────────────────────────────

    function test_triggerFired_decreasesScore() public {
        _recordPoolCreated(issuer, makeAddr("tokenA"), 100 ether, _strictCommitment());
        _recordEscrowCompleted(issuer, 100 ether, 365);
        _recordCommitmentHonored(issuer, _strictCommitment());
        uint256 scoreBefore = engine.getScore(issuer);

        _recordTriggerFired(issuer, 1); // RUG_PULL
        uint256 scoreAfter = engine.getScore(issuer);

        assertLt(scoreAfter, scoreBefore, "Trigger should decrease score");
    }

    function test_triggerFired_severePenalty100() public {
        _recordPoolCreated(issuer, makeAddr("tokenA"), 100 ether, _strictCommitment());
        _recordCommitmentHonored(issuer, _strictCommitment());
        vm.warp(block.timestamp + 365 days);
        uint256 scoreBefore = engine.getScore(issuer);

        _recordTriggerFired(issuer, 1); // RUG_PULL → -100
        uint256 scoreAfter = engine.getScore(issuer);

        assertEq(scoreBefore - scoreAfter, 100, "Severe trigger should deduct 100 points");
    }

    function test_triggerFired_nonSeverePenalty50() public {
        _recordPoolCreated(issuer, makeAddr("tokenA"), 100 ether, _strictCommitment());
        _recordCommitmentHonored(issuer, _strictCommitment());
        vm.warp(block.timestamp + 365 days);
        uint256 scoreBefore = engine.getScore(issuer);

        _recordTriggerFired(issuer, 3); // HONEYPOT → -50
        uint256 scoreAfter = engine.getScore(issuer);

        assertEq(scoreBefore - scoreAfter, 50, "Non-severe trigger should deduct 50 points");
    }

    function test_triggerFired_multipleTriggers_cappedAt500() public {
        // Build high score via escrow completions and commitments
        for (uint256 i = 1; i <= 5; i++) {
            _recordPoolCreated(issuer, makeAddr(string(abi.encode("t", i))), 100 ether, _strictCommitment());
            _recordEscrowCompleted(issuer, 100 ether, 365);
            _recordCommitmentHonored(issuer, _strictCommitment());
        }
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
        _recordPoolCreated(issuer, makeAddr("tokenA"), 1 ether, _defaultCommitment());

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

    // ─── 7. Composite ─────────────────────────────────────────────────

    function test_composite_realisticIssuer() public {
        // Create 3 pools and complete 2 escrows
        _recordPoolCreated(issuer, makeAddr("tokenA"), 200 ether, _strictCommitment());
        _recordPoolCreated(issuer, makeAddr("tokenB"), 150 ether, _strictCommitment());
        _recordPoolCreated(issuer, makeAddr("tokenC"), 100 ether, _strictCommitment());

        _recordEscrowCompleted(issuer, 200 ether, 365);
        _recordEscrowCompleted(issuer, 150 ether, 365);

        // Honor commitments
        _recordCommitmentHonored(issuer, _strictCommitment());
        _recordCommitmentHonored(issuer, _strictCommitment());

        vm.warp(block.timestamp + 200 days);

        // One minor trigger
        _recordTriggerFired(issuer, 3); // HONEYPOT → -50

        uint256 score = engine.getScore(issuer);
        assertGt(score, 200, "Composite score should be meaningful");
        assertLt(score, 1000, "Composite score should not be max with partial completion + trigger");
    }

    // ─── 8. Access Control ────────────────────────────────────────────

    function test_recordEvent_revertsUnauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert(ReputationEngine.Unauthorized.selector);
        engine.recordEvent(issuer, IReputationEngine.EventType.POOL_CREATED, "");
    }

    function test_recordEvent_allowsHook() public {
        _recordPoolCreated(issuer, makeAddr("token"), 100 ether, _defaultCommitment());
    }

    function test_recordEvent_allowsEscrowVault() public {
        vm.prank(escrowVault);
        engine.recordEvent(
            issuer, IReputationEngine.EventType.ESCROW_COMPLETED, abi.encode(uint256(100 ether), uint256(30))
        );
    }

    function test_recordEvent_allowsTriggerOracle() public {
        _recordPoolCreated(issuer, makeAddr("tokenA"), 100 ether, _defaultCommitment());

        vm.prank(triggerOracle);
        engine.recordEvent(issuer, IReputationEngine.EventType.TRIGGER_FIRED, abi.encode(uint8(3)));
    }

    // ─── 9. Cross-chain Encode/Decode ────────────────────────────────

    function test_crossChain_encodeDecodeRoundtrip() public {
        _recordPoolCreated(issuer, makeAddr("tokenA"), 100 ether, _defaultCommitment());
        _recordPoolCreated(issuer, makeAddr("tokenB"), 100 ether, _defaultCommitment());
        _recordEscrowCompleted(issuer, 100 ether, 180);
        _recordTriggerFired(issuer, 3);

        bytes memory encoded = engine.encodeScoreData(issuer);
        (uint256 score, uint16 poolsCreated, uint16 escrowsCompleted, uint16 triggerCount) =
            engine.decodeScoreData(encoded);

        assertEq(score, engine.getScore(issuer), "Decoded score should match getScore");
        assertEq(poolsCreated, 2, "Should have 2 pools");
        assertEq(escrowsCompleted, 1, "Should have 1 escrow completed");
        assertEq(triggerCount, 1, "Should have 1 trigger");
    }

    // ─── 10. Edge Cases ───────────────────────────────────────────────

    function test_edge_scoreClampedAtZero() public {
        _recordPoolCreated(issuer, makeAddr("tokenA"), 1 ether, _defaultCommitment());
        _recordTriggerFired(issuer, 1);
        _recordTriggerFired(issuer, 1);
        _recordTriggerFired(issuer, 1);
        _recordTriggerFired(issuer, 2);
        _recordTriggerFired(issuer, 2);

        uint256 score = engine.getScore(issuer);
        assertEq(score, 0, "Score should be clamped at 0");
    }

    function test_edge_scoreClampedAt1000() public {
        IEscrowVault.IssuerCommitment memory maxStrict = IEscrowVault.IssuerCommitment({
            dailyWithdrawLimit: 0,
            maxSellPercent: 0
        });

        // Build maximum score via completions + commitments (no diversity/pool-creation bonus)
        for (uint256 i = 1; i <= 5; i++) {
            _recordPoolCreated(issuer, makeAddr(string(abi.encode("t", i))), 500_000e18, maxStrict);
            _recordEscrowCompleted(issuer, 500_000e18, 365);
            _recordCommitmentHonored(issuer, maxStrict);
        }
        vm.warp(block.timestamp + 730 days);

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
        _recordCommitmentHonored(issuer, _strictCommitment());
        vm.warp(block.timestamp + 365 days);
        uint256 scoreBefore = engine.getScore(issuer);

        _recordCommitmentViolated(issuer, 1); // RUG_PULL type
        uint256 scoreAfter = engine.getScore(issuer);

        assertLt(scoreAfter, scoreBefore, "Commitment violation should decrease score");
        assertEq(scoreBefore - scoreAfter, 100, "Severe commitment violation should deduct 100");
    }

    function test_edge_multipleIssuersIndependent() public {
        address issuerB = makeAddr("issuerB");

        _recordPoolCreated(issuer, makeAddr("tokenA"), 100 ether, _strictCommitment());
        _recordCommitmentHonored(issuer, _strictCommitment());
        _recordTriggerFired(issuerB, 1);

        uint256 scoreA = engine.getScore(issuer);
        uint256 scoreB = engine.getScore(issuerB);

        assertGt(scoreA, scoreB, "Issuers should have independent scores");
    }
}
