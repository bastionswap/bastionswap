// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @title BastionRouter
/// @notice Minimal swap router for Uniswap V4 pools with BastionHook.
///         Handles the unlock → callback pattern so users can swap in a single tx.
contract BastionRouter is IUnlockCallback {
    using CurrencyLibrary for Currency;
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable poolManager;

    error Expired();
    error OnlyPoolManager();
    error InsufficientOutput(uint256 amountOut, uint256 minAmountOut);
    error ExcessiveInput(uint256 amountIn, uint256 maxAmountIn);

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    // ═══════════════════════════════════════════════════════════════
    //  PUBLIC SWAP FUNCTIONS
    // ═══════════════════════════════════════════════════════════════

    /// @notice Swap exact input amount for as many output tokens as possible.
    /// @param key       Pool key identifying the pool.
    /// @param zeroForOne Direction: true = sell currency0 for currency1.
    /// @param amountIn   Exact input amount (must be > 0).
    /// @param minAmountOut Minimum output amount (slippage protection).
    /// @param deadline   Timestamp after which the tx reverts.
    /// @return amountOut Actual output amount received.
    function swapExactInput(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline
    ) external payable returns (uint256 amountOut) {
        if (block.timestamp > deadline) revert Expired();

        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1
        });

        BalanceDelta delta = abi.decode(
            poolManager.unlock(abi.encode(msg.sender, key, params)),
            (BalanceDelta)
        );

        // Output is the positive delta
        amountOut = zeroForOne
            ? uint256(int256(delta.amount1()))
            : uint256(int256(delta.amount0()));

        if (amountOut < minAmountOut) revert InsufficientOutput(amountOut, minAmountOut);

        _refundETH();
    }

    /// @notice Swap for exact output amount, spending at most maxAmountIn.
    /// @param key       Pool key identifying the pool.
    /// @param zeroForOne Direction: true = sell currency0 for currency1.
    /// @param amountOut  Exact output amount desired (must be > 0).
    /// @param maxAmountIn Maximum input amount (slippage protection).
    /// @param deadline   Timestamp after which the tx reverts.
    /// @return amountIn Actual input amount spent.
    function swapExactOutput(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amountOut,
        uint256 maxAmountIn,
        uint256 deadline
    ) external payable returns (uint256 amountIn) {
        if (block.timestamp > deadline) revert Expired();

        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: int256(amountOut),
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1
        });

        BalanceDelta delta = abi.decode(
            poolManager.unlock(abi.encode(msg.sender, key, params)),
            (BalanceDelta)
        );

        // Input is the negative delta
        amountIn = zeroForOne
            ? uint256(-int256(delta.amount0()))
            : uint256(-int256(delta.amount1()));

        if (amountIn > maxAmountIn) revert ExcessiveInput(amountIn, maxAmountIn);

        _refundETH();
    }

    // ═══════════════════════════════════════════════════════════════
    //  UNLOCK CALLBACK
    // ═══════════════════════════════════════════════════════════════

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();

        (address sender, PoolKey memory key, SwapParams memory params) =
            abi.decode(data, (address, PoolKey, SwapParams));

        BalanceDelta delta = poolManager.swap(key, params, "");

        _settle(key.currency0, sender, delta.amount0());
        _settle(key.currency1, sender, delta.amount1());

        return abi.encode(delta);
    }

    // ═══════════════════════════════════════════════════════════════
    //  INTERNAL SETTLEMENT
    // ═══════════════════════════════════════════════════════════════

    function _settle(Currency currency, address sender, int128 amount) internal {
        if (amount < 0) {
            // User owes tokens to the pool
            uint256 amountToSend = uint256(uint128(-amount));
            if (currency.isAddressZero()) {
                // Native ETH — pay from contract balance (forwarded via msg.value)
                poolManager.settle{value: amountToSend}();
            } else {
                // ERC20 — pull from sender (requires prior approval to this router)
                poolManager.sync(currency);
                IERC20Minimal(Currency.unwrap(currency)).transferFrom(
                    sender, address(poolManager), amountToSend
                );
                poolManager.settle();
            }
        } else if (amount > 0) {
            // Pool owes tokens to the user
            uint256 amountToReceive = uint256(uint128(amount));
            poolManager.take(currency, sender, amountToReceive);
        }
    }

    /// @dev Refund any excess ETH left in the contract after a swap.
    function _refundETH() internal {
        uint256 bal = address(this).balance;
        if (bal > 0) {
            (bool ok,) = msg.sender.call{value: bal}("");
            require(ok, "ETH refund failed");
        }
    }

    receive() external payable {}
}
