// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title IBastionRouter
/// @notice Interface for BastionRouter functions callable by other protocol contracts.
interface IBastionRouter {
    /// @notice Force-removes liquidity from a pool and sends resulting tokens to recipient.
    /// @dev Called by BastionHook during force removal. Only callable by the hook.
    /// @param key Pool key
    /// @param liquidity Amount of liquidity to remove
    /// @param recipient Address to receive the removed tokens/ETH
    function forceRemoveLiquidity(PoolKey calldata key, uint128 liquidity, address recipient) external;
}
