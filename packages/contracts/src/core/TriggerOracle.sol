// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.26;

import {ITriggerOracle} from "../interfaces/ITriggerOracle.sol";
import {IEscrowVault} from "../interfaces/IEscrowVault.sol";
import {IInsurancePool} from "../interfaces/IInsurancePool.sol";
import {IReputationEngine} from "../interfaces/IReputationEngine.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title TriggerOracle
/// @notice Detects on-chain rug-pull and exploit trigger events and propagates
///         them to EscrowVault and InsurancePool for fund redistribution.
contract TriggerOracle is ITriggerOracle, ReentrancyGuard {
    // ─── Constants ────────────────────────────────────────────────────

    uint16 internal constant BPS_BASE = 10_000;
    uint256 internal constant MAX_TRACKER_ENTRIES = 50;
    uint40 internal constant MERKLE_ROOT_CHALLENGE_PERIOD = 1 hours;

    // ─── Immutables ───────────────────────────────────────────────────

    address public immutable BASTION_HOOK;
    address public immutable ESCROW_VAULT;
    address public immutable INSURANCE_POOL;
    IReputationEngine public immutable REPUTATION_ENGINE;

    // ─── Governance ──────────────────────────────────────────────────

    address public GOVERNANCE;

    // ─── Governance Parameters ───────────────────────────────────────

    /// @notice Grace period before trigger execution (default 1 hour)
    uint40 public gracePeriod;

    /// @notice Maximum pause duration (default 7 days)
    uint40 public maxPauseDuration;

    /// @notice Minimum LP age for stable LP calculation (default 1 hour)
    uint40 public stableLpMinAge;

    /// @notice Guardian submission deadline after grace period (default 24 hours)
    uint40 public guardianSubmissionDeadline;

    /// @notice Guardian address for trigger operations
    address public guardian;

    /// @notice Default trigger config inherited by new pools
    TriggerConfig public defaultTriggerConfig;

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

    /// @dev Pause expiry timestamp (0 = not paused)
    uint40 public pausedUntil;

    /// @dev poolId hash => LP addition records for flash-loan inflation tracking
    mapping(bytes32 => Record[]) internal _lpAdditions;

    /// @dev poolId hash => initial total supply snapshot at pool creation
    mapping(bytes32 => uint256) internal _initialTotalSupply;

    /// @dev poolId hash => pending Merkle root submitted by guardian
    mapping(bytes32 => bytes32) internal _pendingMerkleRoots;

    /// @dev poolId hash => timestamp when Merkle root was submitted
    mapping(bytes32 => uint40) internal _merkleRootSubmittedAt;

    /// @dev poolId hash => issued token address (for fallback balanceOf claims)
    mapping(bytes32 => address) internal _poolIssuedTokens;

    // ─── Events ───────────────────────────────────────────────────────

    event TriggerPending(PoolId indexed poolId, TriggerType indexed triggerType, uint40 executeAfter);
    event TriggerExecuted(PoolId indexed poolId, TriggerType indexed triggerType, bool withMerkleRoot);
    event MerkleRootSubmitted(PoolId indexed poolId, bytes32 merkleRoot);
    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event IssuerRegistered(PoolId indexed poolId, address indexed issuer);
    event ExternalCallFailed(string target, PoolId indexed poolId);
    event SupplyInflationDetected(PoolId indexed poolId, uint256 initial, uint256 current);

    // ─── Errors ───────────────────────────────────────────────────────

    error OnlyHook();
    error OnlyGuardian();
    error OnlyGovernance();
    error AlreadyTriggered();
    error ConfigNotSet();
    error IsPaused();
    error NoPendingTrigger();
    error GracePeriodNotElapsed();
    error ZeroAddress();
    error MerkleRootAlreadySubmitted();
    error MerkleRootChallengeNotElapsed();
    error WaitingForMerkleRoot();
    error ZeroMerkleRoot();
    error InvalidDuration();

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

    constructor(
        address bastionHook,
        address escrowVault,
        address insurancePool,
        address guardian_,
        address reputationEngine,
        address governance
    ) {
        BASTION_HOOK = bastionHook;
        ESCROW_VAULT = escrowVault;
        INSURANCE_POOL = insurancePool;
        guardian = guardian_;
        GOVERNANCE = governance;
        REPUTATION_ENGINE = IReputationEngine(reputationEngine);

        // Initialize governance parameters with defaults
        gracePeriod = 1 hours;
        maxPauseDuration = 7 days;
        stableLpMinAge = 1 hours;
        guardianSubmissionDeadline = 24 hours;

        // Initialize default trigger config
        defaultTriggerConfig = TriggerConfig({
            lpRemovalThreshold: 5000,
            dumpThresholdPercent: 3000,
            dumpWindowSeconds: 86400,
            taxDeviationThreshold: 500,
            slowRugWindowSeconds: 86400,
            slowRugCumulativeThreshold: 8000,
            weeklyDumpWindowSeconds: 604800,
            weeklyDumpThresholdPercent: 5000
        });
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

        // RISK-4: Use stable LP (LP present >= MIN_LP_AGE) instead of raw totalLP
        uint256 stableLP = _computeStableLP(key, totalLP);
        uint256 effectiveLP = stableLP > 0 ? stableLP : totalLP;

        // Check single-tx threshold (>50% default)
        uint256 removalBps = (amount * BPS_BASE) / effectiveLP;
        if (removalBps >= cfg.lpRemovalThreshold) {
            _initPendingTrigger(poolId, key, TriggerType.RUG_PULL, 0);
            return;
        }

        // Track for 24h cumulative check
        _pushRecord(_lpRemovals[key], amount);

        // Check cumulative LP removal over slowRugWindowSeconds (>80% = slowRugCumulativeThreshold default)
        uint256 cumulative = _sumWindow(_lpRemovals[key], cfg.slowRugWindowSeconds);
        uint256 cumulativeBps = (cumulative * BPS_BASE) / effectiveLP;
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

        // RISK-5: Use min(totalSupply, initialTotalSupply) as denominator
        uint256 initialSupply = _initialTotalSupply[key];
        uint256 denominator = (initialSupply > 0 && totalSupply > initialSupply) ? initialSupply : totalSupply;

        // Emit inflation detection event if current supply exceeds initial by 50%
        if (initialSupply > 0 && totalSupply > (initialSupply * 3) / 2) {
            emit SupplyInflationDetected(poolId, initialSupply, totalSupply);
        }

        uint256 cumulativeBps = (cumulative * BPS_BASE) / denominator;

        if (cumulativeBps >= cfg.dumpThresholdPercent) {
            _initPendingTrigger(poolId, key, TriggerType.ISSUER_DUMP, totalSupply);
            return;
        }

        // Check weekly cumulative issuer sell → SLOW_RUG
        if (cfg.weeklyDumpWindowSeconds > 0 && cfg.weeklyDumpThresholdPercent > 0) {
            uint256 weeklyCumulative = _sumWindow(_issuerSales[key][issuer], cfg.weeklyDumpWindowSeconds);
            uint256 weeklyBps = (weeklyCumulative * BPS_BASE) / denominator;
            if (weeklyBps >= cfg.weeklyDumpThresholdPercent) {
                _initPendingTrigger(poolId, key, TriggerType.SLOW_RUG, totalSupply);
            }
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

    /// @notice Reports an LP addition event for flash-loan inflation tracking (RISK-4).
    /// @param poolId Pool identifier
    /// @param amount Amount of LP added
    function reportLPAddition(PoolId poolId, uint256 amount) external onlyHook {
        bytes32 key = _key(poolId);
        _pushRecord(_lpAdditions[key], amount);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  TRIGGER EXECUTION (after grace period)
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Submit a Merkle root for a pending trigger (guardian data role).
    /// @param poolId Pool identifier
    /// @param merkleRoot Merkle root of (holder, balance) snapshot
    function submitMerkleRoot(PoolId poolId, bytes32 merkleRoot) external onlyGuardian {
        if (merkleRoot == bytes32(0)) revert ZeroMerkleRoot();
        bytes32 key = _key(poolId);
        PendingTrigger storage pending = _pendingTriggers[key];
        if (pending.detectedAt == 0) revert NoPendingTrigger();
        if (_pendingMerkleRoots[key] != bytes32(0)) revert MerkleRootAlreadySubmitted();

        _pendingMerkleRoots[key] = merkleRoot;
        _merkleRootSubmittedAt[key] = uint40(block.timestamp);

        emit MerkleRootSubmitted(poolId, merkleRoot);
    }

    /// @notice Execute a pending trigger after grace period and either challenge period or deadline.
    /// @dev Permissionless. Path A: root submitted + challenge elapsed. Path B: no root + 24h deadline elapsed.
    /// @param poolId Pool identifier
    function executeTrigger(PoolId poolId) external nonReentrant whenNotPaused {
        bytes32 key = _key(poolId);
        PendingTrigger storage pending = _pendingTriggers[key];
        if (pending.detectedAt == 0) revert NoPendingTrigger();
        if (block.timestamp < pending.detectedAt + gracePeriod) revert GracePeriodNotElapsed();

        PoolTriggerState storage state = _poolStates[key];
        if (state.isTriggered) revert AlreadyTriggered();

        bytes32 merkleRoot = _pendingMerkleRoots[key];
        bool withMerkleRoot;

        if (merkleRoot != bytes32(0)) {
            // Path A: Merkle root submitted — require challenge period elapsed
            uint40 submittedAt = _merkleRootSubmittedAt[key];
            if (block.timestamp < submittedAt + MERKLE_ROOT_CHALLENGE_PERIOD) {
                revert MerkleRootChallengeNotElapsed();
            }
            withMerkleRoot = true;
        } else {
            // Path B: No Merkle root — require deadline elapsed after grace
            if (block.timestamp < pending.detectedAt + gracePeriod + guardianSubmissionDeadline) {
                revert WaitingForMerkleRoot();
            }
            withMerkleRoot = false;
        }

        _executeTriggerInternal(poolId, key, merkleRoot, withMerkleRoot);
    }

    function _executeTriggerInternal(
        PoolId poolId,
        bytes32 key,
        bytes32 merkleRoot,
        bool withMerkleRoot
    ) internal {
        PendingTrigger storage pending = _pendingTriggers[key];
        PoolTriggerState storage state = _poolStates[key];

        TriggerType triggerType = pending.triggerType;
        uint256 totalEligibleSupply = pending.totalEligibleSupply;

        // Mark as triggered
        state.isTriggered = true;
        state.triggerType = triggerType;

        // Clear pending state
        delete _pendingTriggers[key];
        delete _pendingMerkleRoots[key];
        delete _merkleRootSubmittedAt[key];

        // Propagate to EscrowVault
        address issuer = _poolIssuers[key];
        if (issuer != address(0)) {
            uint256 escrowId = _computeEscrowId(poolId, issuer);
            try IEscrowVault(ESCROW_VAULT).triggerForceRemoval(escrowId, uint8(triggerType)) {}
            catch {
                emit ExternalCallFailed("EscrowVault.triggerForceRemoval", poolId);
            }
        }

        // Propagate to InsurancePool
        if (totalEligibleSupply > 0) {
            try IInsurancePool(INSURANCE_POOL).executePayout(
                poolId, uint8(triggerType), totalEligibleSupply, merkleRoot, _poolIssuedTokens[key]
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
        emit TriggerExecuted(poolId, triggerType, withMerkleRoot);
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

    /// @notice Check if a pool has a pending trigger awaiting grace period.
    function getPendingTrigger(PoolId poolId)
        external
        view
        returns (bool exists, TriggerType triggerType, uint40 executeAfter)
    {
        PendingTrigger storage pending = _pendingTriggers[_key(poolId)];
        exists = pending.detectedAt != 0;
        triggerType = pending.triggerType;
        executeAfter = pending.detectedAt + gracePeriod;
    }

    /// @notice Get the pending Merkle root and submission timestamp for a pool.
    function getPendingMerkleRoot(PoolId poolId) external view returns (bytes32 merkleRoot, uint40 submittedAt) {
        bytes32 key = _key(poolId);
        merkleRoot = _pendingMerkleRoots[key];
        submittedAt = _merkleRootSubmittedAt[key];
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

    /// @notice Set the grace period (15 min – 24 hours).
    function setGracePeriod(uint40 newPeriod) external onlyGovernance {
        if (newPeriod < 15 minutes || newPeriod > 24 hours) revert InvalidDuration();
        gracePeriod = newPeriod;
        emit GracePeriodUpdated(newPeriod);
    }

    /// @notice Set the max pause duration (1–14 days).
    function setMaxPauseDuration(uint40 newDuration) external onlyGovernance {
        if (newDuration < 1 days || newDuration > 14 days) revert InvalidDuration();
        maxPauseDuration = newDuration;
        emit MaxPauseDurationUpdated(newDuration);
    }

    /// @notice Set the stable LP minimum age (30 min – 6 hours).
    function setStableLpMinAge(uint40 newAge) external onlyGovernance {
        if (newAge < 30 minutes || newAge > 6 hours) revert InvalidDuration();
        stableLpMinAge = newAge;
        emit StableLpMinAgeUpdated(newAge);
    }

    /// @notice Set the guardian submission deadline (6–72 hours).
    function setGuardianSubmissionDeadline(uint40 newDeadline) external onlyGovernance {
        if (newDeadline < 6 hours || newDeadline > 72 hours) revert InvalidDuration();
        guardianSubmissionDeadline = newDeadline;
        emit GuardianSubmissionDeadlineUpdated(newDeadline);
    }

    /// @notice Set a new guardian address.
    function setGuardian(address newGuardian) external onlyGovernance {
        if (newGuardian == address(0)) revert ZeroAddress();
        guardian = newGuardian;
        emit GuardianUpdated(newGuardian);
    }

    /// @notice Set the default trigger config for new pools.
    function setDefaultTriggerConfig(TriggerConfig calldata config) external onlyGovernance {
        defaultTriggerConfig = config;
        emit DefaultTriggerConfigUpdated(config);
    }

    /// @notice Update an individual pool's trigger config (governance override).
    function updatePoolTriggerConfig(PoolId poolId, TriggerConfig calldata config) external onlyGovernance {
        bytes32 key = _key(poolId);
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

        emit TriggerPending(poolId, triggerType, uint40(block.timestamp) + gracePeriod);
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

    /// @dev Compute stable LP: totalLP minus LP added within MIN_LP_AGE (RISK-4).
    function _computeStableLP(bytes32 key, uint256 totalLP) internal view returns (uint256) {
        Record[] storage additions = _lpAdditions[key];
        uint256 recentLP = 0;
        uint256 cutoff = block.timestamp > stableLpMinAge ? block.timestamp - stableLpMinAge : 0;
        uint256 len = additions.length;
        for (uint256 i; i < len; ++i) {
            if (additions[i].timestamp > cutoff) {
                recentLP += additions[i].amount;
            }
        }
        return totalLP > recentLP ? totalLP - recentLP : 0;
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
