// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title IEscrowVault
/// @notice Manages time-locked and condition-based vesting of token issuer LP funds.
///         Issuer liquidity is automatically escrowed upon pool creation and released
///         according to a predefined vesting schedule. If an on-chain trigger event occurs,
///         remaining escrowed funds are redistributed pro-rata to token holders.
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
    /// @param basisPoints Cumulative percentage (basis points, max 10_000) of total escrowed amount released
    struct VestingStep {
        uint40 timeOffset;
        uint16 basisPoints;
    }

    /// @notice Full status snapshot of an escrow position.
    /// @param totalLocked Original amount deposited into escrow
    /// @param released Cumulative amount already released to the issuer
    /// @param remaining Amount still locked in escrow
    /// @param nextUnlockTime Timestamp of the next vesting tranche unlock (0 if fully vested)
    struct EscrowStatus {
        uint256 totalLocked;
        uint256 released;
        uint256 remaining;
        uint40 nextUnlockTime;
    }

    // ─── Events ───────────────────────────────────────────────────────

    /// @notice Emitted when a new escrow position is created.
    /// @param escrowId Unique identifier for the escrow
    /// @param poolId Uniswap V4 pool identifier
    /// @param issuer Address of the token issuer
    /// @param amount Total amount locked
    event EscrowCreated(uint256 indexed escrowId, PoolId indexed poolId, address indexed issuer, uint256 amount);

    /// @notice Emitted when vested funds are released to the issuer.
    /// @param escrowId Escrow identifier
    /// @param releasedAmount Amount released in this transaction
    event VestedReleased(uint256 indexed escrowId, uint256 releasedAmount);

    /// @notice Emitted when escrowed funds are redistributed due to a trigger event.
    /// @param escrowId Escrow identifier
    /// @param triggerType Type of trigger that caused the redistribution
    /// @param redistributedAmount Total amount redistributed to holders
    event Redistributed(uint256 indexed escrowId, uint8 indexed triggerType, uint256 redistributedAmount);

    /// @notice Emitted when an issuer updates their commitment to stricter values.
    /// @param escrowId Escrow identifier
    /// @param newCommitment The updated commitment parameters
    event CommitmentSet(uint256 indexed escrowId, IssuerCommitment newCommitment);

    // ─── Functions ────────────────────────────────────────────────────

    /// @notice Creates a new escrow position for an issuer's LP funds.
    /// @param poolId Uniswap V4 pool identifier
    /// @param issuer Address of the token issuer whose LP is being escrowed
    /// @param token Address of the ERC20 token to escrow
    /// @param amount Total amount of tokens to lock
    /// @param vestingSchedule Ordered array of vesting steps defining the release schedule
    /// @param commitment Issuer's up-front commitment parameters
    /// @return escrowId Unique identifier for the newly created escrow
    function createEscrow(
        PoolId poolId,
        address issuer,
        address token,
        uint256 amount,
        VestingStep[] calldata vestingSchedule,
        IssuerCommitment calldata commitment
    ) external returns (uint256 escrowId);

    /// @notice Releases all currently vested funds to the issuer.
    /// @dev Reverts if no funds are available for release.
    /// @param escrowId Identifier of the escrow position
    /// @return releasedAmount Amount of funds released in this call
    function releaseVested(uint256 escrowId) external returns (uint256 releasedAmount);

    /// @notice Redistributes remaining escrowed funds to token holders after a trigger event.
    /// @dev Can only be called by the TriggerOracle.
    /// @param escrowId Identifier of the escrow position
    /// @param triggerType The type of trigger event that occurred
    /// @return redistributedAmount Total amount redistributed
    function triggerRedistribution(uint256 escrowId, uint8 triggerType)
        external
        returns (uint256 redistributedAmount);

    /// @notice Calculates the total amount vested so far for an escrow.
    /// @param escrowId Identifier of the escrow position
    /// @return vestedAmount Cumulative amount vested (before subtracting released)
    function calculateVestedAmount(uint256 escrowId) external view returns (uint256 vestedAmount);

    /// @notice Updates the issuer's commitment to stricter values only.
    /// @param escrowId Identifier of the escrow position
    /// @param newCommitment The new commitment values (must be stricter than current)
    function setCommitment(uint256 escrowId, IssuerCommitment calldata newCommitment) external;

    /// @notice Returns the current status of an escrow position.
    /// @param escrowId Identifier of the escrow position
    /// @return status Full status snapshot including locked, released, remaining amounts and next unlock
    function getEscrowStatus(uint256 escrowId) external view returns (EscrowStatus memory status);

    /// @notice Checks whether an escrow position is fully vested (all funds released).
    /// @param poolId Uniswap V4 pool identifier
    /// @return True if the escrow's releasedAmount equals its totalAmount
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
}
