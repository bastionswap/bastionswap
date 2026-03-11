// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title ITriggerOracle
/// @notice Manages trigger state and executes trigger events.
///         Trigger detection (sell limits, LP removal tracking) is handled by BastionHook;
///         this contract only executes triggers when called by the hook.
interface ITriggerOracle {
    // ─── Enums ────────────────────────────────────────────────────────

    /// @notice Classification of detectable on-chain trigger events.
    enum TriggerType {
        NONE,
        RUG_PULL,
        ISSUER_DUMP,
        HONEYPOT,
        HIDDEN_TAX,
        SLOW_RUG,
        COMMITMENT_BREACH
    }

    // ─── Structs ──────────────────────────────────────────────────────

    /// @notice Configuration thresholds for trigger detection per pool.
    struct TriggerConfig {
        uint16 lpRemovalThreshold;
        uint16 dumpThresholdPercent;
        uint40 dumpWindowSeconds;
        uint16 taxDeviationThreshold;
        uint40 slowRugWindowSeconds;
        uint16 slowRugCumulativeThreshold;
        uint40 weeklyDumpWindowSeconds;
        uint16 weeklyDumpThresholdPercent;
    }

    /// @notice Result of a trigger check.
    struct TriggerResult {
        bool triggered;
        TriggerType triggerType;
    }

    // ─── Events ───────────────────────────────────────────────────────

    event TriggerDetected(PoolId indexed poolId, TriggerType indexed triggerType, bytes data);
    event TriggerConfigUpdated(PoolId indexed poolId, TriggerConfig config);

    // ─── Functions ────────────────────────────────────────────────────

    function checkTrigger(PoolId poolId) external view returns (TriggerResult memory result);
    function getTriggerConfig(PoolId poolId) external view returns (TriggerConfig memory config);
    function setTriggerConfig(PoolId poolId, TriggerConfig calldata config) external;

    /// @notice Execute a trigger, callable only by BastionHook.
    function executeTrigger(
        PoolId poolId,
        PoolKey calldata key,
        TriggerType triggerType,
        uint256 totalEligibleSupply
    ) external;

    // ─── Governance ──────────────────────────────────────────────────

    event GovernanceTransferred(address indexed oldGov, address indexed newGov);
    event MaxPauseDurationUpdated(uint256 newDuration);
    event GuardianUpdated(address indexed newGuardian);
    event DefaultTriggerConfigUpdated(TriggerConfig config);

    function setDefaultTriggerConfig(TriggerConfig calldata config) external;
    function updatePoolTriggerConfig(PoolId poolId, TriggerConfig calldata config) external;
}
