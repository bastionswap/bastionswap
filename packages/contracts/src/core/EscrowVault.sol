// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.26;

import {IEscrowVault} from "../interfaces/IEscrowVault.sol";
import {IReputationEngine} from "../interfaces/IReputationEngine.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// @title EscrowVault
/// @notice Manages time-locked and condition-based vesting of issuer LP funds.
contract EscrowVault is IEscrowVault, ReentrancyGuard {
    using SafeTransferLib for ERC20;

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
    address public immutable INSURANCE_POOL;
    IReputationEngine public immutable REPUTATION_ENGINE;

    // ─── Storage ──────────────────────────────────────────────────────

    struct Escrow {
        address issuer;
        address token;
        uint256 totalAmount;
        uint256 releasedAmount;
        uint40 createdAt;
        IssuerCommitment commitment;
        bool isTriggered;
        uint8 triggerType;
    }

    /// @dev escrowId => Escrow
    mapping(uint256 => Escrow) internal _escrows;

    /// @dev escrowId => VestingStep[]
    mapping(uint256 => VestingStep[]) internal _vestingSchedules;

    /// @dev escrowId => dayNumber => amount withdrawn that day
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

    constructor(address bastionHook, address triggerOracle, address insurancePool, address reputationEngine) {
        BASTION_HOOK = bastionHook;
        TRIGGER_ORACLE = triggerOracle;
        INSURANCE_POOL = insurancePool;
        REPUTATION_ENGINE = IReputationEngine(reputationEngine);
    }

    // ─── External Functions ───────────────────────────────────────────

    /// @inheritdoc IEscrowVault
    function createEscrow(
        PoolId poolId,
        address issuer,
        address token,
        uint256 amount,
        VestingStep[] calldata vestingSchedule,
        IssuerCommitment calldata commitment
    ) external onlyHook nonReentrant returns (uint256 escrowId) {
        if (amount == 0) revert ZeroAmount();

        escrowId = _computeEscrowId(poolId, issuer);
        if (_escrows[escrowId].createdAt != 0) revert EscrowAlreadyExists();

        _validateSchedule(vestingSchedule);

        // Store escrow
        _escrows[escrowId] = Escrow({
            issuer: issuer,
            token: token,
            totalAmount: amount,
            releasedAmount: 0,
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

        // Pull tokens from caller (BastionHook)
        ERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        emit EscrowCreated(escrowId, poolId, issuer, amount);
    }

    /// @inheritdoc IEscrowVault
    function releaseVested(uint256 escrowId) external nonReentrant returns (uint256 releasedAmount) {
        Escrow storage escrow = _escrows[escrowId];
        if (escrow.createdAt == 0) revert EscrowNotFound();
        if (msg.sender != escrow.issuer) revert OnlyIssuer();
        if (escrow.isTriggered) revert EscrowTriggered();

        uint256 totalVested = _calculateVestedAmount(escrow, _vestingSchedules[escrowId]);
        uint256 releasable = totalVested - escrow.releasedAmount;
        if (releasable == 0) revert NothingToRelease();

        // Enforce daily withdraw limit
        if (escrow.commitment.dailyWithdrawLimit > 0) {
            uint256 dayNumber = block.timestamp / 1 days;
            uint256 dailyMax = (escrow.totalAmount * escrow.commitment.dailyWithdrawLimit) / BPS_BASE;
            uint256 alreadyToday = _dailyWithdrawn[escrowId][dayNumber];

            if (alreadyToday + releasable > dailyMax) {
                releasable = dailyMax > alreadyToday ? dailyMax - alreadyToday : 0;
                if (releasable == 0) revert DailyLimitExceeded();
            }

            _dailyWithdrawn[escrowId][dayNumber] = alreadyToday + releasable;
        }

        // CEI: update state before transfer
        escrow.releasedAmount += releasable;
        releasedAmount = releasable;

        ERC20(escrow.token).safeTransfer(escrow.issuer, releasedAmount);

        emit VestedReleased(escrowId, releasedAmount);

        // Record escrow completion in reputation engine when fully vested
        if (escrow.releasedAmount == escrow.totalAmount) {
            uint256 durationDays = (block.timestamp - escrow.createdAt) / 1 days;
            try REPUTATION_ENGINE.recordEvent(
                escrow.issuer,
                IReputationEngine.EventType.ESCROW_COMPLETED,
                abi.encode(escrow.totalAmount, durationDays)
            ) {} catch {
                emit ExternalCallFailed("ReputationEngine.recordEvent", escrowId);
            }
        }
    }

    /// @inheritdoc IEscrowVault
    function triggerRedistribution(uint256 escrowId, uint8 triggerType_)
        external
        onlyTriggerOracle
        nonReentrant
        returns (uint256 redistributedAmount)
    {
        Escrow storage escrow = _escrows[escrowId];
        if (escrow.createdAt == 0) revert EscrowNotFound();
        if (escrow.isTriggered) revert EscrowTriggered();

        redistributedAmount = escrow.totalAmount - escrow.releasedAmount;

        // CEI: update state before transfer
        escrow.isTriggered = true;
        escrow.triggerType = triggerType_;

        ERC20(escrow.token).safeTransfer(INSURANCE_POOL, redistributedAmount);

        emit Redistributed(escrowId, triggerType_, redistributedAmount);
    }

    /// @inheritdoc IEscrowVault
    function calculateVestedAmount(uint256 escrowId) external view returns (uint256) {
        Escrow storage escrow = _escrows[escrowId];
        if (escrow.createdAt == 0) revert EscrowNotFound();
        return _calculateVestedAmount(escrow, _vestingSchedules[escrowId]);
    }

    /// @inheritdoc IEscrowVault
    function setCommitment(uint256 escrowId, IssuerCommitment calldata newCommitment) external {
        Escrow storage escrow = _escrows[escrowId];
        if (escrow.createdAt == 0) revert EscrowNotFound();
        if (msg.sender != escrow.issuer) revert OnlyIssuer();
        if (escrow.isTriggered) revert EscrowTriggered();

        IssuerCommitment memory current = escrow.commitment;

        // New commitment must be strictly at least as strict as current
        // dailyWithdrawLimit: lower or equal is stricter
        // lockDuration: longer or equal is stricter
        // maxSellPercent: lower or equal is stricter
        bool isStricter = newCommitment.dailyWithdrawLimit <= current.dailyWithdrawLimit
            && newCommitment.lockDuration >= current.lockDuration
            && newCommitment.maxSellPercent <= current.maxSellPercent;

        // Must actually change at least one field
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

        status.totalLocked = escrow.totalAmount;
        status.released = escrow.releasedAmount;

        if (escrow.isTriggered) {
            status.remaining = 0;
            return status;
        }

        status.remaining = escrow.totalAmount - escrow.releasedAmount;

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
        return escrow.releasedAmount == escrow.totalAmount;
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

    function _calculateVestedAmount(Escrow storage escrow, VestingStep[] storage schedule)
        internal
        view
        returns (uint256)
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

        // Round down: (totalAmount * vestedBps) / BPS_BASE
        return (escrow.totalAmount * vestedBps) / BPS_BASE;
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
        VestingStep[] storage schedule = _vestingSchedules[escrowId];
        if (schedule.length == 0) return 0;

        // Total duration must be >= default (90 days)
        uint40 totalDuration = schedule[schedule.length - 1].timeOffset;
        if (totalDuration < DEFAULT_STEP3_TIME) return 0;

        // Check at each default milestone: custom bps must be <= default bps
        uint16 bps1 = _bpsAtTime(schedule, DEFAULT_STEP1_TIME);
        uint16 bps2 = _bpsAtTime(schedule, DEFAULT_STEP2_TIME);
        uint16 bps3 = _bpsAtTime(schedule, DEFAULT_STEP3_TIME);

        if (bps1 > DEFAULT_STEP1_BPS || bps2 > DEFAULT_STEP2_BPS || bps3 > DEFAULT_STEP3_BPS) {
            return 0; // looser
        }

        // Check if exactly same as default
        if (bps1 == DEFAULT_STEP1_BPS && bps2 == DEFAULT_STEP2_BPS && bps3 == DEFAULT_STEP3_BPS
            && totalDuration == DEFAULT_STEP3_TIME) {
            return 1; // same
        }

        return 2; // stricter
    }
}
