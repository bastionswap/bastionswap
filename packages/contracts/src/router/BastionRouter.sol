// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

/// @title BastionRouter
/// @notice Minimal router for Uniswap V4 pools with BastionHook.
///         Handles swaps, full pool creation (initialize + LP + hook registration),
///         and LP removal with user identification in hookData.
contract BastionRouter is IUnlockCallback {
    using CurrencyLibrary for Currency;
    using TransientStateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager public immutable poolManager;

    uint8 private constant ACTION_SWAP = 0;
    uint8 private constant ACTION_CREATE_POOL = 1;
    uint8 private constant ACTION_REMOVE_LP = 2;
    uint8 private constant ACTION_ADD_LP = 3;

    struct CreatePoolParams {
        PoolKey key;
        uint160 sqrtPriceX96;
        uint256 amount0Max;  // max currency0 for LP
        uint256 amount1Max;  // max currency1 for LP
        bytes hookData;      // abi.encode(issuer, token, vesting, commitment, triggerConfig)
    }

    error Expired();
    error OnlyPoolManager();
    error InsufficientOutput(uint256 amountOut, uint256 minAmountOut);
    error ExcessiveInput(uint256 amountIn, uint256 maxAmountIn);

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    // ═══════════════════════════════════════════════════════════════
    //  PUBLIC FUNCTIONS
    // ═══════════════════════════════════════════════════════════════

    /// @notice Create a pool with initial liquidity and BastionHook registration in one tx.
    /// @param params Pool creation parameters including key, price, amounts, and hookData.
    function createPool(CreatePoolParams calldata params) external payable {
        poolManager.unlock(abi.encode(ACTION_CREATE_POOL, msg.sender, params));
        _refundETH();
    }

    /// @notice Add liquidity to an existing pool. Encodes msg.sender in hookData for issuer identification.
    /// @param key Pool key
    /// @param amount0Max Max amount of currency0
    /// @param amount1Max Max amount of currency1
    function addLiquidity(PoolKey calldata key, uint256 amount0Max, uint256 amount1Max) external payable {
        poolManager.unlock(abi.encode(ACTION_ADD_LP, msg.sender, key, amount0Max, amount1Max));
        _refundETH();
    }

    /// @notice Remove liquidity from a pool. Encodes msg.sender in hookData for issuer identification.
    /// @param key Pool key
    /// @param liquidityToRemove Amount of liquidity to remove
    function removeLiquidity(PoolKey calldata key, uint128 liquidityToRemove) external {
        poolManager.unlock(abi.encode(ACTION_REMOVE_LP, msg.sender, key, liquidityToRemove));
        _refundETH();
    }

    /// @notice Swap exact input amount for as many output tokens as possible.
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
            poolManager.unlock(abi.encode(ACTION_SWAP, msg.sender, key, params)),
            (BalanceDelta)
        );

        amountOut = zeroForOne
            ? uint256(int256(delta.amount1()))
            : uint256(int256(delta.amount0()));

        if (amountOut < minAmountOut) revert InsufficientOutput(amountOut, minAmountOut);

        _refundETH();
    }

    /// @notice Swap for exact output amount, spending at most maxAmountIn.
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
            poolManager.unlock(abi.encode(ACTION_SWAP, msg.sender, key, params)),
            (BalanceDelta)
        );

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

        uint8 action = abi.decode(data, (uint8));

        if (action == ACTION_SWAP) {
            return _handleSwap(data);
        } else if (action == ACTION_CREATE_POOL) {
            return _handleCreatePool(data);
        } else if (action == ACTION_REMOVE_LP) {
            return _handleRemoveLP(data);
        } else if (action == ACTION_ADD_LP) {
            return _handleAddLP(data);
        }

        revert("Unknown action");
    }

    // ═══════════════════════════════════════════════════════════════
    //  INTERNAL HANDLERS
    // ═══════════════════════════════════════════════════════════════

    function _handleSwap(bytes calldata data) internal returns (bytes memory) {
        (, address sender, PoolKey memory key, SwapParams memory params) =
            abi.decode(data, (uint8, address, PoolKey, SwapParams));

        BalanceDelta delta = poolManager.swap(key, params, "");

        _settle(key.currency0, sender, delta.amount0());
        _settle(key.currency1, sender, delta.amount1());

        return abi.encode(delta);
    }

    function _handleCreatePool(bytes calldata data) internal returns (bytes memory) {
        (, address sender, CreatePoolParams memory params) =
            abi.decode(data, (uint8, address, CreatePoolParams));

        // 1. Initialize the pool
        poolManager.initialize(params.key, params.sqrtPriceX96);

        // 2. Compute full-range ticks aligned to tickSpacing
        int24 tickSpacing = params.key.tickSpacing;
        int24 tickLower = (TickMath.MIN_TICK / tickSpacing) * tickSpacing;
        int24 tickUpper = (TickMath.MAX_TICK / tickSpacing) * tickSpacing;

        // 3. Compute liquidity from amounts
        uint160 sqrtPriceAX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceBX96 = TickMath.getSqrtPriceAtTick(tickUpper);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            params.sqrtPriceX96,
            sqrtPriceAX96,
            sqrtPriceBX96,
            params.amount0Max,
            params.amount1Max
        );

        // 4. Add liquidity with hookData to trigger BastionHook registration
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            params.key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: 0
            }),
            params.hookData
        );

        // 5. Settle token deltas
        _settle(params.key.currency0, sender, delta.amount0());
        _settle(params.key.currency1, sender, delta.amount1());

        return abi.encode(delta);
    }

    function _handleAddLP(bytes calldata data) internal returns (bytes memory) {
        (, address sender, PoolKey memory key, uint256 amount0Max, uint256 amount1Max) =
            abi.decode(data, (uint8, address, PoolKey, uint256, uint256));

        // Compute full-range ticks
        int24 tickSpacing = key.tickSpacing;
        int24 tickLower = (TickMath.MIN_TICK / tickSpacing) * tickSpacing;
        int24 tickUpper = (TickMath.MAX_TICK / tickSpacing) * tickSpacing;

        // Get current price from pool
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());

        uint160 sqrtPriceAX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceBX96 = TickMath.getSqrtPriceAtTick(tickUpper);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, sqrtPriceAX96, sqrtPriceBX96, amount0Max, amount1Max
        );

        // hookData identifies the actual user to the hook
        bytes memory hookData = abi.encode(sender);

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: 0
            }),
            hookData
        );

        _settle(key.currency0, sender, delta.amount0());
        _settle(key.currency1, sender, delta.amount1());

        return abi.encode(delta);
    }

    function _handleRemoveLP(bytes calldata data) internal returns (bytes memory) {
        (, address sender, PoolKey memory key, uint128 liquidityToRemove) =
            abi.decode(data, (uint8, address, PoolKey, uint128));

        // Compute full-range ticks (same as createPool)
        int24 tickSpacing = key.tickSpacing;
        int24 tickLower = (TickMath.MIN_TICK / tickSpacing) * tickSpacing;
        int24 tickUpper = (TickMath.MAX_TICK / tickSpacing) * tickSpacing;

        // hookData identifies the actual user to the hook
        bytes memory hookData = abi.encode(sender);

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: -int256(uint256(liquidityToRemove)),
                salt: 0
            }),
            hookData
        );

        // Settle deltas back to sender
        _settle(key.currency0, sender, delta.amount0());
        _settle(key.currency1, sender, delta.amount1());

        return abi.encode(delta);
    }

    // ═══════════════════════════════════════════════════════════════
    //  INTERNAL SETTLEMENT
    // ═══════════════════════════════════════════════════════════════

    function _settle(Currency currency, address sender, int128 amount) internal {
        if (amount < 0) {
            uint256 amountToSend = uint256(uint128(-amount));
            if (currency.isAddressZero()) {
                poolManager.settle{value: amountToSend}();
            } else {
                poolManager.sync(currency);
                IERC20Minimal(Currency.unwrap(currency)).transferFrom(
                    sender, address(poolManager), amountToSend
                );
                poolManager.settle();
            }
        } else if (amount > 0) {
            uint256 amountToReceive = uint256(uint128(amount));
            poolManager.take(currency, sender, amountToReceive);
        }
    }

    /// @dev Refund any excess ETH left in the contract.
    function _refundETH() internal {
        uint256 bal = address(this).balance;
        if (bal > 0) {
            (bool ok,) = msg.sender.call{value: bal}("");
            require(ok, "ETH refund failed");
        }
    }

    receive() external payable {}
}
