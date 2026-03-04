// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseTestHooks} from "@uniswap/v4-core/src/test/BaseTestHooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {IEscrowVault} from "../interfaces/IEscrowVault.sol";
import {IReputationEngine} from "../interfaces/IReputationEngine.sol";
import {InsurancePool} from "../core/InsurancePool.sol";
import {ITriggerOracle} from "../interfaces/ITriggerOracle.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";

import {TriggerOracle} from "../core/TriggerOracle.sol";

/// @title BastionHook
/// @notice Main Uniswap V4 Hook for the BastionSwap protocol.
///         Intercepts pool lifecycle events to enforce escrow locking,
///         insurance fee collection, and rug-pull protection.
contract BastionHook is BaseTestHooks {
    using SafeTransferLib for ERC20;
    using PoolIdLibrary for PoolKey;

    // ─── Immutables ───────────────────────────────────────────────────

    IPoolManager public immutable poolManager;
    IEscrowVault public immutable escrowVault;
    InsurancePool public immutable insurancePool;
    TriggerOracle public immutable triggerOracle;
    IReputationEngine public immutable reputationEngine;

    // ─── Storage ──────────────────────────────────────────────────────

    /// @dev poolId => issuer address (first LP provider)
    mapping(PoolId => address) internal _issuers;

    /// @dev poolId => escrowId for the issuer's escrow
    mapping(PoolId => uint256) internal _escrowIds;

    /// @dev poolId => total LP liquidity tracked (for rug-pull detection)
    mapping(PoolId => uint256) internal _totalLiquidity;

    /// @dev poolId => token address that is the "issued" token (non-base asset)
    mapping(PoolId => address) internal _issuedTokens;

    // ─── Errors ───────────────────────────────────────────────────────

    error OnlyPoolManager();
    error InvalidHookData();

    // ─── Events ───────────────────────────────────────────────────────

    event IssuerRegistered(PoolId indexed poolId, address indexed issuer, address issuedToken);
    event EscrowCreated(PoolId indexed poolId, uint256 indexed escrowId, address indexed issuer);
    event InsuranceFeeDeposited(PoolId indexed poolId, uint256 amount);
    event IssuerSaleReported(PoolId indexed poolId, address indexed issuer, uint256 amount);
    event LPRemovalReported(PoolId indexed poolId, uint256 amount, uint256 totalLP);
    event ExternalCallFailed(string target, PoolId indexed poolId);

    // ─── Modifiers ────────────────────────────────────────────────────

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    // ─── Constructor ──────────────────────────────────────────────────

    constructor(
        IPoolManager _poolManager,
        IEscrowVault _escrowVault,
        InsurancePool _insurancePool,
        TriggerOracle _triggerOracle,
        IReputationEngine _reputationEngine
    ) {
        poolManager = _poolManager;
        escrowVault = _escrowVault;
        insurancePool = _insurancePool;
        triggerOracle = _triggerOracle;
        reputationEngine = _reputationEngine;
    }

    // ─── Hook Permission Flags ────────────────────────────────────────

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ═══════════════════════════════════════════════════════════════════
    //  HOOK CALLBACKS
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Called before liquidity is added. First LP provider becomes the issuer
    ///         and their funds are routed to EscrowVault.
    /// @dev hookData encoding for issuer's first LP:
    ///      abi.encode(issuer, token, amount, vestingSchedule, commitment, triggerConfig)
    function beforeAddLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4) {
        PoolId poolId = key.toId();

        // If no issuer registered yet, this is the first LP → register as issuer
        if (_issuers[poolId] == address(0) && hookData.length > 0) {
            _registerIssuerAndCreateEscrow(poolId, key, hookData);
        }

        // Track total liquidity
        if (params.liquidityDelta > 0) {
            _totalLiquidity[poolId] += uint256(int256(params.liquidityDelta));
        }

        return IHooks.beforeAddLiquidity.selector;
    }

    /// @notice Called before liquidity is removed. Reports LP removal to TriggerOracle.
    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4) {
        PoolId poolId = key.toId();
        uint256 removeAmount = params.liquidityDelta < 0
            ? uint256(uint128(int128(-params.liquidityDelta)))
            : 0;

        if (removeAmount > 0) {
            uint256 totalLP = _totalLiquidity[poolId];

            // Report LP removal to TriggerOracle (for all LPs, but especially issuers)
            if (_issuers[poolId] != address(0) && totalLP > 0) {
                try triggerOracle.reportLPRemoval(poolId, removeAmount, totalLP) {} catch {
                    emit ExternalCallFailed("TriggerOracle.reportLPRemoval", poolId);
                }
            }

            // Update tracked liquidity
            if (removeAmount <= _totalLiquidity[poolId]) {
                _totalLiquidity[poolId] -= removeAmount;
            } else {
                _totalLiquidity[poolId] = 0;
            }

            emit LPRemovalReported(poolId, removeAmount, totalLP);
        }

        return IHooks.beforeRemoveLiquidity.selector;
    }

    /// @notice Called after a swap. Deposits insurance fee on buys and
    ///         reports issuer sales to TriggerOracle.
    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, int128) {
        PoolId poolId = key.toId();
        address issuedToken = _issuedTokens[poolId];

        if (issuedToken != address(0)) {
            // Determine if this is a "buy" of the issued token
            // Buy = swapper receives the issued token
            bool isBuy = _isBuySwap(key, params, issuedToken);

            if (isBuy) {
                _collectInsuranceFee(poolId, delta, key, params, issuedToken);
            }

            // Check if issuer is selling tokens
            address poolIssuer = _issuers[poolId];
            if (sender == poolIssuer && !isBuy) {
                _reportIssuerSale(poolId, poolIssuer, delta, key, issuedToken);
            }
        }

        return (IHooks.afterSwap.selector, 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Check if an address is the issuer for a pool.
    function isIssuer(PoolId poolId, address account) external view returns (bool) {
        return _issuers[poolId] == account;
    }

    /// @notice Get pool info.
    function getPoolInfo(PoolId poolId)
        external
        view
        returns (address issuer, uint256 escrowId, address issuedToken, uint256 totalLiquidity)
    {
        issuer = _issuers[poolId];
        escrowId = _escrowIds[poolId];
        issuedToken = _issuedTokens[poolId];
        totalLiquidity = _totalLiquidity[poolId];
    }

    // ═══════════════════════════════════════════════════════════════════
    //  INTERNAL
    // ═══════════════════════════════════════════════════════════════════

    function _registerIssuerAndCreateEscrow(
        PoolId poolId,
        PoolKey calldata key,
        bytes calldata hookData
    ) internal {
        // Decode hookData — issuer address is explicitly provided
        (
            address issuer,
            address token,
            uint256 amount,
            IEscrowVault.VestingStep[] memory vestingSchedule,
            IEscrowVault.IssuerCommitment memory commitment,
            ITriggerOracle.TriggerConfig memory triggerConfig
        ) = abi.decode(
            hookData,
            (address, address, uint256, IEscrowVault.VestingStep[], IEscrowVault.IssuerCommitment, ITriggerOracle.TriggerConfig)
        );

        // Register issuer
        _issuers[poolId] = issuer;
        _issuedTokens[poolId] = token;

        // Pull tokens from issuer (who must have approved this hook) and approve to EscrowVault
        ERC20(token).safeTransferFrom(issuer, address(this), amount);
        ERC20(token).safeApprove(address(escrowVault), amount);

        // Create escrow
        uint256 escrowId = escrowVault.createEscrow(
            poolId, issuer, token, amount, vestingSchedule, commitment
        );
        _escrowIds[poolId] = escrowId;

        // Register issuer and config in TriggerOracle
        triggerOracle.registerIssuer(poolId, issuer);
        triggerOracle.setTriggerConfig(poolId, triggerConfig);

        // Record pool creation in reputation engine
        try reputationEngine.recordEvent(
            issuer,
            IReputationEngine.EventType.POOL_CREATED,
            abi.encode(token, amount, commitment)
        ) {} catch {
            emit ExternalCallFailed("ReputationEngine.recordEvent", poolId);
        }

        emit IssuerRegistered(poolId, issuer, token);
        emit EscrowCreated(poolId, escrowId, issuer);
    }

    /// @dev Determine if a swap is a "buy" of the issued token.
    ///      Buy = the swapper receives the issued token.
    function _isBuySwap(
        PoolKey calldata key,
        SwapParams calldata params,
        address issuedToken
    ) internal pure returns (bool) {
        bool issuedIsToken0 = Currency.unwrap(key.currency0) == issuedToken;
        // zeroForOne = selling token0 for token1
        // If issued token is token0: buy = !zeroForOne (swapper gets token0)
        // If issued token is token1: buy = zeroForOne (swapper gets token1)
        return issuedIsToken0 ? !params.zeroForOne : params.zeroForOne;
    }

    /// @dev Calculate and deposit insurance fee from a buy swap.
    function _collectInsuranceFee(
        PoolId poolId,
        BalanceDelta delta,
        PoolKey calldata key,
        SwapParams calldata params,
        address issuedToken
    ) internal {
        // The fee is based on the base asset (ETH/WETH) amount spent
        // For simplicity, we calculate fee on the "input" side of the swap
        uint256 feeRate = insurancePool.feeRate();
        if (feeRate == 0) return;

        // Get the amount of base asset spent (the non-issued token)
        // In a buy: swapper sends base asset, receives issued token
        bool issuedIsToken0 = Currency.unwrap(key.currency0) == issuedToken;
        int128 baseAmount;
        if (issuedIsToken0) {
            // base asset is token1, swapper sends token1 (negative delta = owes)
            baseAmount = delta.amount1();
        } else {
            // base asset is token0, swapper sends token0 (negative delta = owes)
            baseAmount = delta.amount0();
        }

        // baseAmount is negative (swapper owes), so negate
        if (baseAmount >= 0) return;
        uint256 absBaseAmount = uint256(uint128(int128(-baseAmount)));

        uint256 feeAmount = (absBaseAmount * feeRate) / 10_000;
        if (feeAmount == 0) return;

        // The fee is deposited as ETH to InsurancePool
        // In a real deployment, the hook would take from the pool's balance.
        // For now, we emit the event and try to forward ETH if available.
        if (address(this).balance >= feeAmount) {
            insurancePool.depositFee{value: feeAmount}(poolId);
            emit InsuranceFeeDeposited(poolId, feeAmount);
        }
    }

    /// @dev Report issuer token sale to TriggerOracle.
    function _reportIssuerSale(
        PoolId poolId,
        address issuer,
        BalanceDelta delta,
        PoolKey calldata key,
        address issuedToken
    ) internal {
        // The issuer sold the issued token (sell = !buy)
        bool issuedIsToken0 = Currency.unwrap(key.currency0) == issuedToken;
        int128 issuedAmount;
        if (issuedIsToken0) {
            issuedAmount = delta.amount0();
        } else {
            issuedAmount = delta.amount1();
        }

        // In a sell, the swapper sends issued tokens (negative delta)
        if (issuedAmount >= 0) return;
        uint256 soldAmount = uint256(uint128(int128(-issuedAmount)));

        // Get total supply for percentage calculation
        uint256 totalSupply = ERC20(issuedToken).totalSupply();
        if (totalSupply == 0) return;

        try triggerOracle.reportIssuerSale(poolId, issuer, soldAmount, totalSupply) {} catch {
            emit ExternalCallFailed("TriggerOracle.reportIssuerSale", poolId);
        }

        emit IssuerSaleReported(poolId, issuer, soldAmount);
    }

    /// @dev Allow receiving ETH for insurance fee deposits
    receive() external payable {}
}
