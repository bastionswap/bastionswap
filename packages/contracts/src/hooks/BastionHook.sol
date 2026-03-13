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
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
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

    /// @dev poolId => base token address for this pool
    mapping(PoolId => address) internal _poolBaseTokens;

    /// @dev poolId => PoolKey stored during issuer registration for force removal
    mapping(PoolId => PoolKey) internal _poolKeys;

    /// @dev Per-pool immutable issuer commitment record
    struct PoolCommitment {
        uint40 lockDuration;
        uint40 vestingDuration;
        uint16 maxDailyLpRemovalBps;
        uint16 maxWeeklyLpRemovalBps;
        uint16 maxDailySellBps;
        uint16 maxWeeklySellBps;
        uint40 createdAt;
        bool isSet;
    }

    /// @dev poolId => immutable commitment set at pool creation
    mapping(PoolId => PoolCommitment) internal _poolCommitments;

    /// @dev poolId => initial total supply at pool creation (for insurance payout calculation)
    mapping(PoolId => uint256) internal _initialTotalSupply;

    /// @dev poolId => cumulative daily sell amount
    mapping(PoolId => uint256) internal _dailyCumulative;

    /// @dev poolId => cumulative weekly sell amount
    mapping(PoolId => uint256) internal _weeklyCumulative;

    /// @dev poolId => daily window start timestamp
    mapping(PoolId => uint40) internal _dailyWindowStart;

    /// @dev poolId => weekly window start timestamp
    mapping(PoolId => uint40) internal _weeklyWindowStart;

    /// @dev poolId => whether the pool has been triggered (local flag for fast access)
    mapping(PoolId => bool) internal _isTriggered;

    /// @dev poolId => LP ratio in bps (liquidity * 10000 / totalSupply) at pool creation
    mapping(PoolId => uint256) internal _lpRatioBps;

    /// @dev poolId => daily LP removed in current window
    mapping(PoolId => uint256) internal _dailyLpRemoved;
    /// @dev poolId => daily LP window start timestamp
    mapping(PoolId => uint40) internal _dailyLpWindowStart;
    /// @dev poolId => weekly LP removed in current window
    mapping(PoolId => uint256) internal _weeklyLpRemoved;
    /// @dev poolId => weekly LP window start timestamp
    mapping(PoolId => uint40) internal _weeklyLpWindowStart;
    /// @dev poolId => initial liquidity at pool creation (denominator for LP removal BPS)
    mapping(PoolId => uint256) internal _initialLiquidity;

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

    // ─── Governance ──────────────────────────────────────────────────

    address public GOVERNANCE;

    // ─── Governance Parameters ───────────────────────────────────────

    /// @notice Maximum base token reserve per pool, keyed by base token address (0 = unlimited)
    mapping(address => uint256) public maxPoolTVL;

    /// @notice Default lock duration when hookData doesn't specify custom (default 7 days)
    uint40 public defaultLockDuration;

    /// @notice Default vesting duration when hookData doesn't specify custom (default 83 days)
    uint40 public defaultVestingDuration;

    /// @notice Minimum lock duration issuer can set (default 7 days)
    uint40 public minLockDuration;

    /// @notice Minimum vesting duration issuer can set (default 7 days)
    uint40 public minVestingDuration;

    /// @notice Default daily LP removal limit (default 10%)
    uint16 public defaultDailyLpRemovalBps = 1000;

    /// @notice Default weekly LP removal limit (default 30%)
    uint16 public defaultWeeklyLpRemovalBps = 3000;

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
    error ExceedsMaxTVL();
    error LockDurationTooShort();
    error VestingDurationTooShort();
    error InvalidDuration();
    error CommitmentTooLenient();
    error IssuerDailySellExceeded();
    error IssuerWeeklySellExceeded();
    error PoolTriggered();
    error IssuerDumpDetected();
    error DailyLpRemovalExceeded();
    error WeeklyLpRemovalExceeded();
    error ZeroAddress();
    error ValueOutOfRange();

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
    event GovernanceTransferred(address indexed oldGov, address indexed newGov);
    event MaxPoolTVLUpdated(address indexed token, uint256 newMaxTVL);
    event DefaultLockDurationUpdated(uint256 newDuration);
    event DefaultVestingDurationUpdated(uint256 newDuration);
    event MinLockDurationUpdated(uint256 newDuration);
    event MinVestingDurationUpdated(uint256 newDuration);
    event DefaultDailyLpRemovalBpsUpdated(uint256 newBps);
    event DefaultWeeklyLpRemovalBpsUpdated(uint256 newBps);
    event PoolCommitmentSet(PoolId indexed poolId, address indexed issuer, PoolCommitment commitment);
    event PoolLiquidityRatio(PoolId indexed poolId, uint256 lpRatioBps);

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

        // Initialize governance parameters — per-token TVL caps
        maxPoolTVL[address(0)] = 2 ether;     // ETH
        maxPoolTVL[_weth] = 2 ether;          // WETH
        maxPoolTVL[_usdc] = 5000e6;           // USDC (5000 USDC)
        defaultLockDuration = 7 days;
        defaultVestingDuration = 83 days;
        minLockDuration = 7 days;
        minVestingDuration = 7 days;

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

        // Enforce per-token TVL cap for ALL LP additions
        if (liquidity > 0) {
            _enforceTVLCap(poolId, key, params, hookData);
        }

        // Track total liquidity
        if (liquidity > 0) {
            _totalLiquidity[poolId] += liquidity;
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
                // Block issuer LP removal after trigger
                if (_isTriggered[poolId]) revert PoolTriggered();

                isIssuerRemoval = true;
                // Enforce vesting
                uint256 escrowId = _escrowIds[poolId];
                uint128 liquidityToRemove = uint128(removeAmount);
                uint128 removable = escrowVault.getRemovableLiquidity(escrowId);
                if (liquidityToRemove > removable) {
                    revert ExceedsVestedAmount(liquidityToRemove, removable);
                }
                escrowVault.recordLPRemoval(escrowId, liquidityToRemove);

                // Fire COMMITMENT_HONORED when escrow is fully completed (no trigger = honored)
                if (escrowVault.isFullyVested(poolId)) {
                    PoolCommitment memory commitment = _poolCommitments[poolId];
                    ITriggerOracle.TriggerConfig memory defaultCfg = triggerOracle.getDefaultTriggerConfig();
                    try reputationEngine.recordEvent(
                        issuer,
                        IReputationEngine.EventType.COMMITMENT_HONORED,
                        abi.encode(
                            commitment.lockDuration,
                            commitment.vestingDuration,
                            commitment.maxDailySellBps,
                            commitment.maxWeeklySellBps,
                            defaultLockDuration,
                            defaultVestingDuration,
                            defaultCfg.dumpThresholdPercent,
                            defaultCfg.weeklyDumpThresholdPercent
                        )
                    ) {} catch {
                        emit ExternalCallFailed("ReputationEngine.COMMITMENT_HONORED", poolId);
                    }
                }
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

        // Track cumulative LP removal for issuer (for permissionless executeTrigger)
        if (isIssuerRemoval) {
            PoolCommitment memory commitment = _poolCommitments[poolId];
            if (commitment.isSet) {
                uint256 initLiq = _initialLiquidity[poolId];
                if (initLiq > 0) {
                    // Daily LP removal check
                    _updateLpDailyWindow(poolId);
                    uint256 projectedDaily = _dailyLpRemoved[poolId] + removeAmount;
                    uint256 dailyBps = (projectedDaily * 10_000 + initLiq - 1) / initLiq;
                    if (dailyBps > commitment.maxDailyLpRemovalBps) revert DailyLpRemovalExceeded();

                    // Weekly LP removal check
                    _updateLpWeeklyWindow(poolId);
                    uint256 projectedWeekly = _weeklyLpRemoved[poolId] + removeAmount;
                    uint256 weeklyBps = (projectedWeekly * 10_000 + initLiq - 1) / initLiq;
                    if (weeklyBps > commitment.maxWeeklyLpRemovalBps) revert WeeklyLpRemovalExceeded();

                    // Update counters
                    _dailyLpRemoved[poolId] += removeAmount;
                    _weeklyLpRemoved[poolId] += removeAmount;
                }
            }
        }

        emit LPRemovalReported(poolId, removeAmount, totalLP);

        return IHooks.beforeRemoveLiquidity.selector;
    }

    /// @notice Called before a swap. Enforces post-trigger issuer sell block and
    ///         direct sell defense (1st layer). Caches swap context for afterSwap (RISK-3).
    /// @dev    Cooperating routers (e.g. BastionSwapRouter) pass `abi.encode(actualSwapper)` as
    ///         hookData so the hook can identify the end-user. For non-cooperating routers the
    ///         `sender` parameter (= the router contract) is used as fallback.
    function beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();
        address issuedToken = _issuedTokens[poolId];
        address poolIssuer = _issuers[poolId];

        // Resolve actual swapper: cooperating routers pass abi.encode(swapper) in hookData
        address actualSwapper = (hookData.length == 32) ? abi.decode(hookData, (address)) : sender;

        // Cache issuedToken, issuer, and actual swapper in transient storage for afterSwap
        _tstore(_issuedTokenSlot(poolId), uint256(uint160(issuedToken)));
        _tstore(_issuerSlot(poolId), uint256(uint160(poolIssuer)));
        _tstore(_actualSwapperSlot(poolId), uint256(uint160(actualSwapper)));

        if (issuedToken != address(0) && poolIssuer != address(0)) {
            // Determine if this is an issuer sell (issuer selling issued token)
            bool issuedIsToken0 = Currency.unwrap(key.currency0) == issuedToken;
            bool isSell = issuedIsToken0 ? params.zeroForOne : !params.zeroForOne;

            if (isSell && actualSwapper == poolIssuer) {
                // Post-trigger block: issuer cannot sell after trigger
                if (_isTriggered[poolId]) revert PoolTriggered();

                // Direct sell defense (1st layer): check commitment limits
                PoolCommitment memory commitment = _poolCommitments[poolId];
                if (commitment.isSet) {
                    uint256 sellAmount = params.amountSpecified < 0
                        ? uint256(uint128(int128(-params.amountSpecified)))
                        : uint256(int256(params.amountSpecified));

                    _checkSellLimits(poolId, commitment, sellAmount);
                }
            }
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

    /// @notice Called after a swap. Enforces issuer sell limits (2nd layer) via BalanceDelta
    ///         and reports sales to TriggerOracle.
    /// @dev    Uses the actual swapper address cached in transient storage by beforeSwap.
    ///         In Uniswap V4, token settlement is deferred (happens after hooks), so balance-based
    ///         detection doesn't work. Instead we use the BalanceDelta from the AMM to compute
    ///         the sell amount and the hookData-resolved swapper identity.
    function afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, int128) {
        PoolId poolId = key.toId();
        address issuedToken = address(uint160(_tload(_issuedTokenSlot(poolId))));

        if (issuedToken != address(0)) {
            address poolIssuer = address(uint160(_tload(_issuerSlot(poolId))));
            address actualSwapper = address(uint160(_tload(_actualSwapperSlot(poolId))));

            if (poolIssuer != address(0) && actualSwapper == poolIssuer) {
                // Determine sell direction and compute sold amount from BalanceDelta
                bool issuedIsToken0 = Currency.unwrap(key.currency0) == issuedToken;
                bool isSell = issuedIsToken0 ? params.zeroForOne : !params.zeroForOne;

                if (isSell) {
                    // User sent issued tokens: negative delta = user owes tokens to pool
                    int128 issuedDelta = issuedIsToken0 ? delta.amount0() : delta.amount1();
                    if (issuedDelta < 0) {
                        uint256 soldAmount = uint256(uint128(-issuedDelta));
                        uint256 currentReserve = ERC20(issuedToken).balanceOf(address(poolManager));
                        if (currentReserve > 0) {
                            // Enforce sell limits (2nd layer — catches all paths, revert only)
                            PoolCommitment memory commitment = _poolCommitments[poolId];
                            if (commitment.isSet) {
                                _enforceAfterSwapSellLimits(poolId, commitment, soldAmount);
                            }
                            emit IssuerSaleReported(poolId, poolIssuer, soldAmount);
                        }
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

        // Set local triggered flag to block future issuer sells
        _isTriggered[poolId] = true;

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
                SafeTransferLib.safeTransfer(ERC20(token), address(insurancePool), tokenAmount);
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
                SafeTransferLib.safeTransfer(ERC20(baseToken), address(insurancePool), baseTokenAmount);
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

    /// @notice Returns the issuer address for a pool.
    function getPoolIssuer(PoolId poolId) external view returns (address) {
        return _issuers[poolId];
    }

    /// @notice Check if an address is the issuer for a pool.
    function isIssuer(PoolId poolId, address account) external view returns (bool) {
        return _issuers[poolId] == account;
    }

    /// @notice Returns the immutable PoolCommitment for a pool.
    function getPoolCommitment(PoolId poolId) external view returns (PoolCommitment memory) {
        return _poolCommitments[poolId];
    }

    /// @notice Returns true if ANY commitment dimension is stricter than governance defaults.
    function isCommitmentStricterThanDefault(PoolId poolId) external view returns (bool) {
        PoolCommitment memory c = _poolCommitments[poolId];
        if (!c.isSet) return false;

        // Duration: stricter if total is longer than default
        uint80 commitmentTotal = uint80(c.lockDuration) + uint80(c.vestingDuration);
        uint80 defaultTotal = uint80(defaultLockDuration) + uint80(defaultVestingDuration);
        if (commitmentTotal > defaultTotal) return true;

        // Thresholds: stricter if lower than defaults from TriggerOracle
        ITriggerOracle.TriggerConfig memory def = triggerOracle.getDefaultTriggerConfig();

        if (c.maxDailyLpRemovalBps < defaultDailyLpRemovalBps) return true;
        if (c.maxWeeklyLpRemovalBps < defaultWeeklyLpRemovalBps) return true;
        if (c.maxDailySellBps < def.dumpThresholdPercent) return true;
        if (c.maxWeeklySellBps < def.weeklyDumpThresholdPercent) return true;

        return false;
    }

    /// @notice Get pool info.
    function getPoolInfo(PoolId poolId)
        external
        view
        returns (address issuer, uint256 escrowId, address issuedToken, uint256 totalLiquidity, address baseToken)
    {
        issuer = _issuers[poolId];
        escrowId = _escrowIds[poolId];
        issuedToken = _issuedTokens[poolId];
        totalLiquidity = _totalLiquidity[poolId];
        baseToken = _poolBaseTokens[poolId];
    }

    // ═══════════════════════════════════════════════════════════════════
    //  PERMISSIONLESS TRIGGER EXECUTION
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Permissionless: anyone can execute trigger if cumulative LP removal threshold is met.
    function executeTrigger(PoolId poolId) external {
        PoolCommitment memory commitment = _poolCommitments[poolId];
        require(commitment.isSet, "Pool not registered");
        require(!_isTriggered[poolId], "Already triggered");

        // Check weekly LP removal threshold
        _updateLpWeeklyWindow(poolId);

        uint256 initLiq = _initialLiquidity[poolId];
        require(initLiq > 0, "No initial liquidity");

        uint256 weeklyBps = (_weeklyLpRemoved[poolId] * 10_000) / initLiq;
        require(weeklyBps >= commitment.maxWeeklyLpRemovalBps, "Threshold not met");

        _isTriggered[poolId] = true;

        // Delegate to TriggerOracle for execution (escrow, insurance, reputation)
        PoolKey memory key = _poolKeys[poolId];
        uint256 totalEligibleSupply = _initialTotalSupply[poolId];
        triggerOracle.executeTrigger(poolId, key, ITriggerOracle.TriggerType.RUG_PULL, totalEligibleSupply);
    }

    /// @notice View: check if cumulative LP removal threshold is currently met.
    function isLPRemovalTriggerable(PoolId poolId) external view returns (bool) {
        PoolCommitment memory c = _poolCommitments[poolId];
        if (!c.isSet) return false;

        uint256 weeklyRemoved = _weeklyLpRemoved[poolId];
        uint40 windowStart = _weeklyLpWindowStart[poolId];

        // Check if window expired (reset would happen)
        if (block.timestamp >= windowStart + 7 days) {
            return false; // window would reset
        }

        uint256 initLiq = _initialLiquidity[poolId];
        if (initLiq == 0) return false;

        uint256 weeklyBps = (weeklyRemoved * 10_000) / initLiq;
        return weeklyBps >= c.maxWeeklyLpRemovalBps;
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
    //  GOVERNANCE — Parameter Setters
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Transfer governance to a new address.
    function transferGovernance(address newGovernance) external onlyGovernance {
        if (newGovernance == address(0)) revert ZeroAddress();
        address oldGov = GOVERNANCE;
        GOVERNANCE = newGovernance;
        emit GovernanceTransferred(oldGov, newGovernance);
    }

    /// @notice Set the maximum pool TVL for a specific base token (0 = unlimited).
    function setMaxPoolTVL(address token, uint256 cap) external onlyGovernance {
        maxPoolTVL[token] = cap;
        emit MaxPoolTVLUpdated(token, cap);
    }

    /// @notice Set the default lock duration (1–90 days).
    function setDefaultLockDuration(uint40 newDuration) external onlyGovernance {
        if (newDuration < 1 days || newDuration > 90 days) revert InvalidDuration();
        defaultLockDuration = newDuration;
        emit DefaultLockDurationUpdated(newDuration);
    }

    /// @notice Set the default vesting duration (7–365 days).
    function setDefaultVestingDuration(uint40 newDuration) external onlyGovernance {
        if (newDuration < 7 days || newDuration > 365 days) revert InvalidDuration();
        defaultVestingDuration = newDuration;
        emit DefaultVestingDurationUpdated(newDuration);
    }

    /// @notice Set the minimum lock duration (1–30 days).
    function setMinLockDuration(uint40 newDuration) external onlyGovernance {
        if (newDuration < 1 days || newDuration > 30 days) revert InvalidDuration();
        minLockDuration = newDuration;
        emit MinLockDurationUpdated(newDuration);
    }

    /// @notice Set the minimum vesting duration (1–30 days).
    function setMinVestingDuration(uint40 newDuration) external onlyGovernance {
        if (newDuration < 1 days || newDuration > 30 days) revert InvalidDuration();
        minVestingDuration = newDuration;
        emit MinVestingDurationUpdated(newDuration);
    }

    function setDefaultDailyLpRemovalBps(uint16 bps) external {
        if (msg.sender != GOVERNANCE) revert OnlyGovernance();
        if (bps < 100 || bps > 5000) revert ValueOutOfRange();
        defaultDailyLpRemovalBps = bps;
        emit DefaultDailyLpRemovalBpsUpdated(bps);
    }

    function setDefaultWeeklyLpRemovalBps(uint16 bps) external {
        if (msg.sender != GOVERNANCE) revert OnlyGovernance();
        if (bps < 500 || bps > 8000) revert ValueOutOfRange();
        defaultWeeklyLpRemovalBps = bps;
        emit DefaultWeeklyLpRemovalBpsUpdated(bps);
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

        // Enforce minimum durations from governance params
        if (lockDuration < minLockDuration) revert LockDurationTooShort();
        if (vestingDuration < minVestingDuration) revert VestingDurationTooShort();

        // Validate and store immutable PoolCommitment
        _validateAndStoreCommitment(poolId, issuer, lockDuration, vestingDuration, triggerConfig);

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

        // Initialize sell tracking & register with TriggerOracle (extracted to reduce stack depth)
        _initSellTrackingAndOracle(poolId, key, token, liquidity, issuer, triggerConfig);

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

    /// @dev Initializes sell tracking state and registers with TriggerOracle.
    ///      Extracted to reduce stack depth in _registerIssuerAndCreateEscrow.
    function _initSellTrackingAndOracle(
        PoolId poolId,
        PoolKey calldata key,
        address token,
        uint128 liquidity,
        address issuer,
        ITriggerOracle.TriggerConfig memory triggerConfig
    ) internal {
        // Store base token for this pool
        address t0 = Currency.unwrap(key.currency0);
        address t1 = Currency.unwrap(key.currency1);
        _poolBaseTokens[poolId] = (t0 == token) ? t1 : t0;

        uint256 totalSupply = ERC20(token).totalSupply();
        _initialTotalSupply[poolId] = totalSupply;
        _initialLiquidity[poolId] = uint256(liquidity);

        // Record LP/supply ratio for transparency
        uint256 lpRatio = (liquidity > 0 && totalSupply > 0)
            ? (uint256(liquidity) * 10_000 / totalSupply)
            : 0;
        _lpRatioBps[poolId] = lpRatio;
        emit PoolLiquidityRatio(poolId, lpRatio);

        // Initialize tracking window starts
        _dailyWindowStart[poolId] = uint40(block.timestamp);
        _weeklyWindowStart[poolId] = uint40(block.timestamp);
        _dailyLpWindowStart[poolId] = uint40(block.timestamp);
        _weeklyLpWindowStart[poolId] = uint40(block.timestamp);

        // Register issuer and config in TriggerOracle
        triggerOracle.registerIssuer(poolId, issuer, totalSupply, token);
        triggerOracle.setTriggerConfig(poolId, triggerConfig);
    }

    /// @dev Enforces per-token TVL cap based on base token reserve.
    function _enforceTVLCap(
        PoolId poolId,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) internal view {
        address baseToken = _poolBaseTokens[poolId];
        if (baseToken == address(0) && hookData.length > 0) {
            // First LP — derive base from allowlist
            address t0 = Currency.unwrap(key.currency0);
            address t1 = Currency.unwrap(key.currency1);
            baseToken = allowedBaseTokens[t0] ? t0 : t1;
        }
        uint256 cap = maxPoolTVL[baseToken];
        if (cap > 0) {
            (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
            int24 tl = (TickMath.MIN_TICK / key.tickSpacing) * key.tickSpacing;
            int24 tu = (TickMath.MAX_TICK / key.tickSpacing) * key.tickSpacing;
            bool baseIsToken0 = (Currency.unwrap(key.currency0) == baseToken);

            uint128 currentLiq = uint128(_totalLiquidity[poolId]);
            uint256 currentReserve = baseIsToken0
                ? _getAmount0ForLiquidity(sqrtPriceX96, TickMath.getSqrtPriceAtTick(tl), TickMath.getSqrtPriceAtTick(tu), currentLiq)
                : _getAmount1ForLiquidity(sqrtPriceX96, TickMath.getSqrtPriceAtTick(tl), TickMath.getSqrtPriceAtTick(tu), currentLiq);

            uint256 addingAmount = _computeBaseAmount(key, params, baseIsToken0);

            if (currentReserve + addingAmount > cap) revert ExceedsMaxTVL();
        }
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
            SafeTransferLib.safeTransfer(ERC20(baseToken), address(insurancePool), feeAmount);
            insurancePool.depositFeeToken(poolId, baseToken, feeAmount);
        }

        emit InsuranceFeeDeposited(poolId, feeAmount);

        // Return positive deltaSpecified: hook claims this from the specified currency.
        // The PoolManager will account this delta to the hook and adjust the caller's delta,
        // so the caller pays the fee on top of the swap amount.
        return toBeforeSwapDelta(int128(uint128(feeAmount)), 0);
    }

    /// @dev Validates issuer trigger thresholds are ≤ governance defaults and stores PoolCommitment.
    function _validateAndStoreCommitment(
        PoolId poolId,
        address issuer,
        uint40 lockDuration,
        uint40 vestingDuration,
        ITriggerOracle.TriggerConfig memory triggerConfig
    ) internal {
        // Read governance defaults
        ITriggerOracle.TriggerConfig memory def = triggerOracle.getDefaultTriggerConfig();

        // Validate: LP removal thresholds must be ≤ defaults (lower = stricter)
        if (triggerConfig.dailyLpRemovalBps > def.dailyLpRemovalBps) revert CommitmentTooLenient();
        if (triggerConfig.weeklyLpRemovalBps > def.weeklyLpRemovalBps) revert CommitmentTooLenient();
        // Validate: weekly LP must be >= daily LP
        if (triggerConfig.weeklyLpRemovalBps < triggerConfig.dailyLpRemovalBps) revert ValueOutOfRange();
        // Validate: sell thresholds must be ≤ defaults
        if (triggerConfig.dumpThresholdPercent > def.dumpThresholdPercent) revert CommitmentTooLenient();
        if (triggerConfig.weeklyDumpThresholdPercent > def.weeklyDumpThresholdPercent) revert CommitmentTooLenient();

        PoolCommitment memory c = PoolCommitment({
            lockDuration: lockDuration,
            vestingDuration: vestingDuration,
            maxDailyLpRemovalBps: triggerConfig.dailyLpRemovalBps,
            maxWeeklyLpRemovalBps: triggerConfig.weeklyLpRemovalBps,
            maxDailySellBps: triggerConfig.dumpThresholdPercent,
            maxWeeklySellBps: triggerConfig.weeklyDumpThresholdPercent,
            createdAt: uint40(block.timestamp),
            isSet: true
        });

        _poolCommitments[poolId] = c;
        emit PoolCommitmentSet(poolId, issuer, c);
    }

    // ─── LP Removal Window Helpers ──────────────────────────────────

    /// @dev Resets daily LP removal counter if 24h window has expired.
    function _updateLpDailyWindow(PoolId poolId) internal {
        if (block.timestamp >= _dailyLpWindowStart[poolId] + 1 days) {
            _dailyLpRemoved[poolId] = 0;
            _dailyLpWindowStart[poolId] = uint40(block.timestamp);
        }
    }

    /// @dev Resets weekly LP removal counter if 7-day window has expired.
    function _updateLpWeeklyWindow(PoolId poolId) internal {
        if (block.timestamp >= _weeklyLpWindowStart[poolId] + 7 days) {
            _weeklyLpRemoved[poolId] = 0;
            _weeklyLpWindowStart[poolId] = uint40(block.timestamp);
        }
    }

    // ─── Issuer Sell Defense Helpers ──────────────────────────────────

    /// @dev Check sell limits before swap (1st layer, direct issuer sells only).
    ///      Reverts if projected sell would exceed daily or weekly commitment thresholds.
    function _checkSellLimits(
        PoolId poolId,
        PoolCommitment memory commitment,
        uint256 sellAmount
    ) internal view {
        address issuedToken = _issuedTokens[poolId];
        uint256 currentReserve = ERC20(issuedToken).balanceOf(address(poolManager));
        if (currentReserve == 0) return;

        // Check daily limit
        if (commitment.maxDailySellBps > 0) {
            uint256 dailyCum = _dailyCumulative[poolId];
            uint40 windowStart = _dailyWindowStart[poolId];
            // Reset window if expired (view-only projection)
            if (block.timestamp >= windowStart + 86400) {
                dailyCum = 0;
            }
            uint256 projected = dailyCum + sellAmount;
            uint256 sellBps = (projected * 10_000 + currentReserve - 1) / currentReserve;
            if (sellBps > commitment.maxDailySellBps) revert IssuerDailySellExceeded();
        }

        // Check weekly limit
        if (commitment.maxWeeklySellBps > 0) {
            uint256 weeklyCum = _weeklyCumulative[poolId];
            uint40 windowStart = _weeklyWindowStart[poolId];
            if (block.timestamp >= windowStart + 7 days) {
                weeklyCum = 0;
            }
            uint256 projected = weeklyCum + sellAmount;
            uint256 sellBps = (projected * 10_000 + currentReserve - 1) / currentReserve;
            if (sellBps > commitment.maxWeeklySellBps) revert IssuerWeeklySellExceeded();
        }
    }

    /// @dev Enforce sell limits after swap (2nd layer, catches all paths).
    ///      Updates cumulative counters and reverts if limits exceeded.
    function _enforceAfterSwapSellLimits(
        PoolId poolId,
        PoolCommitment memory commitment,
        uint256 soldAmount
    ) internal {
        address issuedToken = _issuedTokens[poolId];
        uint256 currentReserve = ERC20(issuedToken).balanceOf(address(poolManager));
        if (currentReserve == 0) return;

        // Reset daily window if expired
        uint40 dailyStart = _dailyWindowStart[poolId];
        if (block.timestamp >= dailyStart + 86400) {
            _dailyCumulative[poolId] = 0;
            _dailyWindowStart[poolId] = uint40(block.timestamp);
        }

        // Reset weekly window if expired
        uint40 weeklyStart = _weeklyWindowStart[poolId];
        if (block.timestamp >= weeklyStart + 7 days) {
            _weeklyCumulative[poolId] = 0;
            _weeklyWindowStart[poolId] = uint40(block.timestamp);
        }

        // Update cumulative counters
        _dailyCumulative[poolId] += soldAmount;
        _weeklyCumulative[poolId] += soldAmount;

        // Check daily limit
        if (commitment.maxDailySellBps > 0) {
            uint256 dailyBps = (_dailyCumulative[poolId] * 10_000 + currentReserve - 1) / currentReserve;
            if (dailyBps > commitment.maxDailySellBps) revert IssuerDumpDetected();
        }

        // Check weekly limit
        if (commitment.maxWeeklySellBps > 0) {
            uint256 weeklyBps = (_weeklyCumulative[poolId] * 10_000 + currentReserve - 1) / currentReserve;
            if (weeklyBps > commitment.maxWeeklySellBps) revert IssuerDumpDetected();
        }
    }

    // ─── View: Issuer Sell Defense ──────────────────────────────────

    /// @notice Get the initial total supply recorded at pool creation.
    function getInitialTotalSupply(PoolId poolId) external view returns (uint256) {
        return _initialTotalSupply[poolId];
    }

    /// @notice Get the LP/supply ratio in bps recorded at pool creation.
    function getLpRatioBps(PoolId poolId) external view returns (uint256) {
        return _lpRatioBps[poolId];
    }

    /// @notice Check if a pool has been triggered (local flag).
    function isPoolTriggered(PoolId poolId) external view returns (bool) {
        return _isTriggered[poolId];
    }

    // ─── Transient Storage Helpers (EIP-1153) ──────────────────────────

    function _tstore(bytes32 slot, uint256 value) internal {
        assembly { tstore(slot, value) }
    }

    function _tload(bytes32 slot) internal view returns (uint256 value) {
        assembly { value := tload(slot) }
    }

    function _issuedTokenSlot(PoolId poolId) internal pure returns (bytes32) {
        return keccak256(abi.encode(poolId, "issuedToken"));
    }

    function _issuerSlot(PoolId poolId) internal pure returns (bytes32) {
        return keccak256(abi.encode(poolId, "issuer"));
    }

    function _actualSwapperSlot(PoolId poolId) internal pure returns (bytes32) {
        return keccak256(abi.encode(poolId, "actualSwapper"));
    }

    /// @dev Allow receiving ETH for insurance fee deposits
    receive() external payable {}
}
