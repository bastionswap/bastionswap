// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.26;

import {IEscrowVault} from "../interfaces/IEscrowVault.sol";
import {IReputationEngine} from "../interfaces/IReputationEngine.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EscrowVault
/// @notice LP removal permission manager. Records how much liquidity the issuer added
///         and controls how much they can remove based on the vesting schedule.
///         No tokens or ETH are ever held by this contract.
contract EscrowVault is IEscrowVault, ReentrancyGuard {
    // ─── Constants ────────────────────────────────────────────────────

    uint16 internal constant BPS_BASE = 10_000;
    uint256 internal constant MAX_SCHEDULE_LENGTH = 10;
    uint256 public constant MIN_VESTING_DURATION = 7 days;

    // Default vesting schedule milestones for comparison
    uint40 private constant DEFAULT_STEP1_TIME = 7 days;
    uint16 private constant DEFAULT_STEP1_BPS  = 1000;
    uint40 private constant DEFAULT_STEP2_TIME = 30 days;
    uint16 private constant DEFAULT_STEP2_BPS  = 3000;
    uint40 private constant DEFAULT_STEP3_TIME = 90 days;
    uint16 private constant DEFAULT_STEP3_BPS  = 10_000;

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
        IssuerCommitment commitment;
        bool isTriggered;
        uint8 triggerType;
    }

    /// @dev escrowId => Escrow
    mapping(uint256 => Escrow) internal _escrows;

    /// @dev escrowId => VestingStep[]
    mapping(uint256 => VestingStep[]) internal _vestingSchedules;

    /// @dev escrowId => dayNumber => liquidity withdrawn that day
    mapping(uint256 => mapping(uint256 => uint256)) internal _dailyWithdrawn;

    /// @dev PoolId hash => escrowId (for pool-based lookups)
    mapping(bytes32 => uint256) internal _poolEscrowIds;

    // ─── Errors ───────────────────────────────────────────────────────

    error OnlyHook();
    error OnlyTriggerOracle();
    error OnlyIssuer();
    error ZeroAmount();
    error EscrowAlreadyExists();
    error EscrowNotFound();
    error EscrowTriggered();
    error EmptySchedule();
    error ScheduleTooLong();
    error ScheduleTimesNotIncreasing();
    error ScheduleBpsNotIncreasing();
    error ScheduleBpsExceedsMax();
    error ScheduleFinalBpsNot10000();
    error NothingToRelease();
    error DailyLimitExceeded();
    error CommitmentNotStricter();
    error VestingBelowMinDuration();

    // ─── Modifiers ────────────────────────────────────────────────────

    modifier onlyHook() {
        if (msg.sender != BASTION_HOOK) revert OnlyHook();
        _;
    }

    modifier onlyTriggerOracle() {
        if (msg.sender != TRIGGER_ORACLE) revert OnlyTriggerOracle();
        _;
    }

    // ─── Constructor ──────────────────────────────────────────────────

    // ─── Events (contract-level) ─────────────────────────────────────

    event ExternalCallFailed(string target, uint256 indexed escrowId);

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
        VestingStep[] calldata vestingSchedule,
        IssuerCommitment calldata commitment
    ) external onlyHook nonReentrant returns (uint256 escrowId) {
        if (liquidity == 0) revert ZeroAmount();

        escrowId = _computeEscrowId(poolId, issuer);
        if (_escrows[escrowId].createdAt != 0) revert EscrowAlreadyExists();

        _validateSchedule(vestingSchedule);

        // Store escrow
        _escrows[escrowId] = Escrow({
            issuer: issuer,
            totalLiquidity: liquidity,
            removedLiquidity: 0,
            createdAt: uint40(block.timestamp),
            commitment: commitment,
            isTriggered: false,
            triggerType: 0
        });

        // Map poolId to escrowId for pool-based lookups
        _poolEscrowIds[PoolId.unwrap(poolId)] = escrowId;

        // Copy vesting schedule to storage
        for (uint256 i; i < vestingSchedule.length; ++i) {
            _vestingSchedules[escrowId].push(vestingSchedule[i]);
        }

        emit EscrowCreated(escrowId, poolId, issuer, liquidity);
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

        uint128 vestedLiq = _calculateVestedLiquidity(escrow, _vestingSchedules[escrowId]);
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

        uint128 vestedLiq = _calculateVestedLiquidity(escrow, _vestingSchedules[escrowId]);
        return vestedLiq > escrow.removedLiquidity ? vestedLiq - escrow.removedLiquidity : 0;
    }

    /// @inheritdoc IEscrowVault
    function triggerLockdown(uint256 escrowId, uint8 triggerType_)
        external
        onlyTriggerOracle
        nonReentrant
    {
        Escrow storage escrow = _escrows[escrowId];
        if (escrow.createdAt == 0) revert EscrowNotFound();
        if (escrow.isTriggered) revert EscrowTriggered();

        escrow.isTriggered = true;
        escrow.triggerType = triggerType_;

        emit Lockdown(escrowId, triggerType_);
    }

    /// @inheritdoc IEscrowVault
    function calculateVestedLiquidity(uint256 escrowId) external view returns (uint128) {
        Escrow storage escrow = _escrows[escrowId];
        if (escrow.createdAt == 0) revert EscrowNotFound();
        return _calculateVestedLiquidity(escrow, _vestingSchedules[escrowId]);
    }

    /// @inheritdoc IEscrowVault
    function setCommitment(uint256 escrowId, IssuerCommitment calldata newCommitment) external {
        Escrow storage escrow = _escrows[escrowId];
        if (escrow.createdAt == 0) revert EscrowNotFound();
        if (msg.sender != escrow.issuer) revert OnlyIssuer();
        if (escrow.isTriggered) revert EscrowTriggered();

        IssuerCommitment memory current = escrow.commitment;

        bool isStricter = newCommitment.dailyWithdrawLimit <= current.dailyWithdrawLimit
            && newCommitment.lockDuration >= current.lockDuration
            && newCommitment.maxSellPercent <= current.maxSellPercent;

        bool isChanged = newCommitment.dailyWithdrawLimit != current.dailyWithdrawLimit
            || newCommitment.lockDuration != current.lockDuration
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

        {
            VestingStep[] storage schedule = _vestingSchedules[escrowId];
            uint256 elapsed = block.timestamp - escrow.createdAt;
            uint256 effectiveElapsed = elapsed > escrow.commitment.lockDuration
                ? elapsed - escrow.commitment.lockDuration
                : 0;

            for (uint256 i; i < schedule.length; ++i) {
                if (schedule[i].timeOffset > effectiveElapsed) {
                    status.nextUnlockTime =
                        escrow.createdAt + escrow.commitment.lockDuration + schedule[i].timeOffset;
                    break;
                }
            }
        }
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

        VestingStep[] storage schedule = _vestingSchedules[escrowId];
        if (schedule.length == 0) return 0;

        endTime = escrow.createdAt + escrow.commitment.lockDuration + schedule[schedule.length - 1].timeOffset;
    }

    // ─── Internal Functions ───────────────────────────────────────────

    function _computeEscrowId(PoolId poolId, address issuer) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(poolId, issuer)));
    }

    function _validateSchedule(VestingStep[] calldata schedule) internal pure {
        uint256 len = schedule.length;
        if (len == 0) revert EmptySchedule();
        if (len > MAX_SCHEDULE_LENGTH) revert ScheduleTooLong();

        uint40 prevTime = 0;
        uint16 prevBps = 0;

        for (uint256 i; i < len; ++i) {
            if (i > 0) {
                if (schedule[i].timeOffset <= prevTime) revert ScheduleTimesNotIncreasing();
                if (schedule[i].basisPoints <= prevBps) revert ScheduleBpsNotIncreasing();
            }
            if (schedule[i].basisPoints > BPS_BASE) revert ScheduleBpsExceedsMax();

            prevTime = schedule[i].timeOffset;
            prevBps = schedule[i].basisPoints;
        }

        if (schedule[len - 1].timeOffset < MIN_VESTING_DURATION) revert VestingBelowMinDuration();
        if (schedule[len - 1].basisPoints != BPS_BASE) revert ScheduleFinalBpsNot10000();
    }

    function _calculateVestedLiquidity(Escrow storage escrow, VestingStep[] storage schedule)
        internal
        view
        returns (uint128)
    {
        uint256 elapsed = block.timestamp - escrow.createdAt;

        // Respect lockDuration: no vesting until lock period passes
        if (elapsed <= escrow.commitment.lockDuration) return 0;
        uint256 effectiveElapsed = elapsed - escrow.commitment.lockDuration;

        uint16 vestedBps = 0;
        for (uint256 i; i < schedule.length; ++i) {
            if (schedule[i].timeOffset <= effectiveElapsed) {
                vestedBps = schedule[i].basisPoints;
            } else {
                break;
            }
        }

        return uint128((uint256(escrow.totalLiquidity) * vestedBps) / BPS_BASE);
    }

    /// @dev Compute the cumulative bps a schedule would have released at a given timeOffset.
    function _bpsAtTime(VestingStep[] storage schedule, uint40 timeOffset) internal view returns (uint16) {
        uint16 bps = 0;
        for (uint256 i; i < schedule.length; ++i) {
            if (schedule[i].timeOffset <= timeOffset) {
                bps = schedule[i].basisPoints;
            } else {
                break;
            }
        }
        return bps;
    }

    // ─── Strictness View Functions ────────────────────────────────────

    /// @inheritdoc IEscrowVault
    function isStricterThanDefault(uint256 escrowId) external view returns (bool) {
        Escrow storage escrow = _escrows[escrowId];
        if (escrow.createdAt == 0) revert EscrowNotFound();
        return _getStrictnessLevel(escrowId) >= 1;
    }

    /// @inheritdoc IEscrowVault
    function getVestingStrictnessLevel(uint256 escrowId) external view returns (uint8) {
        Escrow storage escrow = _escrows[escrowId];
        if (escrow.createdAt == 0) revert EscrowNotFound();
        return _getStrictnessLevel(escrowId);
    }

    /// @inheritdoc IEscrowVault
    function getVestingSchedule(uint256 escrowId) external view returns (VestingStep[] memory) {
        Escrow storage escrow = _escrows[escrowId];
        if (escrow.createdAt == 0) revert EscrowNotFound();
        return _vestingSchedules[escrowId];
    }

    /// @inheritdoc IEscrowVault
    function getEscrowInfo(uint256 escrowId) external view returns (uint40 createdAt, IssuerCommitment memory commitment) {
        Escrow storage escrow = _escrows[escrowId];
        if (escrow.createdAt == 0) revert EscrowNotFound();
        createdAt = escrow.createdAt;
        commitment = escrow.commitment;
    }

    /// @dev Returns 2 = stricter, 1 = same as default, 0 = looser
    function _getStrictnessLevel(uint256 escrowId) internal view returns (uint8) {
        uint256 score = _getStrictnessScore(escrowId);
        if (score == 0) {
            VestingStep[] storage schedule = _vestingSchedules[escrowId];
            if (schedule.length == 0) return 0;
            uint40 totalDuration = schedule[schedule.length - 1].timeOffset;
            if (totalDuration < DEFAULT_STEP3_TIME) return 0;
            uint16 bps1 = _bpsAtTime(schedule, DEFAULT_STEP1_TIME);
            uint16 bps2 = _bpsAtTime(schedule, DEFAULT_STEP2_TIME);
            uint16 bps3 = _bpsAtTime(schedule, DEFAULT_STEP3_TIME);
            if (bps1 > DEFAULT_STEP1_BPS || bps2 > DEFAULT_STEP2_BPS || bps3 > DEFAULT_STEP3_BPS) {
                return 0;
            }
            return 1;
        }
        return 2;
    }

    /// @dev Proportional strictness score (0..200).
    function _getStrictnessScore(uint256 escrowId) internal view returns (uint256) {
        VestingStep[] storage schedule = _vestingSchedules[escrowId];
        if (schedule.length == 0) return 0;

        uint40 totalDuration = schedule[schedule.length - 1].timeOffset;
        if (totalDuration < DEFAULT_STEP3_TIME) return 0;

        uint16 bps1 = _bpsAtTime(schedule, DEFAULT_STEP1_TIME);
        uint16 bps2 = _bpsAtTime(schedule, DEFAULT_STEP2_TIME);
        uint16 bps3 = _bpsAtTime(schedule, DEFAULT_STEP3_TIME);

        if (bps1 > DEFAULT_STEP1_BPS || bps2 > DEFAULT_STEP2_BPS || bps3 > DEFAULT_STEP3_BPS) {
            return 0;
        }

        uint256 saving1 = uint256(DEFAULT_STEP1_BPS - bps1) * BPS_BASE / DEFAULT_STEP1_BPS;
        uint256 saving2 = uint256(DEFAULT_STEP2_BPS - bps2) * BPS_BASE / DEFAULT_STEP2_BPS;
        uint256 saving3 = uint256(DEFAULT_STEP3_BPS - bps3) * BPS_BASE / DEFAULT_STEP3_BPS;

        uint256 extraDuration = totalDuration > DEFAULT_STEP3_TIME
            ? uint256(totalDuration - DEFAULT_STEP3_TIME)
            : 0;
        uint256 durationBonus = extraDuration * BPS_BASE / uint256(DEFAULT_STEP3_TIME);
        if (durationBonus > BPS_BASE) durationBonus = BPS_BASE;

        return ((saving1 + saving2 + saving3 + durationBonus) * 200) / (4 * BPS_BASE);
    }

    /// @notice Returns a proportional strictness score (0..200) for reputation scoring.
    /// @param escrowId Identifier of the escrow position
    /// @return score 0 = default or looser, up to 200 = maximum strictness
    function getVestingStrictnessScore(uint256 escrowId) external view returns (uint256 score) {
        Escrow storage escrow = _escrows[escrowId];
        if (escrow.createdAt == 0) revert EscrowNotFound();
        return _getStrictnessScore(escrowId);
    }
}
