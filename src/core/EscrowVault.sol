// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IEscrowVault} from "../interfaces/IEscrowVault.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

/// @title EscrowVault
/// @notice Manages time-locked and condition-based vesting of issuer LP funds.
contract EscrowVault is IEscrowVault, ReentrancyGuard {
    using SafeTransferLib for ERC20;

    // ─── Constants ────────────────────────────────────────────────────

    uint16 internal constant BPS_BASE = 10_000;
    uint256 internal constant MAX_SCHEDULE_LENGTH = 10;

    // ─── Immutables ───────────────────────────────────────────────────

    address public immutable BASTION_HOOK;
    address public immutable TRIGGER_ORACLE;
    address public immutable INSURANCE_POOL;

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

    constructor(address bastionHook, address triggerOracle, address insurancePool) {
        BASTION_HOOK = bastionHook;
        TRIGGER_ORACLE = triggerOracle;
        INSURANCE_POOL = insurancePool;
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

    // ─── Internal Functions ───────────────────────────────────────────

    function _computeEscrowId(PoolId poolId, address issuer) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(poolId, issuer)));
    }

    function _validateSchedule(VestingStep[] calldata schedule) internal pure {
        uint256 len = schedule.length;
        if (len == 0) revert EmptySchedule();
        if (len > MAX_SCHEDULE_LENGTH) revert ScheduleTooLong();

        uint40 prevTime;
        uint16 prevBps;

        for (uint256 i; i < len; ++i) {
            if (i > 0) {
                if (schedule[i].timeOffset <= prevTime) revert ScheduleTimesNotIncreasing();
                if (schedule[i].basisPoints <= prevBps) revert ScheduleBpsNotIncreasing();
            }
            if (schedule[i].basisPoints > BPS_BASE) revert ScheduleBpsExceedsMax();

            prevTime = schedule[i].timeOffset;
            prevBps = schedule[i].basisPoints;
        }

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

        uint16 vestedBps;
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
}
