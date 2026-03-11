// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title IBastionHook
/// @notice Interface for BastionHook functions callable by other protocol contracts.
interface IBastionHook {
    /// @notice Per-pool immutable issuer commitment record.
    struct PoolCommitment {
        uint40 lockDuration;
        uint40 vestingDuration;
        uint16 maxSingleLpRemovalBps;
        uint16 maxCumulativeLpRemovalBps;
        uint16 maxDailySellBps;
        uint40 weeklyDumpWindowSeconds;
        uint16 weeklyDumpThresholdBps;
        uint40 createdAt;
        bool isSet;
    }

    /// @notice Returns the current governance default lock duration.
    function defaultLockDuration() external view returns (uint40);

    /// @notice Returns the current governance default vesting duration.
    function defaultVestingDuration() external view returns (uint40);

    /// @notice Force-removes issuer's remaining LP from the pool and sends assets to InsurancePool.
    /// @dev Called by EscrowVault during triggerForceRemoval.
    /// @param poolId Uniswap V4 pool identifier
    function forceRemoveIssuerLP(PoolId poolId) external;

    /// @notice Returns the issuer address for a pool.
    /// @param poolId Uniswap V4 pool identifier
    /// @return issuer The issuer address
    function getPoolIssuer(PoolId poolId) external view returns (address issuer);

    /// @notice Returns the immutable PoolCommitment for a pool.
    /// @param poolId Uniswap V4 pool identifier
    function getPoolCommitment(PoolId poolId) external view returns (PoolCommitment memory);

    /// @notice Returns true if ANY commitment dimension is stricter than governance defaults.
    /// @param poolId Uniswap V4 pool identifier
    function isCommitmentStricterThanDefault(PoolId poolId) external view returns (bool);
}
