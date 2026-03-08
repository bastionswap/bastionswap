// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.26;

import {BaseTestHooks} from "@uniswap/v4-core/src/test/BaseTestHooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {IEscrowVault} from "../interfaces/IEscrowVault.sol";
import {IBastionRouter} from "../interfaces/IBastionRouter.sol";
import {IReputationEngine} from "../interfaces/IReputationEngine.sol";
import {InsurancePool} from "../core/InsurancePool.sol";
import {ITriggerOracle} from "../interfaces/ITriggerOracle.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {TriggerOracle} from "../core/TriggerOracle.sol";

/// @title BastionHook
/// @notice Main Uniswap V4 Hook for the BastionSwap protocol.
///         Intercepts pool lifecycle events to enforce escrow locking,
///         insurance fee collection, and rug-pull protection.
contract BastionHook is BaseTestHooks {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ─── Immutables ───────────────────────────────────────────────────

    IPoolManager public immutable poolManager;
    IEscrowVault public immutable escrowVault;
    InsurancePool public immutable insurancePool;
    TriggerOracle public immutable triggerOracle;
    IReputationEngine public immutable reputationEngine;
    address public immutable GOVERNANCE;

    // ─── Storage ──────────────────────────────────────────────────────

    /// @dev poolId => issuer address (first LP provider)
    mapping(PoolId => address) internal _issuers;

    /// @dev poolId => escrowId for the issuer's escrow
    mapping(PoolId => uint256) internal _escrowIds;

    /// @dev poolId => total LP liquidity tracked (for rug-pull detection)
    mapping(PoolId => uint256) internal _totalLiquidity;

    /// @dev poolId => token address that is the "issued" token (non-base asset)
    mapping(PoolId => address) internal _issuedTokens;

    /// @dev poolId => router address that created the issuer's LP position
    mapping(PoolId => address) internal _issuerLPOwner;

    /// @dev poolId => PoolKey stored during issuer registration for force removal
    mapping(PoolId => PoolKey) internal _poolKeys;

    /// @dev BastionRouter address (set via one-time setter, deployed after hook due to CREATE2)
    address public bastionRouter;

    /// @dev Owner address for setBastionRouter (deployer)
    address internal _owner;

    /// @dev Cached insurance fee rate (basis points) to avoid cross-contract call
    uint16 internal _cachedFeeRate;

    /// @dev Base token allowlist: token address => allowed
    mapping(address => bool) public allowedBaseTokens;

    /// @dev Minimum base token amount for initial liquidity per base token
    mapping(address => uint256) public minBaseAmount;

    // ─── Errors ───────────────────────────────────────────────────────

    error OnlyPoolManager();
    error OnlyEscrowVault();
    error OnlyOwner();
    error OnlyGovernance();
    error RouterAlreadySet();
    error RouterNotSet();
    error InvalidHookData();
    error ExceedsVestedAmount(uint128 requested, uint128 removable);
    error MustIdentifyUser();
    error BelowMinBaseAmount(uint256 provided, uint256 required);
    error NoAllowedBaseToken();
    error BaseTokenAlreadySet(address token);
    error BaseTokenNotSet(address token);
    error EscrowTriggered();

    // ─── Events ───────────────────────────────────────────────────────

    event IssuerRegistered(PoolId indexed poolId, address indexed issuer, address issuedToken);
    event EscrowCreated(PoolId indexed poolId, uint256 indexed escrowId, address indexed issuer);
    event InsuranceFeeDeposited(PoolId indexed poolId, uint256 amount);
    event IssuerSaleReported(PoolId indexed poolId, address indexed issuer, uint256 amount);
    event LPRemovalReported(PoolId indexed poolId, uint256 amount, uint256 totalLP);
    event ExternalCallFailed(string target, PoolId indexed poolId);
    event ForceRemovalExecuted(PoolId indexed poolId, uint256 ethAmount, address token, uint256 tokenAmount);
    event BastionRouterSet(address indexed router);
    event BaseTokenAdded(address indexed token, uint256 minAmount);
    event BaseTokenRemoved(address indexed token);
    event MinBaseAmountUpdated(address indexed token, uint256 newMinAmount);

    // ─── Modifiers ────────────────────────────────────────────────────

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    // ─── Constructor ──────────────────────────────────────────────────

    modifier onlyGovernance() {
        if (msg.sender != GOVERNANCE) revert OnlyGovernance();
        _;
    }

    constructor(
        IPoolManager _poolManager,
        IEscrowVault _escrowVault,
        InsurancePool _insurancePool,
        TriggerOracle _triggerOracle,
        IReputationEngine _reputationEngine,
        address _governance,
        address _weth,
        address _usdc
    ) {
        poolManager = _poolManager;
        escrowVault = _escrowVault;
        insurancePool = _insurancePool;
        triggerOracle = _triggerOracle;
        reputationEngine = _reputationEngine;
        GOVERNANCE = _governance;
        _owner = _governance;

        // Initialize base tokens
        allowedBaseTokens[address(0)] = true; // native ETH
        minBaseAmount[address(0)] = 1 ether;
        allowedBaseTokens[_weth] = true;
        minBaseAmount[_weth] = 1 ether;
        allowedBaseTokens[_usdc] = true;
        minBaseAmount[_usdc] = 2000e6; // 2000 USDC (6 decimals)
    }

    // ─── Hook Permission Flags ────────────────────────────────────────

    /// @notice Returns the hook permission flags for Uniswap V4.
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ═══════════════════════════════════════════════════════════════════
    //  HOOK CALLBACKS
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Called before liquidity is added. First LP provider becomes the issuer
    ///         and their LP is registered in EscrowVault.
    /// @dev hookData encoding for issuer's first LP:
    ///      abi.encode(issuer, token, lockDuration, vestingDuration, commitment, triggerConfig)
    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4) {
        PoolId poolId = key.toId();
        uint128 liquidity = params.liquidityDelta > 0
            ? uint128(uint256(int256(params.liquidityDelta)))
            : 0;

        if (_issuers[poolId] == address(0) && hookData.length > 0) {
            // First LP → register as issuer, enforce base token allowlist & min amount
            uint8 result = _validateBaseToken(key, params);
            if (result == 2) {
                // Both tokens are base tokens → skip Bastion protection
                return IHooks.beforeAddLiquidity.selector;
            }
            // result == 1 means validation passed (single base token, amount OK)

            _registerIssuerAndCreateEscrow(poolId, key, sender, liquidity, hookData);
        } else if (liquidity > 0 && sender == _issuerLPOwner[poolId]) {
            // Subsequent issuer LP addition via same router → decode hookData to identify user
            if (hookData.length > 0) {
                address user = abi.decode(hookData, (address));
                if (user == _issuers[poolId]) {
                    // All issuer LP additions get locked in escrow
                    uint256 escrowId = _escrowIds[poolId];
                    escrowVault.addLiquidity(escrowId, liquidity);
                }
            }
        }

        // Track total liquidity
        if (liquidity > 0) {
            _totalLiquidity[poolId] += liquidity;

            // RISK-4: Report LP addition for flash-loan inflation tracking
            if (_issuers[poolId] != address(0)) {
                try triggerOracle.reportLPAddition(poolId, liquidity) {} catch {
                    emit ExternalCallFailed("TriggerOracle.reportLPAddition", poolId);
                }
            }
        }

        return IHooks.beforeAddLiquidity.selector;
    }

    /// @notice Called before liquidity is removed. Enforces vesting for issuer's LP.
    ///         Non-issuer LP is completely free — no restrictions.
    ///         Force removal via trigger bypasses all vesting checks.
    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4) {
        PoolId poolId = key.toId();
        address issuer = _issuers[poolId];

        // No escrow on this pool → pass through
        if (issuer == address(0)) {
            return IHooks.beforeRemoveLiquidity.selector;
        }

        uint256 removeAmount = params.liquidityDelta < 0
            ? uint256(uint128(int128(-params.liquidityDelta)))
            : 0;

        if (removeAmount == 0) {
            // Fee collection (liquidityDelta == 0)
            // Block issuer fee collection after trigger
            if (sender == _issuerLPOwner[poolId] && hookData.length > 0) {
                address user = abi.decode(hookData, (address));
                if (user == issuer) {
                    uint256 escrowId = _escrowIds[poolId];
                    if (escrowVault.isTriggered(escrowId)) {
                        revert EscrowTriggered();
                    }
                }
            }
            return IHooks.beforeRemoveLiquidity.selector;
        }

        // Force removal in progress → skip all vesting checks
        if (_tload(_FORCE_REMOVAL_SLOT) == 1) {
            // Only update tracked liquidity (forceRemoveIssuerLP handles the rest)
            uint256 currentLP = _totalLiquidity[poolId];
            if (removeAmount <= currentLP) {
                _totalLiquidity[poolId] = currentLP - removeAmount;
            } else {
                _totalLiquidity[poolId] = 0;
            }
            return IHooks.beforeRemoveLiquidity.selector;
        }

        // Check if this is the issuer removing LP
        bool isIssuerRemoval = false;
        if (sender == _issuerLPOwner[poolId]) {
            if (hookData.length == 0) revert MustIdentifyUser();
            address user = abi.decode(hookData, (address));
            if (user == issuer) {
                isIssuerRemoval = true;
                // Enforce vesting
                uint256 escrowId = _escrowIds[poolId];
                uint128 liquidityToRemove = uint128(removeAmount);
                uint128 removable = escrowVault.getRemovableLiquidity(escrowId);
                if (liquidityToRemove > removable) {
                    revert ExceedsVestedAmount(liquidityToRemove, removable);
                }
                escrowVault.recordLPRemoval(escrowId, liquidityToRemove);
            }
            // else: non-issuer using same router → allow freely
        }
        // else: different router → different position → allow freely

        uint256 totalLP = _totalLiquidity[poolId];

        // Update tracked liquidity (CEI pattern)
        if (removeAmount <= totalLP) {
            _totalLiquidity[poolId] = totalLP - removeAmount;
        } else {
            _totalLiquidity[poolId] = 0;
        }

        // Report LP removal to TriggerOracle ONLY for issuer removals
        if (isIssuerRemoval && totalLP > 0) {
            try triggerOracle.reportLPRemoval(poolId, removeAmount, totalLP) {} catch {
                emit ExternalCallFailed("TriggerOracle.reportLPRemoval", poolId);
            }
        }

        emit LPRemovalReported(poolId, removeAmount, totalLP);

        return IHooks.beforeRemoveLiquidity.selector;
    }

    /// @notice Called before a swap. Snapshots issuer balance for router bypass detection (RISK-3).
    ///         Uses EIP-1153 transient storage to pass data to afterSwap within the same tx.
    function beforeSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();
        address issuedToken = _issuedTokens[poolId];
        address poolIssuer = _issuers[poolId];

        // Cache issuedToken and issuer in transient storage for afterSwap
        _tstore(_issuedTokenSlot(poolId), uint256(uint160(issuedToken)));
        _tstore(_issuerSlot(poolId), uint256(uint160(poolIssuer)));

        if (issuedToken != address(0) && poolIssuer != address(0)) {
            _tstore(_preSwapBalanceSlot(poolId), ERC20(issuedToken).balanceOf(poolIssuer));
        }

        // Collect insurance fee on exactInput buy swaps
        if (issuedToken != address(0) && params.amountSpecified < 0) {
            bool isBuy = _isBuySwap(key, params, issuedToken);
            if (isBuy) {
                BeforeSwapDelta feeDelta = _collectInsuranceFee(poolId, key, params, issuedToken);
                return (IHooks.beforeSwap.selector, feeDelta, 0);
            }
        }

        return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
    }

    /// @notice Called after a swap. Deposits insurance fee on buys and
    ///         reports issuer sales to TriggerOracle.
    function afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, int128) {
        PoolId poolId = key.toId();
        address issuedToken = address(uint160(_tload(_issuedTokenSlot(poolId))));

        if (issuedToken != address(0)) {
            // RISK-3: Check if issuer balance decreased (detects router bypass)
            address poolIssuer = address(uint160(_tload(_issuerSlot(poolId))));
            if (poolIssuer != address(0)) {
                uint256 preBalance = _tload(_preSwapBalanceSlot(poolId));
                uint256 postBalance = ERC20(issuedToken).balanceOf(poolIssuer);
                if (postBalance < preBalance) {
                    uint256 soldAmount = preBalance - postBalance;
                    uint256 totalSupply = ERC20(issuedToken).totalSupply();
                    if (totalSupply > 0) {
                        try triggerOracle.reportIssuerSale(poolId, poolIssuer, soldAmount, totalSupply) {} catch {
                            emit ExternalCallFailed("TriggerOracle.reportIssuerSale", poolId);
                        }
                        emit IssuerSaleReported(poolId, poolIssuer, soldAmount);
                    }
                }
            }
        }

        return (IHooks.afterSwap.selector, 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  FORCE REMOVAL
    // ═══════════════════════════════════════════════════════════════════

    /// @dev Transient storage slot for force removal in-progress flag
    bytes32 private constant _FORCE_REMOVAL_SLOT = keccak256("BastionHook.forceRemovalInProgress");

    /// @notice Set the BastionRouter address. One-time setter (router deployed after hook).
    function setBastionRouter(address router) external {
        if (msg.sender != _owner) revert OnlyOwner();
        if (bastionRouter != address(0)) revert RouterAlreadySet();
        bastionRouter = router;
        emit BastionRouterSet(router);
    }

    /// @notice Force-removes issuer's remaining LP from the pool and sends assets to InsurancePool.
    /// @dev Called by EscrowVault during triggerForceRemoval.
    function forceRemoveIssuerLP(PoolId poolId) external {
        if (msg.sender != address(escrowVault)) revert OnlyEscrowVault();
        if (bastionRouter == address(0)) revert RouterNotSet();

        PoolKey memory key = _poolKeys[poolId];
        uint256 liquidity = _totalLiquidity[poolId];
        if (liquidity == 0) return;

        // Set transient flag to bypass vesting checks in beforeRemoveLiquidity
        _tstore(_FORCE_REMOVAL_SLOT, 1);

        // Collect unclaimed issuer fees from salt-0 position before LP removal
        IBastionRouter(bastionRouter).forceCollectFees(key, address(this));

        // Call router to force-remove liquidity, tokens/ETH sent to this contract
        IBastionRouter(bastionRouter).forceRemoveLiquidity(key, uint128(liquidity), address(this));

        // Clear transient flag
        _tstore(_FORCE_REMOVAL_SLOT, 0);

        // Update tracked liquidity
        _totalLiquidity[poolId] = 0;

        // Forward received ETH + tokens to InsurancePool
        address token = _issuedTokens[poolId];
        uint256 ethBalance = address(this).balance;
        uint256 tokenAmount = 0;
        if (token != address(0)) {
            tokenAmount = ERC20(token).balanceOf(address(this));
            if (tokenAmount > 0) {
                IERC20Minimal(token).transfer(address(insurancePool), tokenAmount);
            }
        }

        // Determine and forward ERC-20 base token (non-ETH base, e.g. USDC)
        address baseToken;
        uint256 baseTokenAmount = 0;
        if (Currency.unwrap(key.currency0) == token) {
            baseToken = Currency.unwrap(key.currency1);
        } else {
            baseToken = Currency.unwrap(key.currency0);
        }
        if (baseToken != address(0)) {
            baseTokenAmount = ERC20(baseToken).balanceOf(address(this));
            if (baseTokenAmount > 0) {
                IERC20Minimal(baseToken).transfer(address(insurancePool), baseTokenAmount);
            }
        }

        if (ethBalance > 0 || tokenAmount > 0 || baseTokenAmount > 0) {
            insurancePool.receiveEscrowFunds{value: ethBalance}(
                poolId, token, tokenAmount, baseToken, baseTokenAmount
            );
        }

        emit ForceRemovalExecuted(poolId, ethBalance, token, tokenAmount);
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
    //  FEE RATE SYNC
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Sync cached fee rate from InsurancePool. Call after governance changes.
    function syncFeeRate() external {
        _cachedFeeRate = insurancePool.feeRate();
    }

    // ═══════════════════════════════════════════════════════════════════
    //  GOVERNANCE — Base Token Management
    // ═══════════════════════════════════════════════════════════════════

    function addBaseToken(address token, uint256 _minBaseAmount) external onlyGovernance {
        if (allowedBaseTokens[token]) revert BaseTokenAlreadySet(token);
        allowedBaseTokens[token] = true;
        minBaseAmount[token] = _minBaseAmount;
        emit BaseTokenAdded(token, _minBaseAmount);
    }

    function removeBaseToken(address token) external onlyGovernance {
        if (!allowedBaseTokens[token]) revert BaseTokenNotSet(token);
        allowedBaseTokens[token] = false;
        minBaseAmount[token] = 0;
        emit BaseTokenRemoved(token);
    }

    function updateMinBaseAmount(address token, uint256 _minBaseAmount) external onlyGovernance {
        if (!allowedBaseTokens[token]) revert BaseTokenNotSet(token);
        minBaseAmount[token] = _minBaseAmount;
        emit MinBaseAmountUpdated(token, _minBaseAmount);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  INTERNAL
    // ═══════════════════════════════════════════════════════════════════

    function _registerIssuerAndCreateEscrow(
        PoolId poolId,
        PoolKey calldata key,
        address sender,
        uint128 liquidity,
        bytes calldata hookData
    ) internal {
        // Decode hookData — no escrow amount, liquidity comes from params
        (
            address issuer,
            address token,
            uint40 lockDuration,
            uint40 vestingDuration,
            IEscrowVault.IssuerCommitment memory commitment,
            ITriggerOracle.TriggerConfig memory triggerConfig
        ) = abi.decode(
            hookData,
            (address, address, uint40, uint40, IEscrowVault.IssuerCommitment, ITriggerOracle.TriggerConfig)
        );

        // Register issuer
        _issuers[poolId] = issuer;
        _issuedTokens[poolId] = token;
        _issuerLPOwner[poolId] = sender; // Store the router that created issuer's LP
        _poolKeys[poolId] = key; // Store PoolKey for force removal

        // Initialize cached fee rate on first pool creation
        if (_cachedFeeRate == 0) {
            _cachedFeeRate = insurancePool.feeRate();
        }

        // Create escrow — no token transfers, just record liquidity
        uint256 escrowId = escrowVault.createEscrow(
            poolId, issuer, liquidity, lockDuration, vestingDuration, commitment
        );
        _escrowIds[poolId] = escrowId;

        // Register issuer and config in TriggerOracle (RISK-5: pass totalSupply snapshot)
        triggerOracle.registerIssuer(poolId, issuer, ERC20(token).totalSupply(), token);
        triggerOracle.setTriggerConfig(poolId, triggerConfig);

        // Record pool creation in reputation engine
        try reputationEngine.recordEvent(
            issuer,
            IReputationEngine.EventType.POOL_CREATED,
            abi.encode(token, uint256(liquidity), commitment, escrowId)
        ) {} catch {
            emit ExternalCallFailed("ReputationEngine.recordEvent", poolId);
        }

        emit IssuerRegistered(poolId, issuer, token);
        emit EscrowCreated(poolId, escrowId, issuer);
    }

    /// @dev Validates base token allowlist and minimum amount for initial liquidity.
    ///      Returns 1 if single base token validated OK, 2 if both tokens are base tokens.
    ///      Reverts if no base token or below minimum amount.
    function _validateBaseToken(
        PoolKey calldata key,
        ModifyLiquidityParams calldata params
    ) internal view returns (uint8) {
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);
        bool token0IsBase = allowedBaseTokens[token0];
        bool token1IsBase = allowedBaseTokens[token1];

        if (!token0IsBase && !token1IsBase) revert NoAllowedBaseToken();
        if (token0IsBase && token1IsBase) return 2;

        address baseToken = token0IsBase ? token0 : token1;
        uint256 baseAmount = _computeBaseAmount(key, params, token0IsBase);

        if (baseAmount < minBaseAmount[baseToken]) {
            revert BelowMinBaseAmount(baseAmount, minBaseAmount[baseToken]);
        }

        return 1;
    }

    /// @dev Computes expected base token deposit from liquidityDelta using pool's current sqrtPriceX96 and tick range.
    function _computeBaseAmount(
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bool baseIsToken0
    ) internal view returns (uint256) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());

        uint160 sqrtPriceAX96 = TickMath.getSqrtPriceAtTick(params.tickLower);
        uint160 sqrtPriceBX96 = TickMath.getSqrtPriceAtTick(params.tickUpper);

        uint128 liquidity = uint128(uint256(int256(params.liquidityDelta)));

        if (baseIsToken0) {
            return _getAmount0ForLiquidity(sqrtPriceX96, sqrtPriceAX96, sqrtPriceBX96, liquidity);
        } else {
            return _getAmount1ForLiquidity(sqrtPriceX96, sqrtPriceAX96, sqrtPriceBX96, liquidity);
        }
    }

    /// @dev Compute amount0 from liquidity, sqrtPrice, and tick bounds.
    ///      amount0 = L * (sqrtB - sqrtLower) / (sqrtLower * sqrtB) * Q96
    ///      Split into two mulDiv calls to avoid intermediate overflow.
    function _getAmount0ForLiquidity(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint128 liquidity
    ) internal pure returns (uint256) {
        if (sqrtPriceAX96 > sqrtPriceBX96) (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        if (sqrtPriceX96 >= sqrtPriceBX96) return 0; // all in token1
        uint160 effectiveLower = sqrtPriceX96 > sqrtPriceAX96 ? sqrtPriceX96 : sqrtPriceAX96;
        return FullMath.mulDiv(
            uint256(liquidity),
            FullMath.mulDiv(FixedPoint96.Q96, sqrtPriceBX96 - effectiveLower, sqrtPriceBX96),
            effectiveLower
        );
    }

    /// @dev Compute amount1 from liquidity, sqrtPrice, and tick bounds.
    ///      amount1 = L * (sqrtPrice - sqrtA) / Q96
    function _getAmount1ForLiquidity(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint128 liquidity
    ) internal pure returns (uint256) {
        if (sqrtPriceAX96 > sqrtPriceBX96) (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        if (sqrtPriceX96 <= sqrtPriceAX96) return 0; // all in token0
        uint160 effectiveUpper = sqrtPriceX96 < sqrtPriceBX96 ? sqrtPriceX96 : sqrtPriceBX96;
        return FullMath.mulDiv(liquidity, effectiveUpper - sqrtPriceAX96, FixedPoint96.Q96);
    }

    /// @dev Determine if a swap is a "buy" of the issued token.
    function _isBuySwap(
        PoolKey calldata key,
        SwapParams calldata params,
        address issuedToken
    ) internal pure returns (bool) {
        bool issuedIsToken0 = Currency.unwrap(key.currency0) == issuedToken;
        return issuedIsToken0 ? !params.zeroForOne : params.zeroForOne;
    }

    /// @dev Calculate and collect insurance fee from the swap input via PoolManager delta.
    ///      Takes fee from the base token (specified currency) using poolManager.take(),
    ///      then deposits to InsurancePool. Works for both ETH and ERC-20 base tokens.
    ///      Returns a BeforeSwapDelta so the caller pays for the fee.
    function _collectInsuranceFee(
        PoolId poolId,
        PoolKey calldata key,
        SwapParams calldata params,
        address issuedToken
    ) internal returns (BeforeSwapDelta) {
        uint256 cachedFee = _cachedFeeRate;
        if (cachedFee == 0) return toBeforeSwapDelta(0, 0);

        // Fee is a percentage of the input amount (exactInput: amountSpecified is negative)
        uint256 absAmount = uint256(uint128(int128(-params.amountSpecified)));
        uint256 feeAmount = (absAmount * cachedFee) / 10_000;
        if (feeAmount == 0) return toBeforeSwapDelta(0, 0);

        // Determine base currency (the input/specified currency for buy swaps)
        bool issuedIsToken0 = Currency.unwrap(key.currency0) == issuedToken;
        Currency baseCurrency = issuedIsToken0 ? key.currency1 : key.currency0;

        // Take fee from PoolManager (transfers real tokens to this contract)
        poolManager.take(baseCurrency, address(this), feeAmount);

        // Deposit to InsurancePool
        address baseToken = Currency.unwrap(baseCurrency);
        if (baseToken == address(0)) {
            // ETH base token
            insurancePool.depositFee{value: feeAmount}(poolId);
        } else {
            // ERC-20 base token (USDC, WETH, etc.)
            IERC20Minimal(baseToken).transfer(address(insurancePool), feeAmount);
            insurancePool.depositFeeToken(poolId, baseToken, feeAmount);
        }

        emit InsuranceFeeDeposited(poolId, feeAmount);

        // Return positive deltaSpecified: hook claims this from the specified currency.
        // The PoolManager will account this delta to the hook and adjust the caller's delta,
        // so the caller pays the fee on top of the swap amount.
        return toBeforeSwapDelta(int128(uint128(feeAmount)), 0);
    }

    // ─── Transient Storage Helpers (EIP-1153) ──────────────────────────

    function _tstore(bytes32 slot, uint256 value) internal {
        assembly { tstore(slot, value) }
    }

    function _tload(bytes32 slot) internal view returns (uint256 value) {
        assembly { value := tload(slot) }
    }

    function _preSwapBalanceSlot(PoolId poolId) internal pure returns (bytes32) {
        return keccak256(abi.encode(poolId, "preSwapBalance"));
    }

    function _issuedTokenSlot(PoolId poolId) internal pure returns (bytes32) {
        return keccak256(abi.encode(poolId, "issuedToken"));
    }

    function _issuerSlot(PoolId poolId) internal pure returns (bytes32) {
        return keccak256(abi.encode(poolId, "issuer"));
    }

    /// @dev Allow receiving ETH for insurance fee deposits
    receive() external payable {}
}
