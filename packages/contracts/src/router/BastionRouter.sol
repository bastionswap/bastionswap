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
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";

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
    ISignatureTransfer public immutable permit2;

    uint8 private constant ACTION_SWAP = 0;
    uint8 private constant ACTION_CREATE_POOL = 1;
    uint8 private constant ACTION_REMOVE_LP = 2;
    uint8 private constant ACTION_ADD_LP = 3;
    uint8 private constant ACTION_FORCE_REMOVE = 4;
    uint8 private constant ACTION_SWAP_PERMIT2 = 5;
    uint8 private constant ACTION_CREATE_POOL_PERMIT2 = 6;

    /// @dev BastionHook address for access control on forceRemoveLiquidity
    address public bastionHook;

    struct CreatePoolParams {
        PoolKey key;
        uint160 sqrtPriceX96;
        uint256 amount0Max;  // max currency0 for LP
        uint256 amount1Max;  // max currency1 for LP
        bytes hookData;      // abi.encode(issuer, token, vesting, commitment, triggerConfig)
    }

    /// @dev Permit2 data for a single token transfer
    struct Permit2Single {
        ISignatureTransfer.PermitTransferFrom permit;
        bytes signature;
    }

    /// @dev Permit2 data for batch (two-token) transfer
    struct Permit2Batch {
        ISignatureTransfer.PermitBatchTransferFrom permit;
        bytes signature;
    }

    error Expired();
    error OnlyPoolManager();
    error OnlyHook();
    error HookAlreadySet();
    error HookNotSet();
    error InsufficientOutput(uint256 amountOut, uint256 minAmountOut);
    error ExcessiveInput(uint256 amountIn, uint256 maxAmountIn);

    constructor(IPoolManager _poolManager, ISignatureTransfer _permit2) {
        poolManager = _poolManager;
        permit2 = _permit2;
    }

    // ═══════════════════════════════════════════════════════════════
    //  HOOK SETUP
    // ═══════════════════════════════════════════════════════════════

    /// @notice Set the BastionHook address for access control. One-time setter.
    function setBastionHook(address hook) external {
        if (bastionHook != address(0)) revert HookAlreadySet();
        bastionHook = hook;
    }

    /// @notice Force-removes liquidity from a pool and sends resulting tokens to recipient.
    /// @dev Called by BastionHook during force removal. Only callable by the hook.
    function forceRemoveLiquidity(PoolKey calldata key, uint128 liquidity, address recipient) external {
        if (msg.sender != bastionHook) revert OnlyHook();
        poolManager.unlock(abi.encode(ACTION_FORCE_REMOVE, recipient, key, liquidity));
    }

    // ═══════════════════════════════════════════════════════════════
    //  PUBLIC FUNCTIONS (original — backward compatible)
    // ═══════════════════════════════════════════════════════════════

    /// @notice Create a pool with initial liquidity and BastionHook registration in one tx.
    function createPool(
        address token,
        address baseToken,
        uint24 fee,
        uint256 tokenAmount,
        uint160 sqrtPriceX96,
        bytes calldata hookData
    ) external payable returns (PoolId poolId) {
        if (bastionHook == address(0)) revert HookNotSet();

        uint256 baseAmount = baseToken == address(0)
            ? msg.value
            : IERC20Minimal(baseToken).balanceOf(msg.sender);

        Currency currency0;
        Currency currency1;
        uint256 amount0Max;
        uint256 amount1Max;

        if (uint160(baseToken) < uint160(token)) {
            currency0 = Currency.wrap(baseToken);
            currency1 = Currency.wrap(token);
            amount0Max = baseAmount;
            amount1Max = tokenAmount;
        } else {
            currency0 = Currency.wrap(token);
            currency1 = Currency.wrap(baseToken);
            amount0Max = tokenAmount;
            amount1Max = baseAmount;
        }

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: fee,
            tickSpacing: 60,
            hooks: IHooks(bastionHook)
        });

        poolId = key.toId();

        poolManager.unlock(abi.encode(
            ACTION_CREATE_POOL, msg.sender,
            CreatePoolParams({
                key: key,
                sqrtPriceX96: sqrtPriceX96,
                amount0Max: amount0Max,
                amount1Max: amount1Max,
                hookData: hookData
            })
        ));

        _refundETH();
    }

    /// @notice Add liquidity to an existing pool.
    function addLiquidity(PoolKey calldata key, uint256 amount0Max, uint256 amount1Max) external payable {
        poolManager.unlock(abi.encode(ACTION_ADD_LP, msg.sender, key, amount0Max, amount1Max));
        _refundETH();
    }

    /// @notice Remove liquidity from a pool.
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
    //  PERMIT2-ENABLED FUNCTIONS
    // ═══════════════════════════════════════════════════════════════

    /// @notice Create a pool using Permit2 for token transfers.
    /// @param permitData For ETH+ERC20: Permit2Single for the ERC20 side.
    ///                   For ERC20+ERC20: Permit2Batch for both tokens.
    function createPoolPermit2(
        address token,
        address baseToken,
        uint24 fee,
        uint256 tokenAmount,
        uint160 sqrtPriceX96,
        bytes calldata hookData,
        bytes calldata permitData
    ) external payable returns (PoolId poolId) {
        if (bastionHook == address(0)) revert HookNotSet();

        (PoolKey memory key, uint256 amount0Max, uint256 amount1Max) =
            _buildPoolKey(token, baseToken, fee, tokenAmount);

        poolId = key.toId();

        poolManager.unlock(abi.encode(
            ACTION_CREATE_POOL_PERMIT2, msg.sender,
            CreatePoolParams({
                key: key,
                sqrtPriceX96: sqrtPriceX96,
                amount0Max: amount0Max,
                amount1Max: amount1Max,
                hookData: hookData
            }),
            permitData
        ));

        _refundETH();
    }

    /// @dev Build PoolKey and sorted amounts for createPool variants.
    function _buildPoolKey(
        address token,
        address baseToken,
        uint24 fee,
        uint256 tokenAmount
    ) internal view returns (PoolKey memory key, uint256 amount0Max, uint256 amount1Max) {
        bool isNativeBase = baseToken == address(0);
        uint256 baseAmount = isNativeBase ? msg.value : 0;

        if (uint160(baseToken) < uint160(token)) {
            key = PoolKey(Currency.wrap(baseToken), Currency.wrap(token), fee, 60, IHooks(bastionHook));
            amount0Max = isNativeBase ? baseAmount : 0;
            amount1Max = tokenAmount;
        } else {
            key = PoolKey(Currency.wrap(token), Currency.wrap(baseToken), fee, 60, IHooks(bastionHook));
            amount0Max = tokenAmount;
            amount1Max = isNativeBase ? baseAmount : 0;
        }
    }

    /// @notice Swap exact input using Permit2 for the input token.
    function swapExactInputPermit2(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline,
        Permit2Single calldata permitSingle
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
            poolManager.unlock(abi.encode(
                ACTION_SWAP_PERMIT2, msg.sender, key, params,
                permitSingle.permit, permitSingle.signature
            )),
            (BalanceDelta)
        );

        amountOut = zeroForOne
            ? uint256(int256(delta.amount1()))
            : uint256(int256(delta.amount0()));

        if (amountOut < minAmountOut) revert InsufficientOutput(amountOut, minAmountOut);

        _refundETH();
    }

    /// @notice Swap for exact output using Permit2 for the input token.
    function swapExactOutputPermit2(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amountOut,
        uint256 maxAmountIn,
        uint256 deadline,
        Permit2Single calldata permitSingle
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
            poolManager.unlock(abi.encode(
                ACTION_SWAP_PERMIT2, msg.sender, key, params,
                permitSingle.permit, permitSingle.signature
            )),
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
        } else if (action == ACTION_FORCE_REMOVE) {
            return _handleForceRemoveLP(data);
        } else if (action == ACTION_SWAP_PERMIT2) {
            return _handleSwapPermit2(data);
        } else if (action == ACTION_CREATE_POOL_PERMIT2) {
            return _handleCreatePoolPermit2(data);
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

    function _handleSwapPermit2(bytes calldata data) internal returns (bytes memory) {
        (
            , address sender, PoolKey memory key, SwapParams memory params,
            ISignatureTransfer.PermitTransferFrom memory permitTransfer, bytes memory sig
        ) = abi.decode(data, (
            uint8, address, PoolKey, SwapParams,
            ISignatureTransfer.PermitTransferFrom, bytes
        ));

        BalanceDelta delta = poolManager.swap(key, params, "");

        // Determine which currency is the input (negative delta = tokens owed to pool)
        int128 amount0 = delta.amount0();
        int128 amount1 = delta.amount1();

        if (amount0 < 0) {
            _settleWithPermit2(key.currency0, sender, uint256(uint128(-amount0)), permitTransfer, sig);
        } else if (amount0 > 0) {
            poolManager.take(key.currency0, sender, uint256(uint128(amount0)));
        }

        if (amount1 < 0) {
            _settleWithPermit2(key.currency1, sender, uint256(uint128(-amount1)), permitTransfer, sig);
        } else if (amount1 > 0) {
            poolManager.take(key.currency1, sender, uint256(uint128(amount1)));
        }

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

    function _handleCreatePoolPermit2(bytes calldata data) internal returns (bytes memory) {
        (, address sender, CreatePoolParams memory params, bytes memory permitData) =
            abi.decode(data, (uint8, address, CreatePoolParams, bytes));

        BalanceDelta delta = _initAndAddLiquidity(params);

        // Settle with Permit2
        if (params.key.currency0.isAddressZero()) {
            _settleCreatePoolNativePermit2(params.key, sender, delta, permitData);
        } else {
            _settleCreatePoolBatchPermit2(params.key, sender, delta, permitData);
        }

        return abi.encode(delta);
    }

    /// @dev Initialize pool and add full-range liquidity. Shared by both createPool handlers.
    function _initAndAddLiquidity(CreatePoolParams memory params) internal returns (BalanceDelta delta) {
        poolManager.initialize(params.key, params.sqrtPriceX96);

        int24 tickSpacing = params.key.tickSpacing;
        int24 tickLower = (TickMath.MIN_TICK / tickSpacing) * tickSpacing;
        int24 tickUpper = (TickMath.MAX_TICK / tickSpacing) * tickSpacing;

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            params.sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            params.amount0Max,
            params.amount1Max
        );

        (delta,) = poolManager.modifyLiquidity(
            params.key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: 0
            }),
            params.hookData
        );
    }

    /// @dev Settle createPool with ETH + ERC20: ETH settles normally, ERC20 via single Permit2.
    function _settleCreatePoolNativePermit2(
        PoolKey memory key, address sender, BalanceDelta delta, bytes memory permitData
    ) internal {
        Permit2Single memory p2 = abi.decode(permitData, (Permit2Single));

        int128 amount0 = delta.amount0();
        if (amount0 < 0) {
            poolManager.settle{value: uint256(uint128(-amount0))}();
        } else if (amount0 > 0) {
            poolManager.take(key.currency0, sender, uint256(uint128(amount0)));
        }

        int128 amount1 = delta.amount1();
        if (amount1 < 0) {
            _settleWithPermit2(key.currency1, sender, uint256(uint128(-amount1)), p2.permit, p2.signature);
        } else if (amount1 > 0) {
            poolManager.take(key.currency1, sender, uint256(uint128(amount1)));
        }
    }

    /// @dev Settle createPool with ERC20 + ERC20: use batch Permit2 for both tokens.
    function _settleCreatePoolBatchPermit2(
        PoolKey memory key, address sender, BalanceDelta delta, bytes memory permitData
    ) internal {
        Permit2Batch memory p2 = abi.decode(permitData, (Permit2Batch));

        uint256 needed0 = delta.amount0() < 0 ? uint256(uint128(-delta.amount0())) : 0;
        uint256 needed1 = delta.amount1() < 0 ? uint256(uint128(-delta.amount1())) : 0;

        if (needed0 > 0 || needed1 > 0) {
            poolManager.sync(key.currency0);
            poolManager.sync(key.currency1);

            ISignatureTransfer.SignatureTransferDetails[] memory td =
                new ISignatureTransfer.SignatureTransferDetails[](2);
            td[0] = ISignatureTransfer.SignatureTransferDetails({to: address(poolManager), requestedAmount: needed0});
            td[1] = ISignatureTransfer.SignatureTransferDetails({to: address(poolManager), requestedAmount: needed1});

            permit2.permitTransferFrom(p2.permit, td, sender, p2.signature);

            if (needed0 > 0) poolManager.settle();
            if (needed1 > 0) poolManager.settle();
        }

        if (delta.amount0() > 0) poolManager.take(key.currency0, sender, uint256(uint128(delta.amount0())));
        if (delta.amount1() > 0) poolManager.take(key.currency1, sender, uint256(uint128(delta.amount1())));
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

    function _handleForceRemoveLP(bytes calldata data) internal returns (bytes memory) {
        (, address recipient, PoolKey memory key, uint128 liquidity) =
            abi.decode(data, (uint8, address, PoolKey, uint128));

        // Compute full-range ticks
        int24 tickSpacing = key.tickSpacing;
        int24 tickLower = (TickMath.MIN_TICK / tickSpacing) * tickSpacing;
        int24 tickUpper = (TickMath.MAX_TICK / tickSpacing) * tickSpacing;

        // Force remove with empty hookData (transient flag handles auth in hook)
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: -int256(uint256(liquidity)),
                salt: 0
            }),
            ""
        );

        // Send tokens/ETH to recipient (the hook) — both deltas should be positive (receiving)
        _settleToRecipient(key.currency0, recipient, delta.amount0());
        _settleToRecipient(key.currency1, recipient, delta.amount1());

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

    /// @dev Settle a negative delta using Permit2 SignatureTransfer (single token).
    function _settleWithPermit2(
        Currency currency,
        address owner,
        uint256 amount,
        ISignatureTransfer.PermitTransferFrom memory permitTransfer,
        bytes memory sig
    ) internal {
        if (currency.isAddressZero()) {
            // Native ETH — use msg.value already forwarded
            poolManager.settle{value: amount}();
        } else {
            poolManager.sync(currency);
            permit2.permitTransferFrom(
                permitTransfer,
                ISignatureTransfer.SignatureTransferDetails({
                    to: address(poolManager),
                    requestedAmount: amount
                }),
                owner,
                sig
            );
            poolManager.settle();
        }
    }

    /// @dev Settlement for force removal: positive deltas go to recipient, negatives settle from pool
    function _settleToRecipient(Currency currency, address recipient, int128 amount) internal {
        if (amount > 0) {
            uint256 amountToReceive = uint256(uint128(amount));
            poolManager.take(currency, recipient, amountToReceive);
        }
        // Negative deltas shouldn't happen for removals, but handle defensively
        if (amount < 0) {
            uint256 amountToSend = uint256(uint128(-amount));
            if (currency.isAddressZero()) {
                poolManager.settle{value: amountToSend}();
            } else {
                poolManager.sync(currency);
                IERC20Minimal(Currency.unwrap(currency)).transferFrom(
                    address(this), address(poolManager), amountToSend
                );
                poolManager.settle();
            }
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
