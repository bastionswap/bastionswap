// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";
import {IBastionRouter} from "../interfaces/IBastionRouter.sol";

/// @title BastionPositionRouter
/// @notice Pool creation and LP management router for Uniswap V4 pools with BastionHook.
contract BastionPositionRouter is IUnlockCallback, IBastionRouter {
    using CurrencyLibrary for Currency;
    using TransientStateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager public immutable poolManager;
    ISignatureTransfer public immutable permit2;

    uint8 private constant ACTION_CREATE_POOL = 0;
    uint8 private constant ACTION_ADD_LIQUIDITY_V2 = 1;
    uint8 private constant ACTION_REMOVE_LIQUIDITY_V2 = 2;
    uint8 private constant ACTION_COLLECT_FEES = 3;
    uint8 private constant ACTION_FORCE_REMOVE_ISSUER_LP = 4;
    uint8 private constant ACTION_CREATE_POOL_PERMIT2 = 5;
    uint8 private constant ACTION_ADD_LIQUIDITY_V2_PERMIT2 = 6;
    uint8 private constant ACTION_REMOVE_ISSUER_LP = 7;
    uint8 private constant ACTION_COLLECT_ISSUER_FEES = 8;
    uint8 private constant ACTION_FORCE_COLLECT_FEES = 9;

    /// @dev BastionHook address for access control on forceRemoveLiquidity
    address public bastionHook;

    struct CreatePoolParams {
        PoolKey key;
        uint160 sqrtPriceX96;
        uint256 amount0Max;
        uint256 amount1Max;
        bytes hookData;
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
    error SlippageExceeded();

    event LiquidityChanged(
        PoolId indexed poolId, address indexed user,
        int24 tickLower, int24 tickUpper,
        int256 liquidityDelta, int128 amount0, int128 amount1
    );

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
    function forceRemoveLiquidity(PoolKey calldata key, uint128 liquidity, address recipient) external override {
        if (msg.sender != bastionHook) revert OnlyHook();
        poolManager.unlock(abi.encode(ACTION_FORCE_REMOVE_ISSUER_LP, recipient, key, liquidity));
    }

    /// @notice Force-collects unclaimed fees from issuer's salt-0 position.
    /// @dev Called by BastionHook during force removal. Only callable by the hook.
    function forceCollectFees(PoolKey calldata key, address recipient) external override {
        if (msg.sender != bastionHook) revert OnlyHook();
        int24 tickSpacing = key.tickSpacing;
        int24 tickLower = (TickMath.MIN_TICK / tickSpacing) * tickSpacing;
        int24 tickUpper = (TickMath.MAX_TICK / tickSpacing) * tickSpacing;
        poolManager.unlock(abi.encode(ACTION_FORCE_COLLECT_FEES, recipient, key, tickLower, tickUpper));
    }

    // ═══════════════════════════════════════════════════════════════
    //  POOL CREATION
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

    /// @notice Create a pool using Permit2 for token transfers.
    function createPoolPermit2(
        address token,
        address baseToken,
        uint24 fee,
        uint256 tokenAmount,
        uint256 baseAmount,
        uint160 sqrtPriceX96,
        bytes calldata hookData,
        bytes calldata permitData
    ) external payable returns (PoolId poolId) {
        if (bastionHook == address(0)) revert HookNotSet();

        (PoolKey memory key, uint256 amount0Max, uint256 amount1Max) =
            _buildPoolKey(token, baseToken, fee, tokenAmount, baseAmount);

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

    // ═══════════════════════════════════════════════════════════════
    //  GENERAL LP FUNCTIONS (V2 — per-user salt isolation)
    // ═══════════════════════════════════════════════════════════════

    /// @notice Add liquidity to an existing pool with per-user position isolation.
    function addLiquidityV2(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Max,
        uint256 amount1Max,
        uint256 deadline
    ) external payable {
        if (block.timestamp > deadline) revert Expired();
        (tickLower, tickUpper) = _resolveTicks(key.tickSpacing, tickLower, tickUpper);
        poolManager.unlock(abi.encode(
            ACTION_ADD_LIQUIDITY_V2, msg.sender, key, tickLower, tickUpper, amount0Max, amount1Max
        ));
        _refundETH();
    }

    /// @notice Add liquidity using Permit2 for ERC20 deposits.
    function addLiquidityV2Permit2(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Max,
        uint256 amount1Max,
        uint256 deadline,
        bytes calldata permitData
    ) external payable {
        if (block.timestamp > deadline) revert Expired();
        (tickLower, tickUpper) = _resolveTicks(key.tickSpacing, tickLower, tickUpper);
        poolManager.unlock(abi.encode(
            ACTION_ADD_LIQUIDITY_V2_PERMIT2, msg.sender, key, tickLower, tickUpper, amount0Max, amount1Max, permitData
        ));
        _refundETH();
    }

    /// @notice Remove liquidity from a per-user isolated position.
    function removeLiquidityV2(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidityToRemove,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline
    ) external {
        if (block.timestamp > deadline) revert Expired();
        (tickLower, tickUpper) = _resolveTicks(key.tickSpacing, tickLower, tickUpper);
        BalanceDelta delta = abi.decode(
            poolManager.unlock(abi.encode(
                ACTION_REMOVE_LIQUIDITY_V2, msg.sender, key, tickLower, tickUpper, liquidityToRemove
            )),
            (BalanceDelta)
        );
        uint256 out0 = delta.amount0() > 0 ? uint256(int256(delta.amount0())) : 0;
        uint256 out1 = delta.amount1() > 0 ? uint256(int256(delta.amount1())) : 0;
        if (out0 < amount0Min || out1 < amount1Min) revert SlippageExceeded();
        _refundETH();
    }

    /// @notice Remove issuer LP (salt=0 position from createPool).
    ///         Vesting is enforced by the hook's beforeRemoveLiquidity.
    function removeIssuerLiquidity(
        PoolKey calldata key,
        uint128 liquidityToRemove,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline
    ) external {
        if (block.timestamp > deadline) revert Expired();
        int24 tickSpacing = key.tickSpacing;
        int24 tickLower = (TickMath.MIN_TICK / tickSpacing) * tickSpacing;
        int24 tickUpper = (TickMath.MAX_TICK / tickSpacing) * tickSpacing;
        BalanceDelta delta = abi.decode(
            poolManager.unlock(abi.encode(
                ACTION_REMOVE_ISSUER_LP, msg.sender, key, tickLower, tickUpper, liquidityToRemove
            )),
            (BalanceDelta)
        );
        uint256 out0 = delta.amount0() > 0 ? uint256(int256(delta.amount0())) : 0;
        uint256 out1 = delta.amount1() > 0 ? uint256(int256(delta.amount1())) : 0;
        if (out0 < amount0Min || out1 < amount1Min) revert SlippageExceeded();
        _refundETH();
    }

    /// @notice Collect accumulated fees for a per-user position.
    function collectFees(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper
    ) external {
        (tickLower, tickUpper) = _resolveTicks(key.tickSpacing, tickLower, tickUpper);
        poolManager.unlock(abi.encode(
            ACTION_COLLECT_FEES, msg.sender, key, tickLower, tickUpper
        ));
        _refundETH();
    }

    /// @notice Collect accumulated fees for the issuer's salt-0 position.
    /// @dev Issuer LP uses salt=0, so needs a separate fee collection path.
    ///      Passes hookData with sender so BastionHook can verify issuer & check trigger.
    function collectIssuerFees(PoolKey calldata key) external {
        int24 tickSpacing = key.tickSpacing;
        int24 tickLower = (TickMath.MIN_TICK / tickSpacing) * tickSpacing;
        int24 tickUpper = (TickMath.MAX_TICK / tickSpacing) * tickSpacing;
        poolManager.unlock(abi.encode(
            ACTION_COLLECT_ISSUER_FEES, msg.sender, key, tickLower, tickUpper
        ));
        _refundETH();
    }

    /// @notice View a user's position liquidity.
    function getPositionLiquidity(
        PoolKey calldata key,
        address owner,
        int24 tickLower,
        int24 tickUpper
    ) external view returns (uint128 liquidity) {
        (tickLower, tickUpper) = _resolveTicks(key.tickSpacing, tickLower, tickUpper);
        bytes32 salt = bytes32(uint256(uint160(owner)));
        bytes32 positionKey = keccak256(abi.encodePacked(address(this), tickLower, tickUpper, salt));
        liquidity = poolManager.getPositionLiquidity(key.toId(), positionKey);
    }

    // ═══════════════════════════════════════════════════════════════
    //  UNLOCK CALLBACK
    // ═══════════════════════════════════════════════════════════════

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();

        uint8 action = abi.decode(data, (uint8));

        if (action == ACTION_CREATE_POOL) {
            return _handleCreatePool(data);
        } else if (action == ACTION_ADD_LIQUIDITY_V2) {
            return _handleAddLPV2(data);
        } else if (action == ACTION_REMOVE_LIQUIDITY_V2) {
            return _handleRemoveLPV2(data);
        } else if (action == ACTION_COLLECT_FEES) {
            return _handleCollectFees(data);
        } else if (action == ACTION_FORCE_REMOVE_ISSUER_LP) {
            return _handleForceRemoveLP(data);
        } else if (action == ACTION_CREATE_POOL_PERMIT2) {
            return _handleCreatePoolPermit2(data);
        } else if (action == ACTION_ADD_LIQUIDITY_V2_PERMIT2) {
            return _handleAddLPV2Permit2(data);
        } else if (action == ACTION_REMOVE_ISSUER_LP) {
            return _handleRemoveIssuerLP(data);
        } else if (action == ACTION_COLLECT_ISSUER_FEES) {
            return _handleCollectIssuerFees(data);
        } else if (action == ACTION_FORCE_COLLECT_FEES) {
            return _handleForceCollectFees(data);
        }

        revert("Unknown action");
    }

    // ═══════════════════════════════════════════════════════════════
    //  INTERNAL HANDLERS
    // ═══════════════════════════════════════════════════════════════

    function _handleCreatePool(bytes calldata data) internal returns (bytes memory) {
        (, address sender, CreatePoolParams memory params) =
            abi.decode(data, (uint8, address, CreatePoolParams));

        (BalanceDelta delta, uint128 liquidity, int24 tickLower, int24 tickUpper) = _initAndAddLiquidity(params);

        _settle(params.key.currency0, sender, delta.amount0());
        _settle(params.key.currency1, sender, delta.amount1());

        emit LiquidityChanged(params.key.toId(), sender, tickLower, tickUpper,
            int256(uint256(liquidity)), delta.amount0(), delta.amount1());

        return abi.encode(delta);
    }

    function _handleCreatePoolPermit2(bytes calldata data) internal returns (bytes memory) {
        (, address sender, CreatePoolParams memory params, bytes memory permitData) =
            abi.decode(data, (uint8, address, CreatePoolParams, bytes));

        (BalanceDelta delta, uint128 liquidity, int24 tickLower, int24 tickUpper) = _initAndAddLiquidity(params);

        if (params.key.currency0.isAddressZero()) {
            _settleCreatePoolNativePermit2(params.key, sender, delta, permitData);
        } else {
            _settleCreatePoolBatchPermit2(params.key, sender, delta, permitData);
        }

        emit LiquidityChanged(params.key.toId(), sender, tickLower, tickUpper,
            int256(uint256(liquidity)), delta.amount0(), delta.amount1());

        return abi.encode(delta);
    }

    /// @dev Initialize pool and add full-range liquidity. Shared by both createPool handlers.
    function _initAndAddLiquidity(CreatePoolParams memory params)
        internal
        returns (BalanceDelta delta, uint128 liquidity, int24 tickLower, int24 tickUpper)
    {
        poolManager.initialize(params.key, params.sqrtPriceX96);

        int24 tickSpacing = params.key.tickSpacing;
        tickLower = (TickMath.MIN_TICK / tickSpacing) * tickSpacing;
        tickUpper = (TickMath.MAX_TICK / tickSpacing) * tickSpacing;

        liquidity = LiquidityAmounts.getLiquidityForAmounts(
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
        (ISignatureTransfer.PermitTransferFrom memory permit, bytes memory sig) =
            abi.decode(permitData, (ISignatureTransfer.PermitTransferFrom, bytes));

        int128 amount0 = delta.amount0();
        if (amount0 < 0) {
            poolManager.settle{value: uint256(uint128(-amount0))}();
        } else if (amount0 > 0) {
            poolManager.take(key.currency0, sender, uint256(uint128(amount0)));
        }

        int128 amount1 = delta.amount1();
        if (amount1 < 0) {
            _settleWithPermit2(key.currency1, sender, uint256(uint128(-amount1)), permit, sig);
        } else if (amount1 > 0) {
            poolManager.take(key.currency1, sender, uint256(uint128(amount1)));
        }
    }

    /// @dev Settle createPool with ERC20 + ERC20: use batch Permit2 for both tokens.
    function _settleCreatePoolBatchPermit2(
        PoolKey memory key, address sender, BalanceDelta delta, bytes memory permitData
    ) internal {
        (ISignatureTransfer.PermitBatchTransferFrom memory permit, bytes memory sig) =
            abi.decode(permitData, (ISignatureTransfer.PermitBatchTransferFrom, bytes));

        uint256 needed0 = delta.amount0() < 0 ? uint256(uint128(-delta.amount0())) : 0;
        uint256 needed1 = delta.amount1() < 0 ? uint256(uint128(-delta.amount1())) : 0;

        if (needed0 > 0 || needed1 > 0) {
            poolManager.sync(key.currency0);
            poolManager.sync(key.currency1);

            ISignatureTransfer.SignatureTransferDetails[] memory td =
                new ISignatureTransfer.SignatureTransferDetails[](2);
            td[0] = ISignatureTransfer.SignatureTransferDetails({to: address(poolManager), requestedAmount: needed0});
            td[1] = ISignatureTransfer.SignatureTransferDetails({to: address(poolManager), requestedAmount: needed1});

            permit2.permitTransferFrom(permit, td, sender, sig);

            if (needed0 > 0) poolManager.settle();
            if (needed1 > 0) poolManager.settle();
        }

        if (delta.amount0() > 0) poolManager.take(key.currency0, sender, uint256(uint128(delta.amount0())));
        if (delta.amount1() > 0) poolManager.take(key.currency1, sender, uint256(uint128(delta.amount1())));
    }

    function _handleForceRemoveLP(bytes calldata data) internal returns (bytes memory) {
        (, address recipient, PoolKey memory key, uint128 liquidity) =
            abi.decode(data, (uint8, address, PoolKey, uint128));

        int24 tickSpacing = key.tickSpacing;
        int24 tickLower = (TickMath.MIN_TICK / tickSpacing) * tickSpacing;
        int24 tickUpper = (TickMath.MAX_TICK / tickSpacing) * tickSpacing;

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

        _settleToRecipient(key.currency0, recipient, delta.amount0());
        _settleToRecipient(key.currency1, recipient, delta.amount1());

        return abi.encode(delta);
    }

    // ═══════════════════════════════════════════════════════════════
    //  V2 LP HANDLERS (per-user salt isolation)
    // ═══════════════════════════════════════════════════════════════

    function _handleAddLPV2(bytes calldata data) internal returns (bytes memory) {
        (, address sender, PoolKey memory key, int24 tickLower, int24 tickUpper, uint256 amount0Max, uint256 amount1Max) =
            abi.decode(data, (uint8, address, PoolKey, int24, int24, uint256, uint256));

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0Max,
            amount1Max
        );

        bytes32 salt = bytes32(uint256(uint160(sender)));

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: salt
            }),
            abi.encode(sender)
        );

        _settle(key.currency0, sender, delta.amount0());
        _settle(key.currency1, sender, delta.amount1());

        emit LiquidityChanged(key.toId(), sender, tickLower, tickUpper, int256(uint256(liquidity)), delta.amount0(), delta.amount1());

        return abi.encode(delta);
    }

    function _handleAddLPV2Permit2(bytes calldata data) internal returns (bytes memory) {
        (, address sender, PoolKey memory key, int24 tickLower, int24 tickUpper, uint256 amount0Max, uint256 amount1Max, bytes memory permitData) =
            abi.decode(data, (uint8, address, PoolKey, int24, int24, uint256, uint256, bytes));

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0Max,
            amount1Max
        );

        bytes32 salt = bytes32(uint256(uint160(sender)));

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: salt
            }),
            abi.encode(sender)
        );

        if (key.currency0.isAddressZero()) {
            _settleCreatePoolNativePermit2(key, sender, delta, permitData);
        } else {
            _settleCreatePoolBatchPermit2(key, sender, delta, permitData);
        }

        emit LiquidityChanged(key.toId(), sender, tickLower, tickUpper, int256(uint256(liquidity)), delta.amount0(), delta.amount1());

        return abi.encode(delta);
    }

    function _handleRemoveLPV2(bytes calldata data) internal returns (bytes memory) {
        (, address sender, PoolKey memory key, int24 tickLower, int24 tickUpper, uint128 liquidityToRemove) =
            abi.decode(data, (uint8, address, PoolKey, int24, int24, uint128));

        bytes32 salt = bytes32(uint256(uint160(sender)));

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: -int256(uint256(liquidityToRemove)),
                salt: salt
            }),
            abi.encode(sender)
        );

        _settle(key.currency0, sender, delta.amount0());
        _settle(key.currency1, sender, delta.amount1());

        emit LiquidityChanged(key.toId(), sender, tickLower, tickUpper, -int256(uint256(liquidityToRemove)), delta.amount0(), delta.amount1());

        return abi.encode(delta);
    }

    function _handleRemoveIssuerLP(bytes calldata data) internal returns (bytes memory) {
        (, address sender, PoolKey memory key, int24 tickLower, int24 tickUpper, uint128 liquidityToRemove) =
            abi.decode(data, (uint8, address, PoolKey, int24, int24, uint128));

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: -int256(uint256(liquidityToRemove)),
                salt: 0
            }),
            abi.encode(sender)
        );

        _settle(key.currency0, sender, delta.amount0());
        _settle(key.currency1, sender, delta.amount1());

        emit LiquidityChanged(key.toId(), sender, tickLower, tickUpper, -int256(uint256(liquidityToRemove)), delta.amount0(), delta.amount1());

        return abi.encode(delta);
    }

    function _handleCollectFees(bytes calldata data) internal returns (bytes memory) {
        (, address sender, PoolKey memory key, int24 tickLower, int24 tickUpper) =
            abi.decode(data, (uint8, address, PoolKey, int24, int24));

        bytes32 salt = bytes32(uint256(uint160(sender)));

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: 0,
                salt: salt
            }),
            ""
        );

        _settle(key.currency0, sender, delta.amount0());
        _settle(key.currency1, sender, delta.amount1());

        emit LiquidityChanged(key.toId(), sender, tickLower, tickUpper, 0, delta.amount0(), delta.amount1());

        return abi.encode(delta);
    }

    function _handleCollectIssuerFees(bytes calldata data) internal returns (bytes memory) {
        (, address sender, PoolKey memory key, int24 tickLower, int24 tickUpper) =
            abi.decode(data, (uint8, address, PoolKey, int24, int24));

        // Issuer LP uses salt=0, pass hookData so hook can verify issuer & check trigger
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: 0,
                salt: 0
            }),
            abi.encode(sender)
        );

        _settle(key.currency0, sender, delta.amount0());
        _settle(key.currency1, sender, delta.amount1());

        emit LiquidityChanged(key.toId(), sender, tickLower, tickUpper, 0, delta.amount0(), delta.amount1());

        return abi.encode(delta);
    }

    /// @dev Force-collect issuer fees during trigger. Sends to recipient (BastionHook).
    function _handleForceCollectFees(bytes calldata data) internal returns (bytes memory) {
        (, address recipient, PoolKey memory key, int24 tickLower, int24 tickUpper) =
            abi.decode(data, (uint8, address, PoolKey, int24, int24));

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: 0,
                salt: 0
            }),
            ""
        );

        _settleToRecipient(key.currency0, recipient, delta.amount0());
        _settleToRecipient(key.currency1, recipient, delta.amount1());

        return abi.encode(delta);
    }

    // ═══════════════════════════════════════════════════════════════
    //  INTERNAL HELPERS
    // ═══════════════════════════════════════════════════════════════

    /// @dev If both ticks are 0, resolve to full-range aligned to tickSpacing.
    function _resolveTicks(int24 tickSpacing, int24 tl, int24 tu) internal pure returns (int24, int24) {
        if (tl == 0 && tu == 0) {
            tl = (TickMath.MIN_TICK / tickSpacing) * tickSpacing;
            tu = (TickMath.MAX_TICK / tickSpacing) * tickSpacing;
        }
        return (tl, tu);
    }

    /// @dev Build PoolKey and sorted amounts for createPool variants.
    function _buildPoolKey(
        address token,
        address baseToken,
        uint24 fee,
        uint256 tokenAmount,
        uint256 baseAmount
    ) internal view returns (PoolKey memory key, uint256 amount0Max, uint256 amount1Max) {
        if (baseToken == address(0)) baseAmount = msg.value;

        if (uint160(baseToken) < uint160(token)) {
            key = PoolKey(Currency.wrap(baseToken), Currency.wrap(token), fee, 60, IHooks(bastionHook));
            amount0Max = baseAmount;
            amount1Max = tokenAmount;
        } else {
            key = PoolKey(Currency.wrap(token), Currency.wrap(baseToken), fee, 60, IHooks(bastionHook));
            amount0Max = tokenAmount;
            amount1Max = baseAmount;
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

    /// @dev Settlement for force removal: positive deltas go to recipient, negatives settle from pool
    function _settleToRecipient(Currency currency, address recipient, int128 amount) internal {
        if (amount > 0) {
            uint256 amountToReceive = uint256(uint128(amount));
            poolManager.take(currency, recipient, amountToReceive);
        }
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
