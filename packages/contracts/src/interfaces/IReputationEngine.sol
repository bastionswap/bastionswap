// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.26;

/// @title IReputationEngine
/// @notice Tracks and computes on-chain reputation scores for token issuers.
///         Scores range from 0 (worst) to 1000 (best) and are derived from
///         on-chain events such as successful vesting completions, trigger violations,
///         and commitment adherence history.
interface IReputationEngine {
    // ─── Enums ────────────────────────────────────────────────────────

    /// @notice Types of events that affect an issuer's reputation score.
    /// @custom:value ESCROW_COMPLETED Issuer fully completed a vesting schedule (positive)
    /// @custom:value TRIGGER_FIRED A trigger event was detected for the issuer's pool (negative)
    /// @custom:value COMMITMENT_HONORED Issuer stayed within commitment parameters for a period (positive)
    /// @custom:value COMMITMENT_VIOLATED Issuer violated on-chain commitment parameters (negative)
    /// @custom:value POOL_CREATED Issuer created a new pool (tracked for vesting ratio only, no score increase)
    enum EventType {
        ESCROW_COMPLETED,
        TRIGGER_FIRED,
        COMMITMENT_HONORED,
        COMMITMENT_VIOLATED,
        POOL_CREATED
    }

    // ─── Events ───────────────────────────────────────────────────────

    /// @notice Emitted when a reputation-affecting event is recorded for an issuer.
    /// @param issuer Address of the token issuer
    /// @param eventType Type of the recorded event
    /// @param newScore Updated reputation score after the event
    event ReputationUpdated(address indexed issuer, EventType indexed eventType, uint256 newScore);

    // ─── Functions ────────────────────────────────────────────────────

    /// @notice Returns the current reputation score of a token issuer.
    /// @dev Score is in the range [0, 1000]. New issuers start with a baseline score.
    /// @param issuer Address of the token issuer
    /// @return score Current reputation score (0 = worst, 1000 = best)
    function getScore(address issuer) external view returns (uint256 score);

    /// @notice Records a reputation-affecting event for a token issuer.
    /// @dev Can only be called by authorized protocol contracts (BastionHook, EscrowVault, TriggerOracle).
    /// @param issuer Address of the token issuer
    /// @param eventType Type of event being recorded
    /// @param data Arbitrary encoded data providing context about the event
    function recordEvent(address issuer, EventType eventType, bytes calldata data) external;

    /// @notice Encodes an issuer's score data for cross-chain transmission.
    /// @param issuer Address of the token issuer
    /// @return data ABI-encoded score data
    function encodeScoreData(address issuer) external view returns (bytes memory data);

    /// @notice Decodes score data received from a cross-chain message.
    /// @param data ABI-encoded score data
    /// @return score The reputation score
    /// @return poolsCreated Number of pools created
    /// @return escrowsCompleted Number of escrows completed
    /// @return triggerCount Total trigger count
    function decodeScoreData(bytes calldata data)
        external
        pure
        returns (uint256 score, uint16 poolsCreated, uint16 escrowsCompleted, uint16 triggerCount);
}
