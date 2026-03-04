// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {ITriggerOracle} from "../interfaces/ITriggerOracle.sol";
import {IEscrowVault} from "../interfaces/IEscrowVault.sol";
import {IInsurancePool} from "../interfaces/IInsurancePool.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title TriggerOracle
/// @notice Detects on-chain rug-pull and exploit trigger events and propagates
///         them to EscrowVault and InsurancePool for fund redistribution.
contract TriggerOracle is ITriggerOracle, ReentrancyGuard {
    // ─── Constants ────────────────────────────────────────────────────

    uint16 internal constant BPS_BASE = 10_000;
    uint40 internal constant GRACE_PERIOD = 1 hours;
    uint256 internal constant MAX_TRACKER_ENTRIES = 50;

    // ─── Immutables ───────────────────────────────────────────────────

    address public immutable BASTION_HOOK;
    address public immutable ESCROW_VAULT;
    address public immutable INSURANCE_POOL;
    address public immutable GUARDIAN;

    // ─── Storage ──────────────────────────────────────────────────────

    /// @dev Timestamped amount record for sliding window tracking
    struct Record {
        uint40 timestamp;
        uint256 amount;
    }

    /// @dev Pending trigger awaiting grace period expiry
    struct PendingTrigger {
        TriggerType triggerType;
        uint40 detectedAt;
        uint256 totalEligibleSupply;
        address issuer;
    }

    /// @dev Per-pool trigger state
    struct PoolTriggerState {
        bool isTriggered;
        TriggerType triggerType;
        TriggerConfig config;
        bool configSet;
    }

    /// @dev poolId hash => PoolTriggerState
    mapping(bytes32 => PoolTriggerState) internal _poolStates;

    /// @dev poolId hash => LP removal records for sliding window
    mapping(bytes32 => Record[]) internal _lpRemovals;

    /// @dev poolId hash => issuer => sale records for sliding window
    mapping(bytes32 => mapping(address => Record[])) internal _issuerSales;

    /// @dev poolId hash => PendingTrigger
    mapping(bytes32 => PendingTrigger) internal _pendingTriggers;

    /// @dev poolId hash => issuer address (set when escrow is created via hook)
    mapping(bytes32 => address) internal _poolIssuers;

    /// @dev Global pause flag
    bool public paused;

    // ─── Events ───────────────────────────────────────────────────────

    event TriggerPending(PoolId indexed poolId, TriggerType indexed triggerType, uint40 executeAfter);
    event TriggerExecuted(PoolId indexed poolId, TriggerType indexed triggerType);
    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event IssuerRegistered(PoolId indexed poolId, address indexed issuer);

    // ─── Errors ───────────────────────────────────────────────────────

    error OnlyHook();
    error OnlyGuardian();
    error AlreadyTriggered();
    error ConfigNotSet();
    error IsPaused();
    error NoPendingTrigger();
    error GracePeriodNotElapsed();
    error TriggerThresholdNotMet();
    error InvalidProof();
    error ZeroAddress();

    // ─── Modifiers ────────────────────────────────────────────────────

    modifier onlyHook() {
        if (msg.sender != BASTION_HOOK) revert OnlyHook();
        _;
    }

    modifier onlyGuardian() {
        if (msg.sender != GUARDIAN) revert OnlyGuardian();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert IsPaused();
        _;
    }

    // ─── Constructor ──────────────────────────────────────────────────

    constructor(address bastionHook, address escrowVault, address insurancePool, address guardian) {
        BASTION_HOOK = bastionHook;
        ESCROW_VAULT = escrowVault;
        INSURANCE_POOL = insurancePool;
        GUARDIAN = guardian;
    }

    // ═══════════════════════════════════════════════════════════════════
    //  ON-CHAIN REAL-TIME DETECTION (called by Hook)
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Reports an LP removal event for rug-pull detection.
    /// @param poolId Pool identifier
    /// @param amount Amount of LP removed
    /// @param totalLP Total LP before removal
    function reportLPRemoval(PoolId poolId, uint256 amount, uint256 totalLP)
        external
        onlyHook
        whenNotPaused
    {
        bytes32 key = _key(poolId);
        PoolTriggerState storage state = _poolStates[key];
        if (state.isTriggered) return;
        if (!state.configSet) revert ConfigNotSet();

        TriggerConfig memory cfg = state.config;

        // Check single-tx threshold (>50% default)
        uint256 removalBps = (amount * BPS_BASE) / totalLP;
        if (removalBps >= cfg.lpRemovalThreshold) {
            _initPendingTrigger(poolId, key, TriggerType.RUG_PULL, 0);
            return;
        }

        // Track for 24h cumulative check
        _pushRecord(_lpRemovals[key], amount);

        // Check 24h cumulative (>80% = slowRugCumulativeThreshold default)
        uint256 cumulative = _sumWindow(_lpRemovals[key], cfg.dumpWindowSeconds);
        uint256 cumulativeBps = (cumulative * BPS_BASE) / totalLP;
        if (cumulativeBps >= cfg.slowRugCumulativeThreshold) {
            _initPendingTrigger(poolId, key, TriggerType.RUG_PULL, 0);
        }
    }

    /// @notice Reports an issuer token sale for dump detection.
    /// @param poolId Pool identifier
    /// @param issuer Address of the issuer selling
    /// @param amount Amount sold
    /// @param totalSupply Total token supply
    function reportIssuerSale(PoolId poolId, address issuer, uint256 amount, uint256 totalSupply)
        external
        onlyHook
        whenNotPaused
    {
        bytes32 key = _key(poolId);
        PoolTriggerState storage state = _poolStates[key];
        if (state.isTriggered) return;
        if (!state.configSet) revert ConfigNotSet();

        _pushRecord(_issuerSales[key][issuer], amount);

        TriggerConfig memory cfg = state.config;
        uint256 cumulative = _sumWindow(_issuerSales[key][issuer], cfg.dumpWindowSeconds);
        uint256 cumulativeBps = (cumulative * BPS_BASE) / totalSupply;

        if (cumulativeBps >= cfg.dumpThresholdPercent) {
            _initPendingTrigger(poolId, key, TriggerType.ISSUER_DUMP, totalSupply);
        }
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

        _initPendingTrigger(poolId, key, TriggerType.COMMITMENT_BREACH, 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  OFF-CHAIN BOT PROOF SUBMISSION
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Submit proof that a token has honeypot behavior.
    /// @param poolId Pool identifier
    /// @param proof Encoded proof data (e.g. failed transfer tx hash + Merkle proof)
    function submitHoneypotProof(PoolId poolId, bytes calldata proof)
        external
        whenNotPaused
    {
        if (proof.length == 0) revert InvalidProof();

        bytes32 key = _key(poolId);
        PoolTriggerState storage state = _poolStates[key];
        if (state.isTriggered) return;
        if (!state.configSet) revert ConfigNotSet();

        // Proof validation: decode and verify minimally
        // In production, this would verify a Merkle proof against a trusted root.
        // For now, we require non-empty proof and trust the bot's submission.
        // Future: verify against a Merkle root posted by a trusted sequencer.

        _initPendingTrigger(poolId, key, TriggerType.HONEYPOT, 0);
    }

    /// @notice Submit proof of hidden tax exceeding threshold.
    /// @param poolId Pool identifier
    /// @param expectedOutput Expected swap output amount
    /// @param actualOutput Actual swap output received
    /// @param proof Additional proof data
    function submitHiddenTaxProof(
        PoolId poolId,
        uint256 expectedOutput,
        uint256 actualOutput,
        bytes calldata proof
    ) external whenNotPaused {
        if (proof.length == 0) revert InvalidProof();
        if (actualOutput >= expectedOutput) revert TriggerThresholdNotMet();

        bytes32 key = _key(poolId);
        PoolTriggerState storage state = _poolStates[key];
        if (state.isTriggered) return;
        if (!state.configSet) revert ConfigNotSet();

        // Check if deviation exceeds threshold
        uint256 deviation = ((expectedOutput - actualOutput) * BPS_BASE) / expectedOutput;
        if (deviation < state.config.taxDeviationThreshold) revert TriggerThresholdNotMet();

        _initPendingTrigger(poolId, key, TriggerType.HIDDEN_TAX, 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  TRIGGER EXECUTION (after grace period)
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Execute a pending trigger after the grace period has elapsed.
    /// @param poolId Pool identifier
    function executeTrigger(PoolId poolId) external nonReentrant whenNotPaused {
        bytes32 key = _key(poolId);
        PendingTrigger storage pending = _pendingTriggers[key];
        if (pending.detectedAt == 0) revert NoPendingTrigger();
        if (block.timestamp < pending.detectedAt + GRACE_PERIOD) revert GracePeriodNotElapsed();

        PoolTriggerState storage state = _poolStates[key];
        if (state.isTriggered) revert AlreadyTriggered();

        TriggerType triggerType = pending.triggerType;
        uint256 totalEligibleSupply = pending.totalEligibleSupply;

        // Mark as triggered
        state.isTriggered = true;
        state.triggerType = triggerType;

        // Clear pending
        delete _pendingTriggers[key];

        // Propagate to EscrowVault
        address issuer = _poolIssuers[key];
        if (issuer != address(0)) {
            uint256 escrowId = _computeEscrowId(poolId, issuer);
            try IEscrowVault(ESCROW_VAULT).triggerRedistribution(escrowId, uint8(triggerType)) {}
            catch {}
        }

        // Propagate to InsurancePool
        if (totalEligibleSupply > 0) {
            try IInsurancePool(INSURANCE_POOL).executePayout(poolId, uint8(triggerType), totalEligibleSupply) {}
            catch {}
        }

        emit TriggerDetected(poolId, triggerType, "");
        emit TriggerExecuted(poolId, triggerType);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  CONFIGURATION & ADMIN
    // ═══════════════════════════════════════════════════════════════════

    /// @inheritdoc ITriggerOracle
    function setTriggerConfig(PoolId poolId, TriggerConfig calldata config) external onlyHook {
        bytes32 key = _key(poolId);
        _poolStates[key].config = config;
        _poolStates[key].configSet = true;

        emit TriggerConfigUpdated(poolId, config);
    }

    /// @notice Register the issuer for a pool (called by Hook during pool creation).
    /// @param poolId Pool identifier
    /// @param issuer Issuer address
    function registerIssuer(PoolId poolId, address issuer) external onlyHook {
        if (issuer == address(0)) revert ZeroAddress();
        bytes32 key = _key(poolId);
        _poolIssuers[key] = issuer;

        emit IssuerRegistered(poolId, issuer);
    }

    /// @notice Pause all trigger detection and execution.
    function pause() external onlyGuardian {
        paused = true;
        emit Paused(msg.sender);
    }

    /// @notice Unpause trigger detection and execution.
    function unpause() external onlyGuardian {
        paused = false;
        emit Unpaused(msg.sender);
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

    /// @notice Check if a pool has a pending trigger awaiting grace period.
    function getPendingTrigger(PoolId poolId)
        external
        view
        returns (bool exists, TriggerType triggerType, uint40 executeAfter)
    {
        PendingTrigger storage pending = _pendingTriggers[_key(poolId)];
        exists = pending.detectedAt != 0;
        triggerType = pending.triggerType;
        executeAfter = pending.detectedAt + GRACE_PERIOD;
    }

    /// @notice Get the registered issuer for a pool.
    function getPoolIssuer(PoolId poolId) external view returns (address) {
        return _poolIssuers[_key(poolId)];
    }

    /// @notice Check if a pool's trigger config has been set.
    function isConfigSet(PoolId poolId) external view returns (bool) {
        return _poolStates[_key(poolId)].configSet;
    }

    // ─── Internal Functions ───────────────────────────────────────────

    function _key(PoolId poolId) internal pure returns (bytes32) {
        return PoolId.unwrap(poolId);
    }

    function _computeEscrowId(PoolId poolId, address issuer) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(poolId, issuer)));
    }

    function _initPendingTrigger(
        PoolId poolId,
        bytes32 key,
        TriggerType triggerType,
        uint256 totalEligibleSupply
    ) internal {
        PoolTriggerState storage state = _poolStates[key];
        if (state.isTriggered) return;

        // Don't overwrite an existing pending trigger
        if (_pendingTriggers[key].detectedAt != 0) return;

        _pendingTriggers[key] = PendingTrigger({
            triggerType: triggerType,
            detectedAt: uint40(block.timestamp),
            totalEligibleSupply: totalEligibleSupply,
            issuer: _poolIssuers[key]
        });

        emit TriggerPending(poolId, triggerType, uint40(block.timestamp) + GRACE_PERIOD);
    }

    /// @dev Push a new record, pruning old entries beyond MAX_TRACKER_ENTRIES.
    function _pushRecord(Record[] storage records, uint256 amount) internal {
        records.push(Record({timestamp: uint40(block.timestamp), amount: amount}));

        // Prune: if too many entries, remove oldest
        if (records.length > MAX_TRACKER_ENTRIES) {
            // Shift the array: remove first element
            for (uint256 i; i < records.length - 1; ++i) {
                records[i] = records[i + 1];
            }
            records.pop();
        }
    }

    /// @dev Sum amounts within the sliding window ending at block.timestamp.
    function _sumWindow(Record[] storage records, uint40 windowSeconds) internal view returns (uint256 total) {
        uint256 cutoff = block.timestamp > windowSeconds ? block.timestamp - windowSeconds : 0;
        uint256 len = records.length;

        for (uint256 i; i < len; ++i) {
            if (records[i].timestamp >= cutoff) {
                total += records[i].amount;
            }
        }
    }
}
