// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.26;

import {IReputationEngine} from "../interfaces/IReputationEngine.sol";
import {IEscrowVault} from "../interfaces/IEscrowVault.sol";


/// @title ReputationEngine
/// @notice Tracks and computes on-chain reputation scores (0–1000) for token issuers.
///         Scores are informational only — displayed on frontend dashboards, never blocking transactions.
contract ReputationEngine is IReputationEngine {
    // ─── Constants ───────────────────────────────────────────────────

    /// @notice Baseline score for issuers with no recorded events
    uint256 public constant BASELINE_SCORE = 100;

    /// @notice Scale factor for escrow history: weighted sum (token-units * days) needed for max 200 points
    uint256 public constant ESCROW_HISTORY_SCALE = 1_000_000;

    /// @notice Scale for wallet age: seconds per point (365 days / 100 points ≈ 3.65 days)
    uint256 public constant AGE_SCALE = 365 days / 100;

    /// @notice Maximum basis points (100%)
    uint256 private constant MAX_BPS = 10_000;

    // ─── Structs ─────────────────────────────────────────────────────

    struct IssuerProfile {
        uint40 firstEventAt;
        uint16 poolsCreated;
        uint16 escrowsCompleted;
        uint16 triggerCount;
        uint16 severeTriggerCount;
        uint16 commitmentCount;
        uint256 totalLockedWeighted;
        uint256 commitmentScore;
    }

    // ─── Immutables ──────────────────────────────────────────────────

    address public immutable BASTION_HOOK;
    address public immutable ESCROW_VAULT;
    address public immutable TRIGGER_ORACLE;

    // ─── Storage ─────────────────────────────────────────────────────

    mapping(address => IssuerProfile) internal _profiles;

    // ─── Errors ──────────────────────────────────────────────────────

    error Unauthorized();

    // ─── Modifiers ───────────────────────────────────────────────────

    modifier onlyAuthorized() {
        if (msg.sender != BASTION_HOOK && msg.sender != ESCROW_VAULT && msg.sender != TRIGGER_ORACLE) {
            revert Unauthorized();
        }
        _;
    }

    // ─── Constructor ─────────────────────────────────────────────────

    constructor(address bastionHook, address escrowVault, address triggerOracle) {
        BASTION_HOOK = bastionHook;
        ESCROW_VAULT = escrowVault;
        TRIGGER_ORACLE = triggerOracle;
    }

    // ─── External Functions ──────────────────────────────────────────

    /// @inheritdoc IReputationEngine
    function recordEvent(address issuer, EventType eventType, bytes calldata data) external onlyAuthorized {
        IssuerProfile storage profile = _profiles[issuer];

        // Initialize first event timestamp
        if (profile.firstEventAt == 0) {
            profile.firstEventAt = uint40(block.timestamp);
        }

        if (eventType == EventType.POOL_CREATED) {
            _handlePoolCreated(issuer, profile, data);
        } else if (eventType == EventType.ESCROW_COMPLETED) {
            _handleEscrowCompleted(profile, data);
        } else if (eventType == EventType.TRIGGER_FIRED) {
            _handleTriggerFired(profile, data);
        } else if (eventType == EventType.COMMITMENT_HONORED) {
            _handleCommitmentHonored(profile, data);
        } else if (eventType == EventType.COMMITMENT_VIOLATED) {
            _handleCommitmentViolated(profile, data);
        }

        emit ReputationUpdated(issuer, eventType, getScore(issuer));
    }

    /// @inheritdoc IReputationEngine
    function getScore(address issuer) public view returns (uint256 score) {
        IssuerProfile storage profile = _profiles[issuer];

        // New issuer with no events
        if (profile.firstEventAt == 0) {
            return BASELINE_SCORE;
        }

        uint256 positive = BASELINE_SCORE + _calcVestingScore(profile) + _calcEscrowHistoryScore(profile)
            + _calcCommitmentScore(profile) + _calcWalletAgeScore(profile);

        uint256 penalty = _calcTriggerPenalty(profile);

        if (positive > penalty) {
            score = positive - penalty;
        }
        // else score = 0 (default)

        if (score > 1000) {
            score = 1000;
        }
    }

    /// @inheritdoc IReputationEngine
    function encodeScoreData(address issuer) external view returns (bytes memory) {
        IssuerProfile storage profile = _profiles[issuer];
        return abi.encode(
            getScore(issuer),
            profile.poolsCreated,
            profile.escrowsCompleted,
            profile.triggerCount
        );
    }

    /// @inheritdoc IReputationEngine
    function decodeScoreData(bytes calldata data)
        external
        pure
        returns (uint256 score, uint16 poolsCreated, uint16 escrowsCompleted, uint16 triggerCount)
    {
        (score, poolsCreated, escrowsCompleted, triggerCount) =
            abi.decode(data, (uint256, uint16, uint16, uint16));
    }

    // ─── Event Handlers ──────────────────────────────────────────────

    /// @dev Pool creation only increments the pool counter (used as vesting ratio denominator).
    ///      No score increase — prevents reputation manipulation via spam pool creation.
    function _handlePoolCreated(address, IssuerProfile storage profile, bytes calldata) internal {
        profile.poolsCreated++;
    }

    function _handleEscrowCompleted(IssuerProfile storage profile, bytes calldata data) internal {
        (uint256 amount, uint256 durationDays) = abi.decode(data, (uint256, uint256));

        profile.escrowsCompleted++;
        profile.totalLockedWeighted += (amount * durationDays) / 1e18;
    }

    function _handleTriggerFired(IssuerProfile storage profile, bytes calldata data) internal {
        uint8 triggerType = abi.decode(data, (uint8));

        profile.triggerCount++;

        // RUG_PULL = 1, ISSUER_DUMP = 2 in TriggerType enum
        if (triggerType == 1 || triggerType == 2) {
            profile.severeTriggerCount++;
        }
    }

    function _handleCommitmentHonored(IssuerProfile storage profile, bytes calldata data) internal {
        IEscrowVault.IssuerCommitment memory commitment = abi.decode(data, (IEscrowVault.IssuerCommitment));

        profile.commitmentScore += _calcSingleCommitmentStrictness(commitment);
        profile.commitmentCount++;
    }

    function _handleCommitmentViolated(IssuerProfile storage profile, bytes calldata data) internal {
        uint8 triggerType = abi.decode(data, (uint8));

        profile.triggerCount++;

        if (triggerType == 1 || triggerType == 2) {
            profile.severeTriggerCount++;
        }
    }

    // ─── Score Computation Helpers ───────────────────────────────────

    /// @dev Vesting completion score: (completedEscrows / totalEscrows) * 500
    function _calcVestingScore(IssuerProfile storage profile) internal view returns (uint256) {
        uint256 total = profile.poolsCreated;
        if (total == 0) return 0;
        return (uint256(profile.escrowsCompleted) * 500) / total;
    }

    /// @dev Escrow history score: min(totalLockedWeighted / ESCROW_HISTORY_SCALE, 200)
    function _calcEscrowHistoryScore(IssuerProfile storage profile) internal view returns (uint256) {
        uint256 score = (profile.totalLockedWeighted * 200) / ESCROW_HISTORY_SCALE;
        return score > 200 ? 200 : score;
    }

    /// @dev Commitment strictness score: average of all commitment strictness scores, scaled to 0..200
    function _calcCommitmentScore(IssuerProfile storage profile) internal view returns (uint256) {
        if (profile.commitmentCount == 0) return 0;
        return profile.commitmentScore / profile.commitmentCount;
    }

    /// @dev Wallet age score: min((now - firstEventAt) / AGE_SCALE, 100)
    function _calcWalletAgeScore(IssuerProfile storage profile) internal view returns (uint256) {
        if (profile.firstEventAt == 0) return 0;
        uint256 age = block.timestamp - profile.firstEventAt;
        uint256 score = age / AGE_SCALE;
        return score > 100 ? 100 : score;
    }

    /// @dev Trigger penalty: -100 per severe (RUG_PULL/ISSUER_DUMP), -50 per other trigger
    function _calcTriggerPenalty(IssuerProfile storage profile) internal view returns (uint256) {
        uint256 severePenalty = uint256(profile.severeTriggerCount) * 100;
        uint256 otherPenalty = uint256(profile.triggerCount - profile.severeTriggerCount) * 50;
        uint256 total = severePenalty + otherPenalty;
        return total > 500 ? 500 : total;
    }

    /// @dev Calculates strictness of a single commitment (0..200 range).
    ///      Normalizes both components to BPS scale, sums, then divides once to minimize rounding loss.
    function _calcSingleCommitmentStrictness(IEscrowVault.IssuerCommitment memory c) internal pure returns (uint256) {
        // Both components normalized to 0..MAX_BPS (10000) scale
        uint256 withdrawBps = MAX_BPS - uint256(c.dailyWithdrawLimit);
        uint256 sellBps = MAX_BPS - uint256(c.maxSellPercent);

        // Sum (0..20000) then scale to 0..200 in one division
        return ((withdrawBps + sellBps) * 200) / (2 * MAX_BPS);
    }
}
