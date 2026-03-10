// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title ITriggerOracle
/// @notice Detects and classifies on-chain rug-pull and exploit trigger events.
///         Only monitors events that are verifiable purely on-chain:
///         LP removal >50% in a single tx, issuer dumps >30% supply in 24h,
///         honeypot activation, hidden tax >5%, and commitment breaches.
interface ITriggerOracle {
    // ─── Enums ────────────────────────────────────────────────────────

    /// @notice Classification of detectable on-chain trigger events.
    /// @custom:value NONE No trigger detected
    /// @custom:value RUG_PULL LP removal exceeding threshold in a single transaction
    /// @custom:value ISSUER_DUMP Issuer selling more than allowed percentage within 24h window
    /// @custom:value HONEYPOT Token transfer restrictions activated post-launch
    /// @custom:value HIDDEN_TAX Transfer tax exceeds declared amount by more than threshold
    /// @custom:value SLOW_RUG Gradual liquidity drain pattern detected over multiple transactions
    /// @custom:value COMMITMENT_BREACH Violation of issuer's on-chain commitment parameters
    enum TriggerType {
        NONE,
        RUG_PULL,
        ISSUER_DUMP,
        HONEYPOT, // v0.2: decentralized watcher network
        HIDDEN_TAX, // v0.2: decentralized watcher network
        SLOW_RUG,
        COMMITMENT_BREACH
    }

    // ─── Structs ──────────────────────────────────────────────────────

    /// @notice Configuration thresholds for trigger detection per pool.
    /// @param lpRemovalThreshold Basis points of LP that, if removed in one tx, triggers RUG_PULL (default: 5000 = 50%)
    /// @param dumpThresholdPercent Basis points of supply sold in 24h that triggers ISSUER_DUMP (default: 3000 = 30%)
    /// @param dumpWindowSeconds Time window in seconds for dump detection (default: 86400 = 24h)
    /// @param taxDeviationThreshold Basis points deviation from declared tax that triggers HIDDEN_TAX (default: 500 = 5%)
    /// @param slowRugWindowSeconds Time window for slow rug detection in seconds
    /// @param slowRugCumulativeThreshold Cumulative LP removal basis points over the slow rug window
    struct TriggerConfig {
        uint16 lpRemovalThreshold;
        uint16 dumpThresholdPercent;
        uint40 dumpWindowSeconds;
        uint16 taxDeviationThreshold;
        uint40 slowRugWindowSeconds;
        uint16 slowRugCumulativeThreshold;
    }

    /// @notice Result of a trigger check.
    /// @param triggered Whether a trigger event was detected
    /// @param triggerType The type of trigger detected (NONE if not triggered)
    struct TriggerResult {
        bool triggered;
        TriggerType triggerType;
    }

    // ─── Events ───────────────────────────────────────────────────────

    /// @notice Emitted when a trigger event is detected for a pool.
    /// @param poolId Uniswap V4 pool identifier
    /// @param triggerType Type of the detected trigger
    /// @param data Additional context data about the trigger event
    event TriggerDetected(PoolId indexed poolId, TriggerType indexed triggerType, bytes data);

    /// @notice Emitted when trigger configuration is updated for a pool.
    /// @param poolId Uniswap V4 pool identifier
    /// @param config New trigger configuration
    event TriggerConfigUpdated(PoolId indexed poolId, TriggerConfig config);

    // ─── Functions ────────────────────────────────────────────────────

    /// @notice Checks whether a trigger event has occurred for a given pool.
    /// @dev Evaluates all configured trigger conditions against current on-chain state.
    /// @param poolId Uniswap V4 pool identifier
    /// @return result Trigger check result containing triggered flag and type
    function checkTrigger(PoolId poolId) external view returns (TriggerResult memory result);

    /// @notice Returns the current trigger configuration for a pool.
    /// @param poolId Uniswap V4 pool identifier
    /// @return config The active trigger thresholds and parameters
    function getTriggerConfig(PoolId poolId) external view returns (TriggerConfig memory config);

    /// @notice Sets or updates the trigger configuration for a pool.
    /// @dev Can only be called by authorized addresses (e.g. BastionHook during pool initialization).
    /// @param poolId Uniswap V4 pool identifier
    /// @param config New trigger configuration to apply
    function setTriggerConfig(PoolId poolId, TriggerConfig calldata config) external;

    /// @notice Reports an LP addition event for flash-loan inflation tracking.
    /// @param poolId Pool identifier
    /// @param amount Amount of LP added
    function reportLPAddition(PoolId poolId, uint256 amount) external;

    // ─── Governance ──────────────────────────────────────────────────

    /// @notice Emitted when governance is transferred.
    event GovernanceTransferred(address indexed oldGov, address indexed newGov);

    /// @notice Emitted when the grace period is updated.
    event GracePeriodUpdated(uint256 newPeriod);

    /// @notice Emitted when the max pause duration is updated.
    event MaxPauseDurationUpdated(uint256 newDuration);

    /// @notice Emitted when the stable LP min age is updated.
    event StableLpMinAgeUpdated(uint256 newAge);

    /// @notice Emitted when the guardian submission deadline is updated.
    event GuardianSubmissionDeadlineUpdated(uint256 newDeadline);

    /// @notice Emitted when the guardian is updated.
    event GuardianUpdated(address indexed newGuardian);

    /// @notice Emitted when the default trigger config is updated.
    event DefaultTriggerConfigUpdated(TriggerConfig config);

    /// @notice Set the default trigger config for new pools.
    function setDefaultTriggerConfig(TriggerConfig calldata config) external;

    /// @notice Update an individual pool's trigger config (governance override).
    function updatePoolTriggerConfig(PoolId poolId, TriggerConfig calldata config) external;
}
