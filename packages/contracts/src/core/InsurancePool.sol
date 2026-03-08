// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.26;

import {IInsurancePool} from "../interfaces/IInsurancePool.sol";
import {IEscrowVault} from "../interfaces/IEscrowVault.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";

/// @title InsurancePool
/// @notice Per-token isolated insurance pool funded by a portion of buy-side swap fees.
///         On trigger events, affected token holders claim pro-rata compensation.
contract InsurancePool is IInsurancePool, ReentrancyGuard {
    // ─── Constants ────────────────────────────────────────────────────

    uint16 internal constant MAX_FEE_RATE = 200; // 2%
    uint40 internal constant CLAIM_PERIOD = 30 days;
    uint40 internal constant FALLBACK_CLAIM_PERIOD = 7 days;
    uint40 internal constant EMERGENCY_DELAY = 2 days;


    // ─── Immutables ───────────────────────────────────────────────────

    address public immutable BASTION_HOOK;
    address public immutable TRIGGER_ORACLE;
    address public immutable GOVERNANCE;
    IEscrowVault public immutable ESCROW_VAULT;

    // ─── Storage ──────────────────────────────────────────────────────

    struct PoolData {
        uint256 balance;
        bool isTriggered;
        uint40 triggerTimestamp;
        uint8 triggerType;
        uint256 totalEligibleSupply;
        uint256 payoutBalance; // balance snapshot at trigger time for claims
        bytes32 merkleRoot; // Merkle root of (holder, balance) snapshot at trigger time
        uint256 totalClaimed; // cumulative claimed amount (safety check)
        bool useMerkleProof; // true = Merkle path, false = balanceOf fallback
        address issuedToken; // issued token address for fallback balanceOf claims
        uint256 escrowEthBalance; // ETH from force-removed issuer LP
        uint256 escrowTokenBalance; // tokens from force-removed issuer LP
        address escrowToken; // token address for escrow funds
        uint256 tokenPayoutBalance; // snapshot of escrow token balance at payout time
        uint256 baseTokenFeeBalance; // accumulated ERC-20 base token fees (e.g. USDC)
        address baseTokenFeeToken; // base token address for ERC-20 fee pools
        uint256 baseTokenFeePayoutBalance; // snapshot at payout time
        uint256 escrowBaseTokenBalance; // ERC-20 base tokens from force-removed LP
        address escrowBaseToken; // base token address from escrow
        mapping(address => bool) claimed;
    }

    /// @dev PoolId hash => PoolData
    mapping(bytes32 => PoolData) internal _pools;

    /// @notice Current fee rate in basis points (default 100 = 1%)
    uint16 public feeRate;

    /// @notice Protocol treasury address for fund collection
    address public treasury;

    /// @dev Emergency withdrawal requests subject to timelock
    mapping(bytes32 => IInsurancePool.EmergencyRequest) public emergencyRequests;

    // ─── Errors ───────────────────────────────────────────────────────

    error OnlyHook();
    error OnlyTriggerOracle();
    error OnlyGovernance();
    error ZeroAmount();
    error ZeroAddress();
    error AlreadyTriggered();
    error NotTriggered();
    error AlreadyClaimed();
    error ClaimPeriodExpired();
    error ZeroEligibleSupply();
    error FeeRateTooHigh();
    error InsufficientPoolBalance();
    error TransferFailed();
    error InvalidMerkleProof();
    error MerkleRootNotSet();
    error ExceedsPoolBalance();
    error EmergencyDelayNotElapsed();
    error EmergencyRequestNotFound();
    error EmergencyRequestAlreadyExecuted();
    error InsufficientTokenBalance();
    error EscrowNotFullyVested();

    error TreasuryNotSet();

    // ─── Modifiers ────────────────────────────────────────────────────

    modifier onlyHook() {
        if (msg.sender != BASTION_HOOK) revert OnlyHook();
        _;
    }

    modifier onlyTriggerOracle() {
        if (msg.sender != TRIGGER_ORACLE) revert OnlyTriggerOracle();
        _;
    }

    modifier onlyGovernance() {
        if (msg.sender != GOVERNANCE) revert OnlyGovernance();
        _;
    }

    // ─── Constructor ──────────────────────────────────────────────────

    constructor(address bastionHook, address triggerOracle, address governance, address escrowVault, address treasury_) {
        BASTION_HOOK = bastionHook;
        TRIGGER_ORACLE = triggerOracle;
        GOVERNANCE = governance;
        ESCROW_VAULT = IEscrowVault(escrowVault);
        treasury = treasury_;
        feeRate = 100; // 1% default
    }

    // ─── External Functions ───────────────────────────────────────────

    /// @inheritdoc IInsurancePool
    function depositFee(PoolId poolId) external payable onlyHook {
        if (msg.value == 0) revert ZeroAmount();

        PoolData storage pool = _getPool(poolId);
        pool.balance += msg.value;

        emit FeeDeposited(poolId, msg.value);
    }

    /// @inheritdoc IInsurancePool
    function depositFeeToken(PoolId poolId, address token, uint256 amount) external onlyHook {
        if (amount == 0) revert ZeroAmount();
        if (token == address(0)) revert ZeroAddress();

        PoolData storage pool = _getPool(poolId);
        pool.baseTokenFeeBalance += amount;
        pool.baseTokenFeeToken = token;

        emit TokenFeeDeposited(poolId, token, amount);
    }

    /// @inheritdoc IInsurancePool
    function receiveEscrowFunds(
        PoolId poolId,
        address issuedToken, uint256 issuedTokenAmount,
        address baseToken, uint256 baseTokenAmount
    ) external payable onlyHook {
        PoolData storage pool = _getPool(poolId);
        pool.escrowEthBalance += msg.value;
        pool.escrowTokenBalance += issuedTokenAmount;
        pool.escrowToken = issuedToken;
        if (baseTokenAmount > 0 && baseToken != address(0)) {
            pool.escrowBaseTokenBalance += baseTokenAmount;
            pool.escrowBaseToken = baseToken;
        }

        emit EscrowFundsReceived(poolId, msg.value, issuedToken, issuedTokenAmount);
    }

    /// @inheritdoc IInsurancePool
    function executePayout(
        PoolId poolId,
        uint8 triggerType,
        uint256 totalEligibleSupply,
        bytes32 merkleRoot,
        address issuedToken
    ) external onlyTriggerOracle nonReentrant returns (uint256 totalPayout) {
        PoolData storage pool = _getPool(poolId);
        if (pool.isTriggered) revert AlreadyTriggered();
        if (totalEligibleSupply == 0) revert ZeroEligibleSupply();

        // Include escrow ETH in total payout — merge into balance so
        // claimCompensation's `pool.balance -= amount` doesn't underflow.
        pool.balance += pool.escrowEthBalance;
        pool.escrowEthBalance = 0;
        totalPayout = pool.balance;

        pool.isTriggered = true;
        pool.triggerTimestamp = uint40(block.timestamp);
        pool.triggerType = triggerType;
        pool.totalEligibleSupply = totalEligibleSupply;
        pool.payoutBalance = totalPayout;
        pool.tokenPayoutBalance = pool.escrowTokenBalance; // snapshot issued token balance
        pool.baseTokenFeePayoutBalance = pool.baseTokenFeeBalance + pool.escrowBaseTokenBalance; // snapshot base token fees + escrow
        pool.merkleRoot = merkleRoot;
        pool.useMerkleProof = (merkleRoot != bytes32(0));
        pool.issuedToken = issuedToken;

        emit PayoutExecuted(poolId, triggerType, totalPayout);
    }

    /// @inheritdoc IInsurancePool
    function claimCompensation(PoolId poolId, uint256 holderBalance, bytes32[] calldata merkleProof)
        external
        nonReentrant
        returns (uint256 amount)
    {
        PoolData storage pool = _getPool(poolId);
        if (!pool.isTriggered) revert NotTriggered();
        if (pool.claimed[msg.sender]) revert AlreadyClaimed();
        if (holderBalance == 0) revert ZeroAmount();

        if (pool.useMerkleProof) {
            // Merkle mode: 30-day claim period, verify proof
            if (block.timestamp > pool.triggerTimestamp + CLAIM_PERIOD) revert ClaimPeriodExpired();
            if (pool.merkleRoot == bytes32(0)) revert MerkleRootNotSet();

            bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(msg.sender, holderBalance))));
            if (!MerkleProof.verify(merkleProof, pool.merkleRoot, leaf)) revert InvalidMerkleProof();
        } else {
            // Fallback mode: 7-day claim period, verify balanceOf
            if (block.timestamp > pool.triggerTimestamp + FALLBACK_CLAIM_PERIOD) revert ClaimPeriodExpired();
            if (ERC20(pool.issuedToken).balanceOf(msg.sender) < holderBalance) {
                revert InsufficientTokenBalance();
            }
        }

        amount = _calculateCompensation(pool, holderBalance);
        uint256 tokenShare = _calculateTokenCompensation(pool, holderBalance);
        uint256 baseTokenShare = _calculateBaseTokenCompensation(pool, holderBalance);
        if (amount == 0 && tokenShare == 0 && baseTokenShare == 0) revert ZeroAmount();

        // Safety check: totalClaimed must not exceed pool balance
        if (pool.totalClaimed + amount > pool.payoutBalance) revert ExceedsPoolBalance();

        // CEI: mark claimed before transfer
        pool.claimed[msg.sender] = true;
        pool.totalClaimed += amount;
        pool.balance -= amount;

        // Transfer ETH
        if (amount > 0) {
            (bool success,) = msg.sender.call{value: amount}("");
            if (!success) revert TransferFailed();
        }

        // Transfer issued tokens from escrow funds
        if (tokenShare > 0 && pool.escrowToken != address(0)) {
            IERC20Minimal(pool.escrowToken).transfer(msg.sender, tokenShare);
        }

        // Transfer ERC-20 base token fees + escrow base tokens
        if (baseTokenShare > 0) {
            address baseToken = pool.baseTokenFeeToken != address(0) ? pool.baseTokenFeeToken : pool.escrowBaseToken;
            if (baseToken != address(0)) {
                IERC20Minimal(baseToken).transfer(msg.sender, baseTokenShare);
            }
        }

        emit CompensationClaimed(poolId, msg.sender, amount);
    }

    /// @inheritdoc IInsurancePool
    function calculateCompensation(PoolId poolId, uint256 holderBalance) external view returns (uint256 amount) {
        PoolData storage pool = _getPool(poolId);
        if (!pool.isTriggered) return 0;
        amount = _calculateCompensation(pool, holderBalance);
    }

    /// @inheritdoc IInsurancePool
    function getPoolStatus(PoolId poolId) external view returns (PoolStatus memory status) {
        PoolData storage pool = _getPool(poolId);
        status.balance = pool.balance;
        status.isTriggered = pool.isTriggered;
        status.triggerTimestamp = pool.triggerTimestamp;
        status.totalEligibleSupply = pool.totalEligibleSupply;
    }

    /// @inheritdoc IInsurancePool
    function setFeeRate(uint16 newFeeRate) external onlyGovernance {
        if (newFeeRate > MAX_FEE_RATE) revert FeeRateTooHigh();

        uint16 oldRate = feeRate;
        feeRate = newFeeRate;

        emit FeeRateUpdated(oldRate, newFeeRate);
    }

    /// @inheritdoc IInsurancePool
    function requestEmergencyWithdraw(PoolId poolId, address to, uint256 amount)
        external
        onlyGovernance
        returns (bytes32 requestId)
    {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        requestId = keccak256(abi.encode(poolId, to, amount, block.timestamp));
        emergencyRequests[requestId] = IInsurancePool.EmergencyRequest({
            poolId: poolId,
            to: to,
            amount: amount,
            requestedAt: uint40(block.timestamp)
        });

        emit IInsurancePool.EmergencyWithdrawRequested(requestId, poolId, to, amount);
    }

    /// @inheritdoc IInsurancePool
    function executeEmergencyWithdraw(bytes32 requestId) external onlyGovernance nonReentrant {
        IInsurancePool.EmergencyRequest memory req = emergencyRequests[requestId];
        if (req.requestedAt == 0) revert EmergencyRequestNotFound();
        if (block.timestamp < req.requestedAt + EMERGENCY_DELAY) revert EmergencyDelayNotElapsed();

        // Delete before execution to prevent re-entrancy / double-execute
        delete emergencyRequests[requestId];

        PoolData storage pool = _getPool(req.poolId);
        if (pool.balance < req.amount) revert InsufficientPoolBalance();

        pool.balance -= req.amount;

        (bool success,) = req.to.call{value: req.amount}("");
        if (!success) revert TransferFailed();

        emit EmergencyWithdrawal(req.poolId, req.to, req.amount);
    }

    /// @inheritdoc IInsurancePool
    function cancelEmergencyWithdraw(bytes32 requestId) external onlyGovernance {
        if (emergencyRequests[requestId].requestedAt == 0) revert EmergencyRequestNotFound();
        delete emergencyRequests[requestId];

        emit IInsurancePool.EmergencyWithdrawCancelled(requestId);
    }

    /// @notice Check if a holder has already claimed for a pool
    function hasClaimed(PoolId poolId, address holder) external view returns (bool) {
        return _getPool(poolId).claimed[holder];
    }

    /// @inheritdoc IInsurancePool
    function setTreasury(address treasury_) external onlyGovernance {
        if (treasury_ == address(0)) revert ZeroAddress();
        address old = treasury;
        treasury = treasury_;
        emit IInsurancePool.TreasurySet(old, treasury_);
    }

    /// @inheritdoc IInsurancePool
    function claimTreasuryFunds(PoolId poolId) external onlyGovernance nonReentrant {
        if (treasury == address(0)) revert TreasuryNotSet();

        PoolData storage pool = _getPool(poolId);
        if (pool.isTriggered) revert AlreadyTriggered();
        if (pool.balance == 0 && pool.baseTokenFeeBalance == 0) revert ZeroAmount();

        // Escrow must be fully vested
        if (!ESCROW_VAULT.isFullyVested(poolId)) revert EscrowNotFullyVested();

        uint256 ethAmount = pool.balance;
        pool.balance = 0;

        if (ethAmount > 0) {
            (bool success,) = treasury.call{value: ethAmount}("");
            if (!success) revert TransferFailed();
        }

        // Transfer ERC-20 base token fees to treasury
        uint256 baseTokenAmount = pool.baseTokenFeeBalance;
        if (baseTokenAmount > 0 && pool.baseTokenFeeToken != address(0)) {
            pool.baseTokenFeeBalance = 0;
            IERC20Minimal(pool.baseTokenFeeToken).transfer(treasury, baseTokenAmount);
        }

        emit IInsurancePool.TreasuryFundsClaimed(poolId, treasury, ethAmount + baseTokenAmount);
    }

    // ─── Internal Functions ───────────────────────────────────────────

    function _getPool(PoolId poolId) internal view returns (PoolData storage) {
        return _pools[PoolId.unwrap(poolId)];
    }

    function _calculateCompensation(PoolData storage pool, uint256 holderBalance)
        internal
        view
        returns (uint256)
    {
        // pro-rata: (payoutBalance * holderBalance) / totalEligibleSupply
        // Round down to prevent over-distribution
        return (pool.payoutBalance * holderBalance) / pool.totalEligibleSupply;
    }

    function _calculateTokenCompensation(PoolData storage pool, uint256 holderBalance)
        internal
        view
        returns (uint256)
    {
        if (pool.tokenPayoutBalance == 0) return 0;
        return (pool.tokenPayoutBalance * holderBalance) / pool.totalEligibleSupply;
    }

    function _calculateBaseTokenCompensation(PoolData storage pool, uint256 holderBalance)
        internal
        view
        returns (uint256)
    {
        if (pool.baseTokenFeePayoutBalance == 0) return 0;
        return (pool.baseTokenFeePayoutBalance * holderBalance) / pool.totalEligibleSupply;
    }
}
