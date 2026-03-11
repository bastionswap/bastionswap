// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";

/// @title BastionSwapRouter
/// @notice Swap-only router for Uniswap V4 pools with BastionHook.
contract BastionSwapRouter is IUnlockCallback {
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    IPoolManager public immutable poolManager;
    ISignatureTransfer public immutable permit2;

    uint8 private constant ACTION_SWAP_EXACT_INPUT = 0;
    uint8 private constant ACTION_SWAP_EXACT_OUTPUT = 1;
    uint8 private constant ACTION_SWAP_MULTI_HOP = 2;
    uint8 private constant ACTION_SWAP_EXACT_INPUT_PERMIT2 = 3;
    uint8 private constant ACTION_SWAP_EXACT_OUTPUT_PERMIT2 = 4;
    uint8 private constant ACTION_SWAP_MULTI_HOP_PERMIT2 = 5;

    uint8 private constant MAX_HOPS = 4;

    /// @dev BastionHook address (informational, not used for access control in swaps)
    address public bastionHook;

    struct SwapStep {
        PoolKey poolKey;
        bool zeroForOne;
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
    error HookAlreadySet();
    error InsufficientOutput(uint256 amountOut, uint256 minAmountOut);
    error ExcessiveInput(uint256 amountIn, uint256 maxAmountIn);
    error TooManyHops();
    error ZeroHops();

    event SwapExecuted(
        PoolId indexed poolId, address indexed sender,
        int128 amount0, int128 amount1,
        uint160 sqrtPriceX96, int24 tick
    );

    constructor(IPoolManager _poolManager, ISignatureTransfer _permit2) {
        poolManager = _poolManager;
        permit2 = _permit2;
    }

    // ═══════════════════════════════════════════════════════════════
    //  HOOK SETUP
    // ═══════════════════════════════════════════════════════════════

    /// @notice Set the BastionHook address. One-time setter.
    function setBastionHook(address hook) external {
        if (bastionHook != address(0)) revert HookAlreadySet();
        bastionHook = hook;
    }

    // ═══════════════════════════════════════════════════════════════
    //  SWAP FUNCTIONS
    // ═══════════════════════════════════════════════════════════════

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
            poolManager.unlock(abi.encode(ACTION_SWAP_EXACT_INPUT, msg.sender, key, params)),
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
            poolManager.unlock(abi.encode(ACTION_SWAP_EXACT_INPUT, msg.sender, key, params)),
            (BalanceDelta)
        );

        amountIn = zeroForOne
            ? uint256(-int256(delta.amount0()))
            : uint256(-int256(delta.amount1()));

        if (amountIn > maxAmountIn) revert ExcessiveInput(amountIn, maxAmountIn);

        _refundETH();
    }

    // ═══════════════════════════════════════════════════════════════
    //  MULTI-HOP SWAP FUNCTIONS
    // ═══════════════════════════════════════════════════════════════

    /// @notice Execute a multi-hop swap through a series of pools.
    function swapMultiHop(
        SwapStep[] calldata steps,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline
    ) external payable returns (uint256 amountOut) {
        if (block.timestamp > deadline) revert Expired();
        if (steps.length == 0) revert ZeroHops();
        if (steps.length > MAX_HOPS) revert TooManyHops();

        amountOut = abi.decode(
            poolManager.unlock(abi.encode(ACTION_SWAP_MULTI_HOP, msg.sender, steps, amountIn)),
            (uint256)
        );

        if (amountOut < minAmountOut) revert InsufficientOutput(amountOut, minAmountOut);

        _refundETH();
    }

    /// @notice Execute a multi-hop swap using Permit2 for the input token.
    function swapMultiHopPermit2(
        SwapStep[] calldata steps,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline,
        Permit2Single calldata permitSingle
    ) external payable returns (uint256 amountOut) {
        if (block.timestamp > deadline) revert Expired();
        if (steps.length == 0) revert ZeroHops();
        if (steps.length > MAX_HOPS) revert TooManyHops();

        amountOut = abi.decode(
            poolManager.unlock(abi.encode(
                ACTION_SWAP_MULTI_HOP_PERMIT2, msg.sender, steps, amountIn,
                permitSingle.permit, permitSingle.signature
            )),
            (uint256)
        );

        if (amountOut < minAmountOut) revert InsufficientOutput(amountOut, minAmountOut);

        _refundETH();
    }

    // ═══════════════════════════════════════════════════════════════
    //  PERMIT2-ENABLED SWAP FUNCTIONS
    // ═══════════════════════════════════════════════════════════════

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
                ACTION_SWAP_EXACT_INPUT_PERMIT2, msg.sender, key, params,
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
                ACTION_SWAP_EXACT_INPUT_PERMIT2, msg.sender, key, params,
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

        if (action == ACTION_SWAP_EXACT_INPUT) {
            return _handleSwap(data);
        } else if (action == ACTION_SWAP_EXACT_INPUT_PERMIT2) {
            return _handleSwapPermit2(data);
        } else if (action == ACTION_SWAP_MULTI_HOP) {
            return _handleMultiHopSwap(data);
        } else if (action == ACTION_SWAP_MULTI_HOP_PERMIT2) {
            return _handleMultiHopSwapPermit2(data);
        }

        revert("Unknown action");
    }

    // ═══════════════════════════════════════════════════════════════
    //  INTERNAL HANDLERS
    // ═══════════════════════════════════════════════════════════════

    function _handleSwap(bytes calldata data) internal returns (bytes memory) {
        (, address sender, PoolKey memory key, SwapParams memory params) =
            abi.decode(data, (uint8, address, PoolKey, SwapParams));

        BalanceDelta delta = poolManager.swap(key, params, abi.encode(sender));

        _settle(key.currency0, sender, delta.amount0());
        _settle(key.currency1, sender, delta.amount1());

        _emitSwap(key, sender, delta);

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

        BalanceDelta delta = poolManager.swap(key, params, abi.encode(sender));

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

        _emitSwap(key, sender, delta);

        return abi.encode(delta);
    }

    // ═══════════════════════════════════════════════════════════════
    //  MULTI-HOP HANDLERS
    // ═══════════════════════════════════════════════════════════════

    function _handleMultiHopSwap(bytes calldata data) internal returns (bytes memory) {
        (, address sender, SwapStep[] memory steps, uint256 amountIn) =
            abi.decode(data, (uint8, address, SwapStep[], uint256));

        uint256 currentAmount = amountIn;

        for (uint256 i = 0; i < steps.length; i++) {
            SwapParams memory params = SwapParams({
                zeroForOne: steps[i].zeroForOne,
                amountSpecified: -int256(currentAmount),
                sqrtPriceLimitX96: steps[i].zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            });

            BalanceDelta delta = poolManager.swap(steps[i].poolKey, params, abi.encode(sender));
            _emitSwap(steps[i].poolKey, sender, delta);

            currentAmount = steps[i].zeroForOne
                ? uint256(int256(delta.amount1()))
                : uint256(int256(delta.amount0()));
        }

        uint256 amountOut = _settleAllDeltas(steps, sender);

        return abi.encode(amountOut);
    }

    function _handleMultiHopSwapPermit2(bytes calldata data) internal returns (bytes memory) {
        (
            , address sender, SwapStep[] memory steps, uint256 amountIn,
            ISignatureTransfer.PermitTransferFrom memory permitTransfer, bytes memory sig
        ) = abi.decode(data, (
            uint8, address, SwapStep[], uint256,
            ISignatureTransfer.PermitTransferFrom, bytes
        ));

        uint256 currentAmount = amountIn;

        for (uint256 i = 0; i < steps.length; i++) {
            SwapParams memory params = SwapParams({
                zeroForOne: steps[i].zeroForOne,
                amountSpecified: -int256(currentAmount),
                sqrtPriceLimitX96: steps[i].zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            });

            BalanceDelta delta = poolManager.swap(steps[i].poolKey, params, abi.encode(sender));
            _emitSwap(steps[i].poolKey, sender, delta);

            currentAmount = steps[i].zeroForOne
                ? uint256(int256(delta.amount1()))
                : uint256(int256(delta.amount0()));
        }

        uint256 amountOut = _settleAllDeltasPermit2(steps, sender, permitTransfer, sig);

        return abi.encode(amountOut);
    }

    /// @dev Collect unique currencies from all swap steps.
    function _collectCurrencies(SwapStep[] memory steps) internal pure returns (Currency[] memory) {
        Currency[] memory temp = new Currency[](steps.length * 2);
        uint256 count = 0;

        for (uint256 i = 0; i < steps.length; i++) {
            bool found0 = false;
            bool found1 = false;
            for (uint256 j = 0; j < count; j++) {
                if (Currency.unwrap(temp[j]) == Currency.unwrap(steps[i].poolKey.currency0)) found0 = true;
                if (Currency.unwrap(temp[j]) == Currency.unwrap(steps[i].poolKey.currency1)) found1 = true;
            }
            if (!found0) { temp[count] = steps[i].poolKey.currency0; count++; }
            if (!found1) { temp[count] = steps[i].poolKey.currency1; count++; }
        }

        Currency[] memory result = new Currency[](count);
        for (uint256 i = 0; i < count; i++) result[i] = temp[i];
        return result;
    }

    /// @dev Settle all non-zero currency deltas after multi-hop swap. Returns the output amount.
    function _settleAllDeltas(SwapStep[] memory steps, address sender) internal returns (uint256 amountOut) {
        Currency[] memory currencies = _collectCurrencies(steps);

        for (uint256 i = 0; i < currencies.length; i++) {
            int256 delta = poolManager.currencyDelta(address(this), currencies[i]);
            if (delta < 0) {
                uint256 amount = uint256(-delta);
                if (currencies[i].isAddressZero()) {
                    poolManager.settle{value: amount}();
                } else {
                    poolManager.sync(currencies[i]);
                    IERC20Minimal(Currency.unwrap(currencies[i])).transferFrom(
                        sender, address(poolManager), amount
                    );
                    poolManager.settle();
                }
            } else if (delta > 0) {
                uint256 amount = uint256(delta);
                poolManager.take(currencies[i], sender, amount);
                amountOut = amount;
            }
        }
    }

    /// @dev Settle all non-zero deltas using Permit2 for the input token.
    function _settleAllDeltasPermit2(
        SwapStep[] memory steps,
        address sender,
        ISignatureTransfer.PermitTransferFrom memory permitTransfer,
        bytes memory sig
    ) internal returns (uint256 amountOut) {
        Currency[] memory currencies = _collectCurrencies(steps);

        for (uint256 i = 0; i < currencies.length; i++) {
            int256 delta = poolManager.currencyDelta(address(this), currencies[i]);
            if (delta < 0) {
                uint256 amount = uint256(-delta);
                _settleWithPermit2(currencies[i], sender, amount, permitTransfer, sig);
            } else if (delta > 0) {
                uint256 amount = uint256(delta);
                poolManager.take(currencies[i], sender, amount);
                amountOut = amount;
            }
        }
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

    /// @dev Emit SwapExecuted with actual user address and post-swap pool state.
    function _emitSwap(PoolKey memory key, address sender, BalanceDelta delta) internal {
        (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(key.toId());
        emit SwapExecuted(key.toId(), sender, delta.amount0(), delta.amount1(), sqrtPriceX96, tick);
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
