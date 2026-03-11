// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.26;

import {IEscrowVault} from "../interfaces/IEscrowVault.sol";
import {IBastionHook} from "../interfaces/IBastionHook.sol";
import {IReputationEngine} from "../interfaces/IReputationEngine.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EscrowVault
/// @notice LP removal permission manager. Records how much liquidity the issuer added
///         and controls how much they can remove based on lock + linear vesting.
///         No tokens or ETH are ever held by this contract.
contract EscrowVault is IEscrowVault, ReentrancyGuard {
    // ─── Constants ────────────────────────────────────────────────────

    uint16 internal constant BPS_BASE = 10_000;
    uint256 public constant MIN_LOCK_DURATION = 7 days;
    uint256 public constant MIN_VESTING_DURATION = 7 days;


    // ─── Immutables ───────────────────────────────────────────────────

    address public immutable BASTION_HOOK;
    address public immutable TRIGGER_ORACLE;
    IReputationEngine public immutable REPUTATION_ENGINE;

    // ─── Storage ──────────────────────────────────────────────────────

    struct Escrow {
        address issuer;
        uint128 totalLiquidity;
        uint128 removedLiquidity;
        uint40 createdAt;
        uint40 lockDuration;
        uint40 vestingDuration;
        IssuerCommitment commitment;
        bool isTriggered;
        uint8 triggerType;
    }

    /// @dev escrowId => Escrow
    mapping(uint256 => Escrow) internal _escrows;

    /// @dev escrowId => dayNumber => liquidity withdrawn that day
    mapping(uint256 => mapping(uint256 => uint256)) internal _dailyWithdrawn;

    /// @dev PoolId hash => escrowId (for pool-based lookups)
    mapping(bytes32 => uint256) internal _poolEscrowIds;

    /// @dev escrowId => PoolId (reverse mapping for force removal)
    mapping(uint256 => PoolId) internal _escrowPoolIds;

    // ─── Errors ───────────────────────────────────────────────────────

    error OnlyHook();
    error OnlyTriggerOracle();
    error OnlyIssuer();
    error ZeroAmount();
    error EscrowAlreadyExists();
    error EscrowNotFound();
    error EscrowTriggered();
    error NothingToRelease();
    error DailyLimitExceeded();
    error CommitmentNotStricter();
    error LockDurationTooShort();
    error VestingDurationTooShort();

    // ─── Modifiers ────────────────────────────────────────────────────

    modifier onlyHook() {
        if (msg.sender != BASTION_HOOK) revert OnlyHook();
        _;
    }

    modifier onlyTriggerOracle() {
        if (msg.sender != TRIGGER_ORACLE) revert OnlyTriggerOracle();
        _;
    }

    // ─── Events (contract-level) ─────────────────────────────────────

    event ExternalCallFailed(string target, uint256 indexed escrowId);

    // ─── Constructor ──────────────────────────────────────────────────

    constructor(address bastionHook, address triggerOracle, address reputationEngine) {
        BASTION_HOOK = bastionHook;
        TRIGGER_ORACLE = triggerOracle;
        REPUTATION_ENGINE = IReputationEngine(reputationEngine);
    }

    // ─── External Functions ───────────────────────────────────────────

    /// @inheritdoc IEscrowVault
    function createEscrow(
        PoolId poolId,
        address issuer,
        uint128 liquidity,
        uint40 lockDuration,
        uint40 vestingDuration,
        IssuerCommitment calldata commitment
    ) external onlyHook nonReentrant returns (uint256 escrowId) {
        if (liquidity == 0) revert ZeroAmount();
        if (lockDuration < MIN_LOCK_DURATION) revert LockDurationTooShort();
        if (vestingDuration < MIN_VESTING_DURATION) revert VestingDurationTooShort();

        escrowId = _computeEscrowId(poolId, issuer);
        if (_escrows[escrowId].createdAt != 0) revert EscrowAlreadyExists();

        // Store escrow
        _escrows[escrowId] = Escrow({
            issuer: issuer,
            totalLiquidity: liquidity,
            removedLiquidity: 0,
            createdAt: uint40(block.timestamp),
            lockDuration: lockDuration,
            vestingDuration: vestingDuration,
            commitment: commitment,
            isTriggered: false,
            triggerType: 0
        });

        // Map poolId to escrowId for pool-based lookups
        _poolEscrowIds[PoolId.unwrap(poolId)] = escrowId;
        _escrowPoolIds[escrowId] = poolId;

        emit EscrowCreated(escrowId, poolId, issuer, liquidity, lockDuration, vestingDuration);
    }

    /// @inheritdoc IEscrowVault
    function addLiquidity(uint256 escrowId, uint128 liquidity)
        external
        onlyHook
        nonReentrant
    {
        if (liquidity == 0) revert ZeroAmount();
        Escrow storage escrow = _escrows[escrowId];
        if (escrow.createdAt == 0) revert EscrowNotFound();
        if (escrow.isTriggered) revert EscrowTriggered();

        escrow.totalLiquidity += liquidity;

        emit LiquidityAdded(escrowId, liquidity, escrow.totalLiquidity);
    }

    /// @inheritdoc IEscrowVault
    function getTotalLiquidity(uint256 escrowId) external view returns (uint128) {
        Escrow storage escrow = _escrows[escrowId];
        if (escrow.createdAt == 0) return 0;
        return escrow.totalLiquidity;
    }

    /// @inheritdoc IEscrowVault
    function recordLPRemoval(uint256 escrowId, uint128 liquidityRemoved)
        external
        onlyHook
        nonReentrant
    {
        Escrow storage escrow = _escrows[escrowId];
        if (escrow.createdAt == 0) revert EscrowNotFound();
        if (escrow.isTriggered) revert EscrowTriggered();

        uint128 vestedLiq = _calculateVestedLiquidity(escrow);
        uint128 removable = vestedLiq > escrow.removedLiquidity ? vestedLiq - escrow.removedLiquidity : 0;
        if (removable == 0) revert NothingToRelease();
        if (liquidityRemoved > removable) revert NothingToRelease();

        // Enforce daily withdraw limit
        if (escrow.commitment.dailyWithdrawLimit > 0) {
            uint256 dayNumber = block.timestamp / 1 days;
            uint256 dailyMax = (uint256(escrow.totalLiquidity) * escrow.commitment.dailyWithdrawLimit) / BPS_BASE;
            uint256 alreadyToday = _dailyWithdrawn[escrowId][dayNumber];

            if (alreadyToday + liquidityRemoved > dailyMax) {
                revert DailyLimitExceeded();
            }

            _dailyWithdrawn[escrowId][dayNumber] = alreadyToday + liquidityRemoved;
        }

        escrow.removedLiquidity += liquidityRemoved;

        emit LPRemovalRecorded(escrowId, liquidityRemoved);

        // Record escrow completion in reputation engine when fully removed
        if (escrow.removedLiquidity == escrow.totalLiquidity) {
            uint256 durationDays = (block.timestamp - escrow.createdAt) / 1 days;
            try REPUTATION_ENGINE.recordEvent(
                escrow.issuer,
                IReputationEngine.EventType.ESCROW_COMPLETED,
                abi.encode(uint256(escrow.totalLiquidity), durationDays)
            ) {} catch {
                emit ExternalCallFailed("ReputationEngine.recordEvent", escrowId);
            }
        }
    }

    /// @inheritdoc IEscrowVault
    function getRemovableLiquidity(uint256 escrowId) external view returns (uint128) {
        Escrow storage escrow = _escrows[escrowId];
        if (escrow.createdAt == 0) return 0;
        if (escrow.isTriggered) return 0;

        uint128 vestedLiq = _calculateVestedLiquidity(escrow);
        return vestedLiq > escrow.removedLiquidity ? vestedLiq - escrow.removedLiquidity : 0;
    }

    /// @inheritdoc IEscrowVault
    function triggerForceRemoval(uint256 escrowId, uint8 triggerType_)
        external
        onlyTriggerOracle
        nonReentrant
    {
        Escrow storage escrow = _escrows[escrowId];
        if (escrow.createdAt == 0) revert EscrowNotFound();
        if (escrow.isTriggered) revert EscrowTriggered();

        // CEI: effects before interactions
        escrow.isTriggered = true;
        escrow.triggerType = triggerType_;

        // Compute remaining liquidity to seize
        uint128 remainingLiquidity = escrow.totalLiquidity - escrow.removedLiquidity;
        escrow.removedLiquidity = escrow.totalLiquidity; // all seized

        // Force-remove issuer LP via hook → router → poolManager
        if (remainingLiquidity > 0) {
            // Look up the poolId for this escrow
            PoolId poolId = _escrowPoolIds[escrowId];
            // Use low-level call to safely handle non-contract addresses and reverts
            (bool success, bytes memory reason) = BASTION_HOOK.call(
                abi.encodeCall(IBastionHook.forceRemoveIssuerLP, (poolId))
            );
            if (success) {
                emit ForceRemoval(escrowId, triggerType_, remainingLiquidity);
            } else {
                emit ForceRemovalFailed(escrowId, reason);
            }
        } else {
            emit ForceRemoval(escrowId, triggerType_, 0);
        }
    }

    /// @inheritdoc IEscrowVault
    function calculateVestedLiquidity(uint256 escrowId) external view returns (uint128) {
        Escrow storage escrow = _escrows[escrowId];
        if (escrow.createdAt == 0) revert EscrowNotFound();
        return _calculateVestedLiquidity(escrow);
    }

    /// @inheritdoc IEscrowVault
    function setCommitment(uint256 escrowId, IssuerCommitment calldata newCommitment) external {
        Escrow storage escrow = _escrows[escrowId];
        if (escrow.createdAt == 0) revert EscrowNotFound();
        if (msg.sender != escrow.issuer) revert OnlyIssuer();
        if (escrow.isTriggered) revert EscrowTriggered();

        IssuerCommitment memory current = escrow.commitment;

        bool isStricter = newCommitment.dailyWithdrawLimit <= current.dailyWithdrawLimit
            && newCommitment.maxSellPercent <= current.maxSellPercent;

        bool isChanged = newCommitment.dailyWithdrawLimit != current.dailyWithdrawLimit
            || newCommitment.maxSellPercent != current.maxSellPercent;

        if (!isStricter || !isChanged) revert CommitmentNotStricter();

        escrow.commitment = newCommitment;

        emit CommitmentSet(escrowId, newCommitment);
    }

    /// @inheritdoc IEscrowVault
    function getEscrowStatus(uint256 escrowId) external view returns (EscrowStatus memory status) {
        Escrow storage escrow = _escrows[escrowId];
        if (escrow.createdAt == 0) revert EscrowNotFound();

        status.totalLiquidity = escrow.totalLiquidity;
        status.removedLiquidity = escrow.removedLiquidity;

        if (escrow.isTriggered) {
            status.remainingLiquidity = 0;
            return status;
        }

        status.remainingLiquidity = escrow.totalLiquidity - escrow.removedLiquidity;

        // nextUnlockTime: when does the lock period end (i.e., when vesting starts)?
        uint256 lockEnd = uint256(escrow.createdAt) + uint256(escrow.lockDuration);
        if (block.timestamp < lockEnd) {
            status.nextUnlockTime = uint40(lockEnd);
        }
        // If already past lock, nextUnlockTime = 0 (vesting is actively happening or complete)
    }

    /// @inheritdoc IEscrowVault
    function isFullyVested(PoolId poolId) external view returns (bool) {
        uint256 escrowId = _poolEscrowIds[PoolId.unwrap(poolId)];
        Escrow storage escrow = _escrows[escrowId];
        if (escrow.createdAt == 0) return false;
        return escrow.removedLiquidity == escrow.totalLiquidity;
    }

    /// @inheritdoc IEscrowVault
    function getVestingEndTime(PoolId poolId) external view returns (uint256 endTime) {
        uint256 escrowId = _poolEscrowIds[PoolId.unwrap(poolId)];
        Escrow storage escrow = _escrows[escrowId];
        if (escrow.createdAt == 0) return 0;

        endTime = uint256(escrow.createdAt) + uint256(escrow.lockDuration) + uint256(escrow.vestingDuration);
    }

    // ─── Internal Functions ───────────────────────────────────────────

    function _computeEscrowId(PoolId poolId, address issuer) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(poolId, issuer)));
    }

    /// @dev Linear vesting: 0 during lock, then linearly from 0 to totalLiquidity over vestingDuration
    function _calculateVestedLiquidity(Escrow storage escrow)
        internal
        view
        returns (uint128)
    {
        uint256 elapsed = block.timestamp - escrow.createdAt;

        // During lock period: nothing vested
        if (elapsed < escrow.lockDuration) return 0;

        uint256 vestingElapsed = elapsed - escrow.lockDuration;

        // Fully vested
        if (vestingElapsed >= escrow.vestingDuration) return escrow.totalLiquidity;

        // Linear interpolation
        return uint128((uint256(escrow.totalLiquidity) * vestingElapsed) / escrow.vestingDuration);
    }

    // ─── Strictness View Functions ────────────────────────────────────

    /// @inheritdoc IEscrowVault
    function isStricterThanDefault(uint256 escrowId) external view returns (bool) {
        Escrow storage escrow = _escrows[escrowId];
        if (escrow.createdAt == 0) revert EscrowNotFound();
        return _getStrictnessLevel(escrow) >= 1;
    }

    /// @inheritdoc IEscrowVault
    function getVestingStrictnessLevel(uint256 escrowId) external view returns (uint8) {
        Escrow storage escrow = _escrows[escrowId];
        if (escrow.createdAt == 0) revert EscrowNotFound();
        return _getStrictnessLevel(escrow);
    }

    /// @inheritdoc IEscrowVault
    function getEscrowInfo(uint256 escrowId)
        external
        view
        returns (uint40 createdAt, uint40 lockDuration, uint40 vestingDuration, IssuerCommitment memory commitment)
    {
        Escrow storage escrow = _escrows[escrowId];
        if (escrow.createdAt == 0) revert EscrowNotFound();
        createdAt = escrow.createdAt;
        lockDuration = escrow.lockDuration;
        vestingDuration = escrow.vestingDuration;
        commitment = escrow.commitment;
    }

    /// @dev Returns 2 = stricter, 1 = same as default, 0 = looser
    ///      Reads governance defaults from BastionHook dynamically.
    function _getStrictnessLevel(Escrow storage escrow) internal view returns (uint8) {
        uint40 defLock = IBastionHook(BASTION_HOOK).defaultLockDuration();
        uint40 defVesting = IBastionHook(BASTION_HOOK).defaultVestingDuration();
        uint40 defTotal = defLock + defVesting;
        uint40 totalDuration = escrow.lockDuration + escrow.vestingDuration;

        if (totalDuration < defTotal) return 0;

        if (escrow.lockDuration == defLock && escrow.vestingDuration == defVesting) {
            return 1; // same as default
        }

        if (totalDuration > defTotal) return 2; // stricter
        // totalDuration == defTotal but different split
        if (escrow.lockDuration >= defLock) return 1; // at least same
        return 0; // shorter lock with same total = looser
    }

    /// @dev Proportional strictness score (0..200).
    ///      Based on how much the total duration exceeds the governance default.
    function _getStrictnessScore(Escrow storage escrow) internal view returns (uint256) {
        uint40 defTotal = IBastionHook(BASTION_HOOK).defaultLockDuration()
            + IBastionHook(BASTION_HOOK).defaultVestingDuration();
        uint40 totalDuration = escrow.lockDuration + escrow.vestingDuration;
        if (totalDuration <= defTotal) return 0;

        // Extra duration ratio capped at 200
        uint256 extraDuration = uint256(totalDuration) - uint256(defTotal);
        uint256 score = (extraDuration * 200) / uint256(defTotal);
        if (score > 200) score = 200;
        return score;
    }

    /// @inheritdoc IEscrowVault
    function isTriggered(uint256 escrowId) external view returns (bool) {
        return _escrows[escrowId].isTriggered;
    }

    /// @notice Returns a proportional strictness score (0..200) for reputation scoring.
    /// @param escrowId Identifier of the escrow position
    /// @return score 0 = default or looser, up to 200 = maximum strictness
    function getVestingStrictnessScore(uint256 escrowId) external view returns (uint256 score) {
        Escrow storage escrow = _escrows[escrowId];
        if (escrow.createdAt == 0) revert EscrowNotFound();
        return _getStrictnessScore(escrow);
    }
}
