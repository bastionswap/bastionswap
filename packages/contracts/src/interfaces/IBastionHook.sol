// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title IBastionHook
/// @notice Interface for BastionHook functions callable by other protocol contracts.
interface IBastionHook {
    /// @notice Force-removes issuer's remaining LP from the pool and sends assets to InsurancePool.
    /// @dev Called by EscrowVault during triggerForceRemoval.
    /// @param poolId Uniswap V4 pool identifier
    function forceRemoveIssuerLP(PoolId poolId) external;
}
