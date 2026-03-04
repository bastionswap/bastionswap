// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title IInsurancePool
/// @notice Per-token isolated insurance pool funded by a portion of buy-side swap fees.
///         When a trigger event is detected, the pool automatically compensates affected
///         token holders on a pro-rata basis.
interface IInsurancePool {
    // ─── Structs ──────────────────────────────────────────────────────

    /// @notice Status snapshot of an insurance pool.
    /// @param balance Current total balance available in the insurance pool
    /// @param coveragePerHolder Estimated payout per holder if a trigger event occurs now
    /// @param holderCount Number of eligible token holders tracked for payout distribution
    struct PoolStatus {
        uint256 balance;
        uint256 coveragePerHolder;
        uint256 holderCount;
    }

    // ─── Events ───────────────────────────────────────────────────────

    /// @notice Emitted when a swap fee is deposited into the insurance pool.
    /// @param poolId Uniswap V4 pool identifier
    /// @param amount Amount deposited
    event FeeDeposited(PoolId indexed poolId, uint256 amount);

    /// @notice Emitted when a payout is executed after a trigger event.
    /// @param poolId Uniswap V4 pool identifier
    /// @param triggerType Type of trigger that caused the payout
    /// @param totalPaid Total amount distributed to affected holders
    event PayoutExecuted(PoolId indexed poolId, uint8 triggerType, uint256 totalPaid);

    /// @notice Emitted when an individual holder claims their compensation.
    /// @param poolId Uniswap V4 pool identifier
    /// @param holder Address of the claiming holder
    /// @param amount Amount claimed
    event CompensationClaimed(PoolId indexed poolId, address indexed holder, uint256 amount);

    // ─── Functions ────────────────────────────────────────────────────

    /// @notice Deposits a portion of swap fees into the insurance pool for a given token pair.
    /// @dev Called by BastionHook during afterSwap on buy-side transactions.
    ///      Typically 1-2% of the buy transaction value.
    /// @param poolId Uniswap V4 pool identifier
    /// @param amount Amount of fee tokens to deposit
    function depositFee(PoolId poolId, uint256 amount) external;

    /// @notice Executes a payout from the insurance pool after a trigger event is confirmed.
    /// @dev Can only be called by an authorized trigger source.
    ///      Marks the pool as triggered and allocates funds for holder claims.
    /// @param poolId Uniswap V4 pool identifier
    /// @param triggerType The type of trigger event that occurred
    /// @return totalPaid Total amount earmarked for distribution to holders
    function executePayout(PoolId poolId, uint8 triggerType) external returns (uint256 totalPaid);

    /// @notice Returns the current status of an insurance pool.
    /// @param poolId Uniswap V4 pool identifier
    /// @return status Pool status including balance, per-holder coverage, and holder count
    function getPoolStatus(PoolId poolId) external view returns (PoolStatus memory status);

    /// @notice Allows an individual holder to claim their compensation after a payout is executed.
    /// @dev Reverts if the pool has not been triggered or the holder has already claimed.
    /// @param poolId Uniswap V4 pool identifier
    /// @param holder Address of the token holder claiming compensation
    /// @return amount Amount of compensation transferred to the holder
    function claimCompensation(PoolId poolId, address holder) external returns (uint256 amount);
}
