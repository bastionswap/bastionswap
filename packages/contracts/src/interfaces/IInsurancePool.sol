// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title IInsurancePool
/// @notice Per-token isolated insurance pool funded by a portion of buy-side swap fees.
///         When a trigger event is detected, the pool automatically compensates affected
///         token holders on a pro-rata basis via pull-based claims.
interface IInsurancePool {
    // ─── Structs ──────────────────────────────────────────────────────

    /// @notice Status snapshot of an insurance pool.
    /// @param balance Current total balance available in the insurance pool
    /// @param isTriggered Whether a trigger event has been activated
    /// @param triggerTimestamp Block timestamp when trigger was activated (0 if not triggered)
    /// @param totalEligibleSupply Total token supply eligible for claims at trigger snapshot
    struct PoolStatus {
        uint256 balance;
        bool isTriggered;
        uint40 triggerTimestamp;
        uint256 totalEligibleSupply;
    }

    // ─── Events ───────────────────────────────────────────────────────

    /// @notice Emitted when a swap fee is deposited into the insurance pool.
    /// @param poolId Uniswap V4 pool identifier
    /// @param amount Amount deposited
    event FeeDeposited(PoolId indexed poolId, uint256 amount);

    /// @notice Emitted when a payout is executed after a trigger event.
    /// @param poolId Uniswap V4 pool identifier
    /// @param triggerType Type of trigger that caused the payout
    /// @param totalPayout Total amount earmarked for distribution
    event PayoutExecuted(PoolId indexed poolId, uint8 indexed triggerType, uint256 totalPayout);

    /// @notice Emitted when an individual holder claims their compensation.
    /// @param poolId Uniswap V4 pool identifier
    /// @param holder Address of the claiming holder
    /// @param amount Amount claimed
    event CompensationClaimed(PoolId indexed poolId, address indexed holder, uint256 amount);

    /// @notice Emitted when the fee rate is updated.
    /// @param oldRate Previous fee rate in basis points
    /// @param newRate New fee rate in basis points
    event FeeRateUpdated(uint16 oldRate, uint16 newRate);

    /// @notice Emitted when an emergency withdrawal is executed.
    /// @param poolId Pool identifier
    /// @param to Recipient address
    /// @param amount Amount withdrawn
    event EmergencyWithdrawal(PoolId indexed poolId, address indexed to, uint256 amount);

    // ─── Functions ────────────────────────────────────────────────────

    /// @notice Deposits a portion of swap fees into the insurance pool for a given token pair.
    /// @dev Called by BastionHook during afterSwap on buy-side transactions.
    /// @param poolId Uniswap V4 pool identifier
    function depositFee(PoolId poolId) external payable;

    /// @notice Executes a payout from the insurance pool after a trigger event is confirmed.
    /// @dev Can only be called by TriggerOracle. Marks pool as triggered and records snapshot.
    /// @param poolId Uniswap V4 pool identifier
    /// @param triggerType The type of trigger event that occurred
    /// @param totalEligibleSupply Total token supply eligible for pro-rata claims
    /// @param merkleRoot Merkle root of (holder, balance) snapshot at trigger time
    /// @param issuedToken Address of the issued token (for fallback balanceOf claims)
    /// @return totalPayout Total amount earmarked for distribution
    function executePayout(
        PoolId poolId,
        uint8 triggerType,
        uint256 totalEligibleSupply,
        bytes32 merkleRoot,
        address issuedToken
    ) external returns (uint256 totalPayout);

    /// @notice Allows a holder to claim their pro-rata compensation after a payout.
    /// @dev Reverts if not triggered, already claimed, or claim period expired.
    ///      Holder is msg.sender. Balance is verified via Merkle proof.
    /// @param poolId Uniswap V4 pool identifier
    /// @param holderBalance Holder's token balance at trigger snapshot
    /// @param merkleProof Merkle proof for (msg.sender, holderBalance) leaf
    /// @return amount Amount of compensation transferred to the holder
    function claimCompensation(PoolId poolId, uint256 holderBalance, bytes32[] calldata merkleProof)
        external
        returns (uint256 amount);

    /// @notice Calculates the compensation amount for a given holder balance.
    /// @param poolId Uniswap V4 pool identifier
    /// @param holderBalance Holder's token balance at trigger snapshot
    /// @return amount Estimated compensation amount
    function calculateCompensation(PoolId poolId, uint256 holderBalance) external view returns (uint256 amount);

    /// @notice Returns the current status of an insurance pool.
    /// @param poolId Uniswap V4 pool identifier
    /// @return status Pool status snapshot
    function getPoolStatus(PoolId poolId) external view returns (PoolStatus memory status);

    /// @notice Sets the fee rate for insurance pool deposits.
    /// @dev Can only be called by governance.
    /// @param newFeeRate New fee rate in basis points (max 200 = 2%)
    function setFeeRate(uint16 newFeeRate) external;

    /// @notice Pending emergency withdrawal request.
    struct EmergencyRequest {
        PoolId poolId;
        address to;
        uint256 amount;
        uint40 requestedAt;
    }

    /// @notice Emitted when an emergency withdrawal is requested.
    event EmergencyWithdrawRequested(bytes32 indexed requestId, PoolId indexed poolId, address to, uint256 amount);

    /// @notice Emitted when an emergency withdrawal request is cancelled.
    event EmergencyWithdrawCancelled(bytes32 indexed requestId);

    /// @notice Request an emergency withdrawal (subject to timelock).
    /// @param poolId Pool to withdraw from
    /// @param to Recipient address
    /// @param amount Amount to withdraw
    function requestEmergencyWithdraw(PoolId poolId, address to, uint256 amount) external returns (bytes32 requestId);

    /// @notice Execute a previously requested emergency withdrawal after timelock delay.
    /// @param requestId The request identifier
    function executeEmergencyWithdraw(bytes32 requestId) external;

    /// @notice Cancel a pending emergency withdrawal request.
    /// @param requestId The request identifier
    function cancelEmergencyWithdraw(bytes32 requestId) external;

    // ─── Treasury ────────────────────────────────────────────────────

    /// @notice Emitted when unclaimed insurance funds are sent to the protocol treasury.
    event TreasuryFundsClaimed(PoolId indexed poolId, address indexed treasury, uint256 amount);

    /// @notice Emitted when the treasury address is updated.
    event TreasurySet(address oldTreasury, address newTreasury);

    /// @notice Sets the treasury address for protocol fund collection.
    /// @param treasury_ New treasury address
    function setTreasury(address treasury_) external;

    /// @notice Claims insurance pool funds to the treasury after normal pool completion.
    /// @dev Requires: pool not triggered, escrow fully vested, grace period passed.
    /// @param poolId Uniswap V4 pool identifier
    function claimTreasuryFunds(PoolId poolId) external;
}
