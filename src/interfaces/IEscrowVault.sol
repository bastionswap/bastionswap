// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

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
    /// @param basisPoints Percentage (basis points, max 10_000) of total escrowed amount released
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
    event Redistributed(uint256 indexed escrowId, uint8 triggerType, uint256 redistributedAmount);

    // ─── Functions ────────────────────────────────────────────────────

    /// @notice Creates a new escrow position for an issuer's LP funds.
    /// @param poolId Uniswap V4 pool identifier
    /// @param issuer Address of the token issuer whose LP is being escrowed
    /// @param amount Total amount of LP tokens to lock
    /// @param vestingSchedule Ordered array of vesting steps defining the release schedule
    /// @return escrowId Unique identifier for the newly created escrow
    function createEscrow(
        PoolId poolId,
        address issuer,
        uint256 amount,
        VestingStep[] calldata vestingSchedule
    ) external returns (uint256 escrowId);

    /// @notice Releases all currently vested funds to the issuer.
    /// @dev Reverts if no funds are available for release.
    /// @param escrowId Identifier of the escrow position
    /// @return releasedAmount Amount of funds released in this call
    function releaseVested(uint256 escrowId) external returns (uint256 releasedAmount);

    /// @notice Redistributes remaining escrowed funds to token holders after a trigger event.
    /// @dev Can only be called by an authorized trigger source (e.g. BastionHook or TriggerOracle).
    /// @param escrowId Identifier of the escrow position
    /// @param triggerType The type of trigger event that occurred
    /// @return redistributedAmount Total amount redistributed
    function triggerRedistribution(uint256 escrowId, uint8 triggerType)
        external
        returns (uint256 redistributedAmount);

    /// @notice Returns the current status of an escrow position.
    /// @param escrowId Identifier of the escrow position
    /// @return status Full status snapshot including locked, released, remaining amounts and next unlock
    function getEscrowStatus(uint256 escrowId) external view returns (EscrowStatus memory status);
}
