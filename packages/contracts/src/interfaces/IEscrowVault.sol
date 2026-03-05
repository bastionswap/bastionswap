// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title IEscrowVault
/// @notice LP removal permission manager. Records how much liquidity the issuer added
///         and controls how much they can remove based on the vesting schedule.
///         No tokens or ETH are held by the vault. BastionHook's beforeRemoveLiquidity
///         is the enforcement point.
interface IEscrowVault {
    // ─── Structs ──────────────────────────────────────────────────────

    /// @notice Defines the issuer's up-front commitments that are enforced on-chain.
    /// @param dailyWithdrawLimit Maximum percentage (basis points) of LP the issuer can withdraw per day
    /// @param lockDuration Minimum total lock duration in seconds before any vesting begins
    /// @param maxSellPercent Maximum percentage (basis points) of token supply the issuer may sell per 24h window
    struct IssuerCommitment {
        uint16 dailyWithdrawLimit;
        uint40 lockDuration;
        uint16 maxSellPercent;
    }

    /// @notice Defines a single step in a vesting schedule.
    /// @param timeOffset Seconds after escrow creation when this tranche unlocks
    /// @param basisPoints Cumulative percentage (basis points, max 10_000) of total escrowed liquidity released
    struct VestingStep {
        uint40 timeOffset;
        uint16 basisPoints;
    }

    /// @notice Full status snapshot of an escrow position.
    /// @param totalLiquidity Original liquidity amount locked
    /// @param removedLiquidity Cumulative liquidity already removed by the issuer
    /// @param remainingLiquidity Liquidity still locked
    /// @param nextUnlockTime Timestamp of the next vesting tranche unlock (0 if fully vested)
    struct EscrowStatus {
        uint128 totalLiquidity;
        uint128 removedLiquidity;
        uint128 remainingLiquidity;
        uint40 nextUnlockTime;
    }

    // ─── Events ───────────────────────────────────────────────────────

    /// @notice Emitted when a new escrow position is created.
    /// @param escrowId Unique identifier for the escrow
    /// @param poolId Uniswap V4 pool identifier
    /// @param issuer Address of the token issuer
    /// @param liquidity Total liquidity locked
    event EscrowCreated(uint256 indexed escrowId, PoolId indexed poolId, address indexed issuer, uint128 liquidity);

    /// @notice Emitted when LP removal is recorded for the issuer.
    /// @param escrowId Escrow identifier
    /// @param liquidityRemoved Amount of liquidity removed in this transaction
    event LPRemovalRecorded(uint256 indexed escrowId, uint128 liquidityRemoved);

    /// @notice Emitted when escrow is locked down due to a trigger event.
    /// @param escrowId Escrow identifier
    /// @param triggerType Type of trigger that caused the lockdown
    event Lockdown(uint256 indexed escrowId, uint8 indexed triggerType);

    /// @notice Emitted when an issuer updates their commitment to stricter values.
    /// @param escrowId Escrow identifier
    /// @param newCommitment The updated commitment parameters
    event CommitmentSet(uint256 indexed escrowId, IssuerCommitment newCommitment);

    // ─── Functions ────────────────────────────────────────────────────

    /// @notice Creates a new escrow position recording the issuer's LP liquidity.
    /// @param poolId Uniswap V4 pool identifier
    /// @param issuer Address of the token issuer whose LP is being escrowed
    /// @param liquidity Total liquidity amount to lock
    /// @param vestingSchedule Ordered array of vesting steps defining the release schedule
    /// @param commitment Issuer's up-front commitment parameters
    /// @return escrowId Unique identifier for the newly created escrow
    function createEscrow(
        PoolId poolId,
        address issuer,
        uint128 liquidity,
        VestingStep[] calldata vestingSchedule,
        IssuerCommitment calldata commitment
    ) external returns (uint256 escrowId);

    /// @notice Records an LP removal by the issuer. Called by BastionHook.
    /// @dev Enforces daily withdraw limits and updates removedLiquidity.
    /// @param escrowId Identifier of the escrow position
    /// @param liquidityRemoved Amount of liquidity being removed
    function recordLPRemoval(uint256 escrowId, uint128 liquidityRemoved) external;

    /// @notice Returns the amount of liquidity the issuer can currently remove.
    /// @param escrowId Identifier of the escrow position
    /// @return removable Amount of liquidity removable right now
    function getRemovableLiquidity(uint256 escrowId) external view returns (uint128 removable);

    /// @notice Locks down the escrow due to a trigger event. No LP removal allowed after this.
    /// @dev Can only be called by the TriggerOracle.
    /// @param escrowId Identifier of the escrow position
    /// @param triggerType The type of trigger event that occurred
    function triggerLockdown(uint256 escrowId, uint8 triggerType) external;

    /// @notice Calculates the total liquidity vested so far for an escrow.
    /// @param escrowId Identifier of the escrow position
    /// @return vestedLiquidity Cumulative liquidity vested (before subtracting removed)
    function calculateVestedLiquidity(uint256 escrowId) external view returns (uint128 vestedLiquidity);

    /// @notice Updates the issuer's commitment to stricter values only.
    /// @param escrowId Identifier of the escrow position
    /// @param newCommitment The new commitment values (must be stricter than current)
    function setCommitment(uint256 escrowId, IssuerCommitment calldata newCommitment) external;

    /// @notice Returns the current status of an escrow position.
    /// @param escrowId Identifier of the escrow position
    /// @return status Full status snapshot including liquidity amounts and next unlock
    function getEscrowStatus(uint256 escrowId) external view returns (EscrowStatus memory status);

    /// @notice Checks whether an escrow position is fully vested (all liquidity removed).
    /// @param poolId Uniswap V4 pool identifier
    /// @return True if the escrow's removedLiquidity equals its totalLiquidity
    function isFullyVested(PoolId poolId) external view returns (bool);

    /// @notice Returns the timestamp when the last vesting tranche unlocks.
    /// @param poolId Uniswap V4 pool identifier
    /// @return endTime Timestamp of the final vesting unlock
    function getVestingEndTime(PoolId poolId) external view returns (uint256 endTime);

    /// @notice Checks if the escrow's vesting schedule is at least as strict as the default.
    /// @param escrowId Identifier of the escrow position
    /// @return True if at every default milestone time point, the custom schedule
    ///         has vested <= the default amount AND total duration >= 90 days
    function isStricterThanDefault(uint256 escrowId) external view returns (bool);

    /// @notice Returns the strictness level of the escrow's vesting schedule vs default.
    /// @param escrowId Identifier of the escrow position
    /// @return level 2 = stricter than default, 1 = same as default, 0 = looser than default
    function getVestingStrictnessLevel(uint256 escrowId) external view returns (uint8 level);

    /// @notice Returns the vesting schedule for an escrow position.
    /// @param escrowId Identifier of the escrow position
    /// @return schedule Array of vesting steps
    function getVestingSchedule(uint256 escrowId) external view returns (VestingStep[] memory schedule);

    /// @notice Returns the escrow's creation timestamp and commitment parameters.
    /// @param escrowId Identifier of the escrow position
    /// @return createdAt Timestamp when the escrow was created
    /// @return commitment The issuer's commitment parameters
    function getEscrowInfo(uint256 escrowId) external view returns (uint40 createdAt, IssuerCommitment memory commitment);

    /// @notice Returns a proportional strictness score (0..200) for reputation scoring.
    /// @param escrowId Identifier of the escrow position
    /// @return score 0 = default or looser, up to 200 = maximum strictness
    function getVestingStrictnessScore(uint256 escrowId) external view returns (uint256 score);
}
