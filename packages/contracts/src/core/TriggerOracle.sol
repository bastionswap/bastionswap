// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.26;

import {ITriggerOracle} from "../interfaces/ITriggerOracle.sol";
import {IEscrowVault} from "../interfaces/IEscrowVault.sol";
import {IInsurancePool} from "../interfaces/IInsurancePool.sol";
import {IReputationEngine} from "../interfaces/IReputationEngine.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title TriggerOracle
/// @notice Manages trigger state and propagates trigger events to EscrowVault,
///         InsurancePool, and ReputationEngine. Trigger detection (sell limits,
///         LP removal tracking) is handled by BastionHook; this contract only
///         executes triggers when called by the hook.
contract TriggerOracle is ITriggerOracle, ReentrancyGuard {
    // ─── Constants ────────────────────────────────────────────────────

    uint16 internal constant BPS_BASE = 10_000;

    // ─── Immutables ───────────────────────────────────────────────────

    address public immutable BASTION_HOOK;
    address public immutable ESCROW_VAULT;
    address public immutable INSURANCE_POOL;
    IReputationEngine public immutable REPUTATION_ENGINE;

    // ─── Governance ──────────────────────────────────────────────────

    address public GOVERNANCE;

    // ─── Governance Parameters ───────────────────────────────────────

    /// @notice Maximum pause duration (default 7 days)
    uint40 public maxPauseDuration;

    /// @notice Guardian address for trigger operations
    address public guardian;

    /// @notice Default trigger config inherited by new pools
    TriggerConfig public defaultTriggerConfig;

    // ─── Storage ──────────────────────────────────────────────────────

    /// @dev Per-pool trigger state
    struct PoolTriggerState {
        bool isTriggered;
        TriggerType triggerType;
        TriggerConfig config;
        bool configSet;
    }

    /// @dev poolId hash => PoolTriggerState
    mapping(bytes32 => PoolTriggerState) internal _poolStates;

    /// @dev poolId hash => issuer address (set when escrow is created via hook)
    mapping(bytes32 => address) internal _poolIssuers;

    /// @dev Pause expiry timestamp (0 = not paused)
    uint40 public pausedUntil;

    /// @dev poolId hash => initial total supply snapshot at pool creation
    mapping(bytes32 => uint256) internal _initialTotalSupply;

    /// @dev poolId hash => issued token address (for fallback balanceOf claims)
    mapping(bytes32 => address) internal _poolIssuedTokens;

    // ─── Events ───────────────────────────────────────────────────────

    event TriggerExecuted(PoolId indexed poolId, TriggerType indexed triggerType, bool withMerkleRoot);
    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event IssuerRegistered(PoolId indexed poolId, address indexed issuer);
    event ExternalCallFailed(string target, PoolId indexed poolId);

    // ─── Errors ───────────────────────────────────────────────────────

    error OnlyHook();
    error OnlyGuardian();
    error OnlyGovernance();
    error AlreadyTriggered();
    error ConfigNotSet();
    error IsPaused();
    error ZeroAddress();
    error InvalidDuration();
    error InvalidTriggerConfig();

    // ─── Modifiers ────────────────────────────────────────────────────

    modifier onlyHook() {
        if (msg.sender != BASTION_HOOK) revert OnlyHook();
        _;
    }

    modifier onlyGuardian() {
        if (msg.sender != guardian) revert OnlyGuardian();
        _;
    }

    modifier onlyGovernance() {
        if (msg.sender != GOVERNANCE) revert OnlyGovernance();
        _;
    }

    modifier whenNotPaused() {
        if (block.timestamp < pausedUntil) revert IsPaused();
        _;
    }

    // ─── Constructor ──────────────────────────────────────────────────

    error ZeroConstructorAddress();

    constructor(
        address bastionHook,
        address escrowVault,
        address insurancePool,
        address guardian_,
        address reputationEngine,
        address governance
    ) {
        if (bastionHook == address(0)) revert ZeroConstructorAddress();
        if (escrowVault == address(0)) revert ZeroConstructorAddress();
        if (insurancePool == address(0)) revert ZeroConstructorAddress();
        if (guardian_ == address(0)) revert ZeroConstructorAddress();
        if (reputationEngine == address(0)) revert ZeroConstructorAddress();
        if (governance == address(0)) revert ZeroConstructorAddress();

        BASTION_HOOK = bastionHook;
        ESCROW_VAULT = escrowVault;
        INSURANCE_POOL = insurancePool;
        guardian = guardian_;
        GOVERNANCE = governance;
        REPUTATION_ENGINE = IReputationEngine(reputationEngine);

        // Initialize governance parameters with defaults
        maxPauseDuration = 7 days;

        // Initialize default trigger config
        defaultTriggerConfig = TriggerConfig({
            dailyLpRemovalBps: 1000,
            weeklyLpRemovalBps: 3000,
            dumpThresholdPercent: 300,
            dumpWindowSeconds: 86400,
            taxDeviationThreshold: 500,
            weeklyDumpWindowSeconds: 604800,
            weeklyDumpThresholdPercent: 1500
        });
    }

    // ═══════════════════════════════════════════════════════════════════
    //  TRIGGER EXECUTION (called by BastionHook)
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Execute a trigger, callable only by BastionHook.
    /// @dev BastionHook calls this after verifying cumulative LP removal threshold is met.
    function executeTrigger(
        PoolId poolId,
        PoolKey calldata, /* key */
        TriggerType triggerType,
        uint256 totalEligibleSupply
    ) external onlyHook whenNotPaused {
        bytes32 k = _key(poolId);
        PoolTriggerState storage state = _poolStates[k];
        if (state.isTriggered) revert AlreadyTriggered();
        if (!state.configSet) revert ConfigNotSet();

        _executeImmediate(poolId, k, triggerType, totalEligibleSupply);
    }

    /// @notice Reports a commitment breach by the issuer.
    /// @param poolId Pool identifier
    function reportCommitmentBreach(PoolId poolId)
        external
        onlyHook
        whenNotPaused
    {
        bytes32 key = _key(poolId);
        PoolTriggerState storage state = _poolStates[key];
        if (state.isTriggered) return;
        if (!state.configSet) revert ConfigNotSet();

        _executeImmediate(poolId, key, TriggerType.COMMITMENT_BREACH, 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  IMMEDIATE TRIGGER EXECUTION
    // ═══════════════════════════════════════════════════════════════════

    /// @dev Immediately executes a trigger: marks state, propagates to EscrowVault,
    ///      InsurancePool (with zero merkle root for balanceOf fallback), and ReputationEngine.
    function _executeImmediate(
        PoolId poolId,
        bytes32 key,
        TriggerType triggerType,
        uint256 totalEligibleSupply
    ) internal {
        PoolTriggerState storage state = _poolStates[key];
        if (state.isTriggered) return;

        // Mark as triggered
        state.isTriggered = true;
        state.triggerType = triggerType;

        // Propagate to EscrowVault — must succeed or entire trigger reverts (H-03 fix)
        address issuer = _poolIssuers[key];
        if (issuer != address(0)) {
            uint256 escrowId = _computeEscrowId(poolId, issuer);
            IEscrowVault(ESCROW_VAULT).triggerForceRemoval(escrowId, uint8(triggerType));
        }

        // Propagate to InsurancePool (enters 24h waiting state for guardian Merkle root submission)
        if (totalEligibleSupply > 0) {
            try IInsurancePool(INSURANCE_POOL).executePayout(
                poolId, uint8(triggerType), totalEligibleSupply, _poolIssuedTokens[key]
            ) {} catch {
                emit ExternalCallFailed("InsurancePool.executePayout", poolId);
            }
        }

        // Record trigger in reputation engine
        if (issuer != address(0)) {
            try REPUTATION_ENGINE.recordEvent(
                issuer,
                IReputationEngine.EventType.TRIGGER_FIRED,
                abi.encode(uint8(triggerType))
            ) {} catch {
                emit ExternalCallFailed("ReputationEngine.recordEvent", poolId);
            }
        }

        emit TriggerDetected(poolId, triggerType, "");
        emit TriggerExecuted(poolId, triggerType, false);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  CONFIGURATION & ADMIN
    // ═══════════════════════════════════════════════════════════════════

    /// @inheritdoc ITriggerOracle
    function setTriggerConfig(PoolId poolId, TriggerConfig calldata config) external onlyHook {
        _validateTriggerConfig(config); // C-01 fix: validate on pool creation too
        bytes32 key = _key(poolId);
        _poolStates[key].config = config;
        _poolStates[key].configSet = true;

        emit TriggerConfigUpdated(poolId, config);
    }

    /// @notice Register the issuer for a pool (called by Hook during pool creation).
    /// @param poolId Pool identifier
    /// @param issuer Issuer address
    /// @param totalSupply Initial total supply snapshot for dump detection denominator
    /// @param issuedToken Address of the issued token (for fallback balanceOf claims)
    function registerIssuer(PoolId poolId, address issuer, uint256 totalSupply, address issuedToken) external onlyHook {
        if (issuer == address(0)) revert ZeroAddress();
        bytes32 key = _key(poolId);
        _poolIssuers[key] = issuer;
        _initialTotalSupply[key] = totalSupply;
        _poolIssuedTokens[key] = issuedToken;

        emit IssuerRegistered(poolId, issuer);
    }

    /// @notice Pause all trigger detection and execution for up to MAX_PAUSE_DURATION.
    function pause() external onlyGuardian {
        pausedUntil = uint40(block.timestamp) + maxPauseDuration;
        emit Paused(msg.sender);
    }

    /// @notice Unpause trigger detection and execution immediately.
    function unpause() external onlyGuardian {
        pausedUntil = 0;
        emit Unpaused(msg.sender);
    }

    /// @notice Check if the oracle is currently paused.
    function paused() external view returns (bool) {
        return block.timestamp < pausedUntil;
    }

    // ═══════════════════════════════════════════════════════════════════
    //  VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════

    /// @inheritdoc ITriggerOracle
    function checkTrigger(PoolId poolId) external view returns (TriggerResult memory result) {
        PoolTriggerState storage state = _poolStates[_key(poolId)];
        result.triggered = state.isTriggered;
        result.triggerType = state.triggerType;
    }

    /// @inheritdoc ITriggerOracle
    function getTriggerConfig(PoolId poolId) external view returns (TriggerConfig memory) {
        return _poolStates[_key(poolId)].config;
    }

    /// @notice Get the registered issuer for a pool.
    function getPoolIssuer(PoolId poolId) external view returns (address) {
        return _poolIssuers[_key(poolId)];
    }

    /// @notice Check if a pool's trigger config has been set.
    function isConfigSet(PoolId poolId) external view returns (bool) {
        return _poolStates[_key(poolId)].configSet;
    }

    /// @notice Get the initial total supply snapshot for a pool.
    function getInitialTotalSupply(PoolId poolId) external view returns (uint256) {
        return _initialTotalSupply[_key(poolId)];
    }

    /// @notice Returns the default trigger config as a struct (avoids tuple destructuring).
    function getDefaultTriggerConfig() external view returns (TriggerConfig memory) {
        return defaultTriggerConfig;
    }

    // ═══════════════════════════════════════════════════════════════════
    //  GOVERNANCE PARAMETER SETTERS
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Transfer governance to a new address.
    function transferGovernance(address newGovernance) external onlyGovernance {
        if (newGovernance == address(0)) revert ZeroAddress();
        address oldGov = GOVERNANCE;
        GOVERNANCE = newGovernance;
        emit GovernanceTransferred(oldGov, newGovernance);
    }

    /// @notice Set the max pause duration (1–14 days).
    function setMaxPauseDuration(uint40 newDuration) external onlyGovernance {
        if (newDuration < 1 days || newDuration > 14 days) revert InvalidDuration();
        maxPauseDuration = newDuration;
        emit MaxPauseDurationUpdated(newDuration);
    }

    /// @notice Set a new guardian address.
    function setGuardian(address newGuardian) external onlyGovernance {
        if (newGuardian == address(0)) revert ZeroAddress();
        guardian = newGuardian;
        emit GuardianUpdated(newGuardian);
    }

    /// @notice Set the default trigger config for new pools.
    function setDefaultTriggerConfig(TriggerConfig calldata config) external onlyGovernance {
        _validateTriggerConfig(config);
        defaultTriggerConfig = config;
        emit DefaultTriggerConfigUpdated(config);
    }

    error PoolAlreadyRegistered();

    /// @notice Update an individual pool's trigger config (governance override).
    /// @dev Only allowed for pools that have NOT been registered with an issuer yet (M-01 fix).
    function updatePoolTriggerConfig(PoolId poolId, TriggerConfig calldata config) external onlyGovernance {
        _validateTriggerConfig(config);
        bytes32 key = _key(poolId);
        if (_poolIssuers[key] != address(0)) revert PoolAlreadyRegistered(); // M-01 fix
        _poolStates[key].config = config;
        _poolStates[key].configSet = true;
        emit TriggerConfigUpdated(poolId, config);
    }

    // ─── Internal Functions ───────────────────────────────────────────

    function _key(PoolId poolId) internal pure returns (bytes32) {
        return PoolId.unwrap(poolId);
    }

    function _computeEscrowId(PoolId poolId, address issuer) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(poolId, issuer)));
    }

    /// @dev Validates TriggerConfig fields are within sane ranges.
    function _validateTriggerConfig(TriggerConfig calldata cfg) internal pure {
        // LP removal BPS: must be > 0 and <= 10000
        if (cfg.dailyLpRemovalBps == 0 || cfg.dailyLpRemovalBps > BPS_BASE) revert InvalidTriggerConfig();
        if (cfg.weeklyLpRemovalBps == 0 || cfg.weeklyLpRemovalBps > BPS_BASE) revert InvalidTriggerConfig();
        // Sell BPS thresholds: must be > 0 and <= 10000
        if (cfg.dumpThresholdPercent == 0 || cfg.dumpThresholdPercent > BPS_BASE) revert InvalidTriggerConfig();
        if (cfg.taxDeviationThreshold == 0 || cfg.taxDeviationThreshold > BPS_BASE) revert InvalidTriggerConfig();
        if (cfg.weeklyDumpThresholdPercent == 0 || cfg.weeklyDumpThresholdPercent > BPS_BASE) revert InvalidTriggerConfig();
        // Time windows: must be between 1 hour and 30 days
        if (cfg.dumpWindowSeconds < 1 hours || cfg.dumpWindowSeconds > 30 days) revert InvalidTriggerConfig();
        if (cfg.weeklyDumpWindowSeconds < 1 days || cfg.weeklyDumpWindowSeconds > 30 days) revert InvalidTriggerConfig();
    }
}
