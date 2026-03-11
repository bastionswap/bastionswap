// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.26;

import {IInsurancePool} from "../interfaces/IInsurancePool.sol";
import {IEscrowVault} from "../interfaces/IEscrowVault.sol";
import {IBastionHook} from "../interfaces/IBastionHook.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @title InsurancePool
/// @notice Per-token isolated insurance pool funded by a portion of buy-side swap fees.
///         On trigger events, affected token holders claim pro-rata compensation.
///
///         Claim Mode State Machine:
///         State A — Triggered, 24h not elapsed: no claims, guardian can submit merkle root
///         State B — Merkle root submitted: only claimCompensation (Merkle proof)
///         State C — 24h elapsed + no merkle root: only claimCompensationFallback (balanceOf)
contract InsurancePool is IInsurancePool, ReentrancyGuard {
    // ─── Constants ────────────────────────────────────────────────────

    uint16 internal constant MAX_FEE_RATE = 500; // 5%
    uint16 internal constant MIN_FEE_RATE = 10; // 0.1%
    uint256 public constant BPS_DENOMINATOR = 10000;
    /// @notice Time window for guardian to submit Merkle root after trigger (default 24h)
    uint40 public merkleSubmissionDeadline;

    // ─── Immutables ───────────────────────────────────────────────────

    address public immutable BASTION_HOOK;
    address public immutable TRIGGER_ORACLE;
    IEscrowVault public immutable ESCROW_VAULT;

    // ─── Governance ──────────────────────────────────────────────────

    address public GOVERNANCE;

    // ─── Guardian ────────────────────────────────────────────────────

    /// @notice Guardian address responsible for submitting Merkle roots after triggers
    address public guardian;

    // ─── Governance Parameters ───────────────────────────────────────

    /// @notice Merkle-based claim period after merkle root submission (default 30 days from trigger)
    uint40 public merkleClaimPeriod;

    /// @notice Fallback (balanceOf) claim period after 24h deadline (default 7 days)
    uint40 public fallbackClaimPeriod;

    /// @notice Timelock delay for emergency withdrawals (default 2 days)
    uint40 public emergencyTimelock;

    /// @notice Issuer reward share in basis points (default 1000 = 10%)
    uint256 public issuerRewardBps;

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
        bool useMerkleProof; // true = Merkle mode, false = waiting/fallback
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
        uint256 triggerBlockNumber; // block number when trigger executed (flash-loan protection)
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
    error OnlyGuardian();
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
    error IssuerCannotClaim();
    error FeeRateTooLow();
    error InvalidDuration();
    error MustWaitOneBlock();
    error FallbackAlreadyActive();
    error MerkleAlreadySubmitted();
    error NotInMerkleMode();
    error NotInFallbackMode();
    error MerkleSubmissionWindowActive();

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

    modifier onlyGuardian() {
        if (msg.sender != guardian) revert OnlyGuardian();
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
        merkleClaimPeriod = 30 days;
        fallbackClaimPeriod = 7 days;
        emergencyTimelock = 2 days;
        issuerRewardBps = 1000; // 10%
        merkleSubmissionDeadline = 24 hours;
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
        address issuedToken
    ) external onlyTriggerOracle nonReentrant returns (uint256 totalPayout) {
        PoolData storage pool = _getPool(poolId);
        if (pool.isTriggered) revert AlreadyTriggered();
        if (totalEligibleSupply == 0) revert ZeroEligibleSupply();

        // Include escrow ETH in total payout — merge into balance so
        // claim functions' `pool.balance -= amount` doesn't underflow.
        pool.balance += pool.escrowEthBalance;
        pool.escrowEthBalance = 0;
        totalPayout = pool.balance;

        pool.isTriggered = true;
        pool.triggerTimestamp = uint40(block.timestamp);
        pool.triggerBlockNumber = block.number;
        pool.triggerType = triggerType;
        pool.totalEligibleSupply = totalEligibleSupply;
        pool.payoutBalance = totalPayout;
        pool.tokenPayoutBalance = pool.escrowTokenBalance; // snapshot issued token balance
        pool.baseTokenFeePayoutBalance = pool.baseTokenFeeBalance + pool.escrowBaseTokenBalance;
        // No merkle root set — guardian has 24h to submit via submitMerkleRoot()
        pool.useMerkleProof = false;
        pool.issuedToken = issuedToken;

        emit PayoutExecuted(poolId, triggerType, totalPayout);
    }

    /// @notice Guardian submits a Merkle root within 24h of trigger, entering Merkle mode.
    /// @dev Must be called within merkleSubmissionDeadline of trigger. Once fallback mode
    ///      is active (24h elapsed without submission), this is permanently blocked.
    /// @param poolId Uniswap V4 pool identifier
    /// @param root Merkle root of (holder, balance) snapshot
    function submitMerkleRoot(PoolId poolId, bytes32 root) external onlyGuardian {
        if (root == bytes32(0)) revert MerkleRootNotSet();

        PoolData storage pool = _getPool(poolId);
        if (!pool.isTriggered) revert NotTriggered();
        if (pool.useMerkleProof) revert MerkleAlreadySubmitted();

        // Fallback is irreversible: if 24h has passed, merkle submission is permanently blocked
        if (block.timestamp > pool.triggerTimestamp + merkleSubmissionDeadline) {
            revert FallbackAlreadyActive();
        }

        pool.merkleRoot = root;
        pool.useMerkleProof = true;

        emit MerkleRootSubmitted(poolId, root);
    }

    /// @notice Claim compensation using Merkle proof (State B only).
    /// @dev Only available after guardian has submitted a Merkle root.
    /// @param poolId Uniswap V4 pool identifier
    /// @param holderBalance Holder's token balance at trigger snapshot
    /// @param merkleProof Merkle proof for (msg.sender, holderBalance) leaf
    /// @return amount Amount of compensation transferred
    function claimCompensation(PoolId poolId, uint256 holderBalance, bytes32[] calldata merkleProof)
        external
        nonReentrant
        returns (uint256 amount)
    {
        PoolData storage pool = _getPool(poolId);
        if (!pool.isTriggered) revert NotTriggered();
        if (!pool.useMerkleProof) revert NotInMerkleMode();
        if (msg.sender == IBastionHook(BASTION_HOOK).getPoolIssuer(poolId)) revert IssuerCannotClaim();
        if (pool.claimed[msg.sender]) revert AlreadyClaimed();
        if (holderBalance == 0) revert ZeroAmount();

        // Merkle mode: claim period from trigger timestamp
        if (block.timestamp > pool.triggerTimestamp + merkleClaimPeriod) revert ClaimPeriodExpired();
        if (pool.merkleRoot == bytes32(0)) revert MerkleRootNotSet();

        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(msg.sender, holderBalance))));
        if (!MerkleProof.verify(merkleProof, pool.merkleRoot, leaf)) revert InvalidMerkleProof();

        amount = _executeClaimTransfers(pool, poolId, holderBalance);
    }

    /// @notice Claim compensation using balanceOf fallback (State C only).
    /// @dev Only available after 24h deadline has passed without Merkle root submission.
    /// @param poolId Uniswap V4 pool identifier
    /// @param holderBalance Holder's token balance to claim with
    /// @return amount Amount of compensation transferred
    function claimCompensationFallback(PoolId poolId, uint256 holderBalance)
        external
        nonReentrant
        returns (uint256 amount)
    {
        PoolData storage pool = _getPool(poolId);
        if (!pool.isTriggered) revert NotTriggered();
        if (pool.useMerkleProof) revert NotInFallbackMode();
        if (msg.sender == IBastionHook(BASTION_HOOK).getPoolIssuer(poolId)) revert IssuerCannotClaim();
        if (pool.claimed[msg.sender]) revert AlreadyClaimed();
        if (holderBalance == 0) revert ZeroAmount();

        // Must wait for merkle submission deadline to pass (24h)
        if (block.timestamp <= pool.triggerTimestamp + merkleSubmissionDeadline) {
            revert MerkleSubmissionWindowActive();
        }

        // Fallback claim period: 7 days after the 24h deadline
        if (block.timestamp > pool.triggerTimestamp + merkleSubmissionDeadline + fallbackClaimPeriod) {
            revert ClaimPeriodExpired();
        }

        // Flash-loan protection: must wait at least one block after trigger
        if (block.number <= pool.triggerBlockNumber) revert MustWaitOneBlock();

        if (ERC20(pool.issuedToken).balanceOf(msg.sender) < holderBalance) {
            revert InsufficientTokenBalance();
        }

        amount = _executeClaimTransfers(pool, poolId, holderBalance);
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
        if (newFeeRate < MIN_FEE_RATE) revert FeeRateTooLow();

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
        if (block.timestamp < req.requestedAt + emergencyTimelock) revert EmergencyDelayNotElapsed();

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

    /// @notice Check if a pool is in fallback mode (24h elapsed, no merkle root)
    function isFallbackMode(PoolId poolId) external view returns (bool) {
        PoolData storage pool = _getPool(poolId);
        return pool.isTriggered && !pool.useMerkleProof
            && block.timestamp > pool.triggerTimestamp + merkleSubmissionDeadline;
    }

    /// @notice Check if a pool is in merkle mode
    function isMerkleMode(PoolId poolId) external view returns (bool) {
        PoolData storage pool = _getPool(poolId);
        return pool.isTriggered && pool.useMerkleProof;
    }

    // ═══════════════════════════════════════════════════════════════════
    //  GOVERNANCE PARAMETER SETTERS
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Transfer governance to a new address.
    function transferGovernance(address newGovernance) external onlyGovernance {
        if (newGovernance == address(0)) revert ZeroAddress();
        address oldGov = GOVERNANCE;
        GOVERNANCE = newGovernance;
        emit GovernanceTransferred(oldGov, newGovernance);
    }

    /// @notice Set the guardian address responsible for Merkle root submission.
    function setGuardian(address newGuardian) external onlyGovernance {
        if (newGuardian == address(0)) revert ZeroAddress();
        address old = guardian;
        guardian = newGuardian;
        emit GuardianSet(old, newGuardian);
    }

    /// @notice Set the Merkle-based claim period (14–90 days).
    function setMerkleClaimPeriod(uint40 newPeriod) external onlyGovernance {
        if (newPeriod < 14 days || newPeriod > 90 days) revert InvalidDuration();
        merkleClaimPeriod = newPeriod;
        emit MerkleClaimPeriodUpdated(newPeriod);
    }

    /// @notice Set the fallback claim period (3–30 days).
    function setFallbackClaimPeriod(uint40 newPeriod) external onlyGovernance {
        if (newPeriod < 3 days || newPeriod > 30 days) revert InvalidDuration();
        fallbackClaimPeriod = newPeriod;
        emit FallbackClaimPeriodUpdated(newPeriod);
    }

    /// @notice Set the emergency withdrawal timelock (1–7 days).
    function setEmergencyTimelock(uint40 newTimelock) external onlyGovernance {
        if (newTimelock < 1 days || newTimelock > 7 days) revert InvalidDuration();
        emergencyTimelock = newTimelock;
        emit EmergencyTimelockUpdated(newTimelock);
    }

    /// @notice Set the Merkle submission deadline (6h–72h).
    function setMerkleSubmissionDeadline(uint40 newDeadline) external onlyGovernance {
        if (newDeadline < 6 hours || newDeadline > 72 hours) revert InvalidDuration();
        merkleSubmissionDeadline = newDeadline;
        emit MerkleSubmissionDeadlineUpdated(newDeadline);
    }

    /// @notice Set the issuer reward share in basis points (0–3000).
    function setIssuerRewardBps(uint256 newBps) external onlyGovernance {
        if (newBps > 3000) revert FeeRateTooHigh();
        issuerRewardBps = newBps;
        emit IssuerRewardBpsUpdated(newBps);
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

        address issuer = IBastionHook(BASTION_HOOK).getPoolIssuer(poolId);
        uint256 totalIssuerReward;
        uint256 totalTreasuryAmount;

        // ETH balance split
        uint256 ethAmount = pool.balance;
        pool.balance = 0;

        if (ethAmount > 0) {
            uint256 issuerEth = ethAmount * issuerRewardBps / BPS_DENOMINATOR;
            uint256 treasuryEth = ethAmount - issuerEth;
            totalIssuerReward += issuerEth;
            totalTreasuryAmount += treasuryEth;

            if (issuerEth > 0) {
                (bool s1,) = issuer.call{value: issuerEth}("");
                if (!s1) revert TransferFailed();
            }
            if (treasuryEth > 0) {
                (bool s2,) = treasury.call{value: treasuryEth}("");
                if (!s2) revert TransferFailed();
            }
        }

        // ERC-20 base token fees split
        uint256 baseTokenAmount = pool.baseTokenFeeBalance;
        if (baseTokenAmount > 0 && pool.baseTokenFeeToken != address(0)) {
            pool.baseTokenFeeBalance = 0;
            uint256 issuerToken = baseTokenAmount * issuerRewardBps / BPS_DENOMINATOR;
            uint256 treasuryToken = baseTokenAmount - issuerToken;
            totalIssuerReward += issuerToken;
            totalTreasuryAmount += treasuryToken;

            if (issuerToken > 0) {
                SafeTransferLib.safeTransfer(ERC20(pool.baseTokenFeeToken), issuer, issuerToken);
            }
            if (treasuryToken > 0) {
                SafeTransferLib.safeTransfer(ERC20(pool.baseTokenFeeToken), treasury, treasuryToken);
            }
        }

        emit IInsurancePool.TreasuryFundsClaimed(poolId, totalTreasuryAmount, totalIssuerReward);
    }

    // ─── Internal Functions ───────────────────────────────────────────

    function _getPool(PoolId poolId) internal view returns (PoolData storage) {
        return _pools[PoolId.unwrap(poolId)];
    }

    /// @dev Shared claim execution logic for both Merkle and Fallback modes.
    function _executeClaimTransfers(PoolData storage pool, PoolId poolId, uint256 holderBalance)
        internal
        returns (uint256 amount)
    {
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
            SafeTransferLib.safeTransfer(ERC20(pool.escrowToken), msg.sender, tokenShare);
        }

        // Transfer ERC-20 base token fees + escrow base tokens
        if (baseTokenShare > 0) {
            address baseToken = pool.baseTokenFeeToken != address(0) ? pool.baseTokenFeeToken : pool.escrowBaseToken;
            if (baseToken != address(0)) {
                SafeTransferLib.safeTransfer(ERC20(baseToken), msg.sender, baseTokenShare);
            }
        }

        emit CompensationClaimed(poolId, msg.sender, amount);
    }

    function _calculateCompensation(PoolData storage pool, uint256 holderBalance)
        internal
        view
        returns (uint256)
    {
        // pro-rata: (payoutBalance * holderBalance) / totalEligibleSupply
        // Round down to prevent over-distribution; FullMath prevents overflow
        return FullMath.mulDiv(pool.payoutBalance, holderBalance, pool.totalEligibleSupply);
    }

    function _calculateTokenCompensation(PoolData storage pool, uint256 holderBalance)
        internal
        view
        returns (uint256)
    {
        if (pool.tokenPayoutBalance == 0) return 0;
        return FullMath.mulDiv(pool.tokenPayoutBalance, holderBalance, pool.totalEligibleSupply);
    }

    function _calculateBaseTokenCompensation(PoolData storage pool, uint256 holderBalance)
        internal
        view
        returns (uint256)
    {
        if (pool.baseTokenFeePayoutBalance == 0) return 0;
        return FullMath.mulDiv(pool.baseTokenFeePayoutBalance, holderBalance, pool.totalEligibleSupply);
    }
}
