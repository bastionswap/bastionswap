// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {EscrowVault} from "../../src/core/EscrowVault.sol";
import {InsurancePool} from "../../src/core/InsurancePool.sol";
import {IEscrowVault} from "../../src/interfaces/IEscrowVault.sol";
import {IInsurancePool} from "../../src/interfaces/IInsurancePool.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";

// ─── Mock Contracts ──────────────────────────────────────────────────────────

contract MockRepEngine {
    function recordEvent(address, uint8, bytes calldata) external {}
    function getScore(address) external pure returns (uint256) { return 500; }
}

contract MockERC20Token is ERC20 {
    constructor() ERC20("Mock", "MCK", 18) {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  PROTOCOL HANDLER — exercises EscrowVault + InsurancePool together
// ═══════════════════════════════════════════════════════════════════════════════

contract ProtocolHandler is Test {
    EscrowVault public vault;
    InsurancePool public pool;

    address public hook;
    address public oracle;
    address public insuranceAddr;
    address public governance;

    // Fixed escrow parameters
    uint256 public constant NUM_POOLS = 5;
    uint128 public constant ESCROW_LIQUIDITY = 100e18;

    // Escrow state tracking
    uint256[] public escrowIds;
    PoolId[] public poolIds;
    address[] public issuers;

    // Ghost variables for invariant verification
    uint128 public ghost_totalLocked;
    uint128 public ghost_totalRemoved;
    uint256 public ghost_totalFeeDeposited;
    uint256 public ghost_totalClaimed;
    mapping(uint256 => bool) public ghost_escrowTriggered;
    mapping(uint256 => uint128) public ghost_escrowRemoved;
    mapping(bytes32 => bool) public ghost_poolTriggered;
    mapping(bytes32 => uint256) public ghost_poolTriggerCount;
    uint256 public ghost_removalAfterTriggerAttempts;
    bool public ghost_removalAfterTriggerSucceeded;

    // Claim tracking
    mapping(bytes32 => uint256) public ghost_poolTotalClaimed;
    mapping(bytes32 => uint256) public ghost_poolPayoutBalance;

    constructor(
        EscrowVault _vault,
        InsurancePool _pool,
        address _hook,
        address _oracle,
        address _insuranceAddr,
        address _governance
    ) {
        vault = _vault;
        pool = _pool;
        hook = _hook;
        oracle = _oracle;
        insuranceAddr = _insuranceAddr;
        governance = _governance;

        // Create NUM_POOLS escrows
        for (uint256 i; i < NUM_POOLS; ++i) {
            PoolId poolId = PoolId.wrap(bytes32(i + 1));
            address issuer = address(uint160(0x1000 + i));

            poolIds.push(poolId);
            issuers.push(issuer);

            IEscrowVault.VestingStep[] memory schedule = new IEscrowVault.VestingStep[](3);
            schedule[0] = IEscrowVault.VestingStep({timeOffset: 7 days, basisPoints: 2000});
            schedule[1] = IEscrowVault.VestingStep({timeOffset: 30 days, basisPoints: 5000});
            schedule[2] = IEscrowVault.VestingStep({timeOffset: 90 days, basisPoints: 10000});

            IEscrowVault.IssuerCommitment memory commitment = IEscrowVault.IssuerCommitment({
                dailyWithdrawLimit: 0,
                lockDuration: 0,
                maxSellPercent: 200
            });

            vm.prank(hook);
            uint256 escrowId = vault.createEscrow(poolId, issuer, ESCROW_LIQUIDITY, schedule, commitment);
            escrowIds.push(escrowId);

            ghost_totalLocked += ESCROW_LIQUIDITY;
        }

        // Fund insurance pool for each pool
        for (uint256 i; i < NUM_POOLS; ++i) {
            vm.deal(hook, 10 ether);
            vm.prank(hook);
            pool.depositFee{value: 10 ether}(poolIds[i]);
            ghost_totalFeeDeposited += 10 ether;
        }
    }

    // ─── Handler Actions ─────────────────────────────────────────────

    function warpForward(uint256 secs) external {
        secs = bound(secs, 1, 120 days);
        vm.warp(block.timestamp + secs);
    }

    function recordLPRemoval(uint256 poolIndex, uint128 amount) external {
        poolIndex = bound(poolIndex, 0, NUM_POOLS - 1);
        uint256 escrowId = escrowIds[poolIndex];

        if (ghost_escrowTriggered[escrowId]) {
            ghost_removalAfterTriggerAttempts++;
        }

        uint128 removable = vault.getRemovableLiquidity(escrowId);
        amount = uint128(bound(amount, 0, removable));
        if (amount == 0) return;

        vm.prank(hook);
        try vault.recordLPRemoval(escrowId, amount) {
            ghost_totalRemoved += amount;
            ghost_escrowRemoved[escrowId] += amount;

            if (ghost_escrowTriggered[escrowId]) {
                ghost_removalAfterTriggerSucceeded = true;
            }
        } catch {}
    }

    function triggerLockdown(uint256 poolIndex) external {
        poolIndex = bound(poolIndex, 0, NUM_POOLS - 1);
        uint256 escrowId = escrowIds[poolIndex];
        bytes32 poolKey = PoolId.unwrap(poolIds[poolIndex]);

        vm.prank(oracle);
        try vault.triggerLockdown(escrowId, 1) {
            ghost_escrowTriggered[escrowId] = true;
            ghost_poolTriggerCount[poolKey]++;
        } catch {}
    }

    function executePayout(uint256 poolIndex) external {
        poolIndex = bound(poolIndex, 0, NUM_POOLS - 1);
        PoolId poolId = poolIds[poolIndex];
        bytes32 poolKey = PoolId.unwrap(poolId);

        if (ghost_poolTriggered[poolKey]) return;

        vm.prank(oracle);
        try pool.executePayout(poolId, 1, 1000 ether, bytes32(0), address(0)) returns (uint256 payout) {
            ghost_poolTriggered[poolKey] = true;
            ghost_poolPayoutBalance[poolKey] = payout;
        } catch {}
    }

    function depositFee(uint256 poolIndex, uint256 amount) external {
        poolIndex = bound(poolIndex, 0, NUM_POOLS - 1);
        amount = bound(amount, 0.001 ether, 5 ether);

        vm.deal(hook, amount);
        vm.prank(hook);
        pool.depositFee{value: amount}(poolIds[poolIndex]);
        ghost_totalFeeDeposited += amount;
    }

    function claimCompensation(uint256 poolIndex, uint256 holderBalance) external {
        poolIndex = bound(poolIndex, 0, NUM_POOLS - 1);
        holderBalance = bound(holderBalance, 1, 100 ether);
        PoolId poolId = poolIds[poolIndex];
        bytes32 poolKey = PoolId.unwrap(poolId);

        if (!ghost_poolTriggered[poolKey]) return;

        address holder = msg.sender;
        bytes32[] memory proof = new bytes32[](0);

        vm.prank(holder);
        try pool.claimCompensation(poolId, holderBalance, proof) returns (uint256 amt) {
            ghost_totalClaimed += amt;
            ghost_poolTotalClaimed[poolKey] += amt;
        } catch {}
    }

    // ─── View Helpers ─────────────────────────────────────────────────

    function getEscrowId(uint256 index) external view returns (uint256) {
        return escrowIds[index];
    }

    function getPoolId(uint256 index) external view returns (PoolId) {
        return poolIds[index];
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  PROTOCOL INVARIANT TESTS
// ═══════════════════════════════════════════════════════════════════════════════

contract ProtocolInvariantTest is Test {
    EscrowVault public vault;
    InsurancePool public pool;
    ProtocolHandler public handler;

    address public hook;
    address public oracle;
    address public insuranceAddr;
    address public governance;

    function setUp() public {
        hook = makeAddr("hook");
        oracle = makeAddr("oracle");
        governance = makeAddr("governance");

        vault = new EscrowVault(hook, oracle, address(new MockRepEngine()));

        // InsurancePool: hook deposits fees, oracle triggers payouts
        pool = new InsurancePool(hook, oracle, governance, address(0), address(0));
        insuranceAddr = address(pool);

        handler = new ProtocolHandler(vault, pool, hook, oracle, insuranceAddr, governance);

        targetContract(address(handler));
    }

    // ─── Invariant 1: totalLiquidity >= removedLiquidity for every escrow ──

    function invariant_escrowLiquidityGeRemoved() public view {
        for (uint256 i; i < handler.NUM_POOLS(); ++i) {
            uint256 escrowId = handler.escrowIds(i);
            if (handler.ghost_escrowTriggered(escrowId)) continue;

            IEscrowVault.EscrowStatus memory status = vault.getEscrowStatus(escrowId);
            assert(status.totalLiquidity >= status.removedLiquidity);
        }
    }

    // ─── Invariant 2: InsurancePool balance consistency ───────────────

    function invariant_insurancePoolBalanceConsistency() public view {
        for (uint256 i; i < handler.NUM_POOLS(); ++i) {
            PoolId poolId = handler.poolIds(i);
            IInsurancePool.PoolStatus memory status = pool.getPoolStatus(poolId);
            assert(status.balance <= address(pool).balance);
        }
    }

    // ─── Invariant 3: No removal after trigger ────────────────────────

    function invariant_noRemovalAfterTrigger() public view {
        assert(!handler.ghost_removalAfterTriggerSucceeded());
    }

    // ─── Invariant 4: Max 1 trigger per pool (escrow side) ───────────

    function invariant_maxOneTriggerPerPool() public view {
        for (uint256 i; i < handler.NUM_POOLS(); ++i) {
            bytes32 poolKey = PoolId.unwrap(handler.poolIds(i));
            assert(handler.ghost_poolTriggerCount(poolKey) <= 1);
        }
    }

    // ─── Invariant 5: Vault holds no assets ───────────────────────────

    function invariant_vaultHoldsNoAssets() public view {
        assertEq(address(vault).balance, 0);
    }

    // ─── Invariant 6: ETH conservation (InsurancePool) ───────────────

    function invariant_insuranceEthConservation() public view {
        uint256 poolEthBalance = address(pool).balance;
        uint256 expectedEth = handler.ghost_totalFeeDeposited() - handler.ghost_totalClaimed();
        assertEq(poolEthBalance, expectedEth);
    }

    // ─── Invariant 7: Claims never exceed payout balance per pool ────

    function invariant_claimsNeverExceedPayout() public view {
        for (uint256 i; i < handler.NUM_POOLS(); ++i) {
            bytes32 poolKey = PoolId.unwrap(handler.poolIds(i));
            uint256 totalClaimed = handler.ghost_poolTotalClaimed(poolKey);
            uint256 payoutBalance = handler.ghost_poolPayoutBalance(poolKey);
            if (payoutBalance > 0) {
                assert(totalClaimed <= payoutBalance);
            }
        }
    }

    // ─── Invariant 8: Removed amount matches ghost tracking ─────────

    function invariant_removedMatchesGhost() public view {
        for (uint256 i; i < handler.NUM_POOLS(); ++i) {
            uint256 escrowId = handler.escrowIds(i);
            if (handler.ghost_escrowTriggered(escrowId)) continue;

            IEscrowVault.EscrowStatus memory status = vault.getEscrowStatus(escrowId);
            assertEq(status.removedLiquidity, handler.ghost_escrowRemoved(escrowId));
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  ECONOMIC INVARIANT TESTS
// ═══════════════════════════════════════════════════════════════════════════════

contract EconomicHandler is Test {
    EscrowVault public vault;
    InsurancePool public pool;

    address public hook;
    address public oracle;

    uint256 public escrowId;
    PoolId public poolId;
    address public issuer;
    uint128 public escrowLiquidity;

    // Ghost: track total LP removed by issuer
    uint128 public ghost_totalRemoved;
    // Ghost: track fee deposits to insurance
    uint256 public ghost_insuranceFees;

    bool public ghost_triggered;

    constructor(
        EscrowVault _vault,
        InsurancePool _pool,
        address _hook,
        address _oracle,
        uint128 _liquidity
    ) {
        vault = _vault;
        pool = _pool;
        hook = _hook;
        oracle = _oracle;
        escrowLiquidity = _liquidity;

        issuer = makeAddr("econ_issuer");
        poolId = PoolId.wrap(bytes32(uint256(0xECECEC)));
        escrowId = uint256(keccak256(abi.encode(poolId, issuer)));

        IEscrowVault.VestingStep[] memory schedule = new IEscrowVault.VestingStep[](3);
        schedule[0] = IEscrowVault.VestingStep({timeOffset: 7 days, basisPoints: 2000});
        schedule[1] = IEscrowVault.VestingStep({timeOffset: 30 days, basisPoints: 5000});
        schedule[2] = IEscrowVault.VestingStep({timeOffset: 90 days, basisPoints: 10000});

        IEscrowVault.IssuerCommitment memory commitment = IEscrowVault.IssuerCommitment({
            dailyWithdrawLimit: 0,
            lockDuration: 0,
            maxSellPercent: 200
        });

        vm.prank(hook);
        vault.createEscrow(poolId, issuer, _liquidity, schedule, commitment);

        // Fund insurance pool
        vm.deal(hook, 5 ether);
        vm.prank(hook);
        pool.depositFee{value: 5 ether}(poolId);
        ghost_insuranceFees = 5 ether;
    }

    function warpForward(uint256 secs) external {
        secs = bound(secs, 1, 120 days);
        vm.warp(block.timestamp + secs);
    }

    function recordLPRemoval(uint128 amount) external {
        if (ghost_triggered) return;

        uint128 removable = vault.getRemovableLiquidity(escrowId);
        amount = uint128(bound(amount, 0, removable));
        if (amount == 0) return;

        vm.prank(hook);
        try vault.recordLPRemoval(escrowId, amount) {
            ghost_totalRemoved += amount;
        } catch {}
    }

    function triggerLockdown() external {
        if (ghost_triggered) return;

        vm.prank(oracle);
        try vault.triggerLockdown(escrowId, 1) {
            ghost_triggered = true;
        } catch {}
    }

    function depositFee(uint256 amount) external {
        amount = bound(amount, 0.001 ether, 2 ether);
        vm.deal(hook, amount);
        vm.prank(hook);
        pool.depositFee{value: amount}(poolId);
        ghost_insuranceFees += amount;
    }
}

contract EconomicInvariantTest is Test {
    EscrowVault public vault;
    InsurancePool public pool;
    EconomicHandler public handler;

    address public hook;
    address public oracle;
    address public governance;
    uint128 constant LIQUIDITY = 200e18;

    function setUp() public {
        hook = makeAddr("hook");
        oracle = makeAddr("oracle");
        governance = makeAddr("governance");

        vault = new EscrowVault(hook, oracle, address(new MockRepEngine()));
        pool = new InsurancePool(hook, oracle, governance, address(0), address(0));

        handler = new EconomicHandler(vault, pool, hook, oracle, LIQUIDITY);

        targetContract(address(handler));
    }

    /// @dev Issuer can never remove more LP than the total liquidity
    function invariant_issuerCantExceedLiquidity() public view {
        assert(handler.ghost_totalRemoved() <= LIQUIDITY);
    }

    /// @dev If trigger fires, issuer can't remove any more LP
    function invariant_triggerBlocksRemoval() public view {
        if (!handler.ghost_triggered()) return;
        uint128 removable = vault.getRemovableLiquidity(handler.escrowId());
        assertEq(removable, 0);
    }

    /// @dev removed + remaining = total liquidity (conservation)
    ///      After lockdown, remainingLiquidity is reported as 0 (locked), so the
    ///      invariant becomes: removedLiquidity <= totalLiquidity.
    function invariant_liquidityConservation() public view {
        IEscrowVault.EscrowStatus memory status = vault.getEscrowStatus(handler.escrowId());
        if (handler.ghost_triggered()) {
            // After lockdown: remaining is 0, removed <= total
            assertEq(status.remainingLiquidity, 0);
            assertLe(status.removedLiquidity, status.totalLiquidity);
        } else {
            // Normal: removed + remaining = total
            assertEq(uint256(status.removedLiquidity) + uint256(status.remainingLiquidity), uint256(status.totalLiquidity));
        }
    }

    /// @dev Insurance pool ETH balance tracks deposits minus claims
    function invariant_insurancePoolSolvency() public view {
        uint256 poolBalance = address(pool).balance;
        assert(poolBalance >= handler.ghost_insuranceFees());
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  CROSS-CONTRACT FUZZ TESTS — random amounts, times, holders
// ═══════════════════════════════════════════════════════════════════════════════

contract CrossContractFuzzTest is Test {
    EscrowVault public vault;
    InsurancePool public pool;
    MockERC20Token public token;

    address public hook;
    address public oracle;
    address public governance;

    function setUp() public {
        hook = makeAddr("hook");
        oracle = makeAddr("oracle");
        governance = makeAddr("governance");

        token = new MockERC20Token();
        vault = new EscrowVault(hook, oracle, address(new MockRepEngine()));
        pool = new InsurancePool(hook, oracle, governance, address(0), address(0));
    }

    function _createEscrowWithParams(
        uint128 liquidity,
        uint40 lockDuration,
        uint16 dailyLimit
    ) internal returns (uint256 escrowId, PoolId poolId, address issuer) {
        liquidity = uint128(bound(liquidity, 1e18, type(uint128).max / 2));
        lockDuration = uint40(bound(lockDuration, 0, 90 days));
        dailyLimit = uint16(bound(dailyLimit, 0, 10000));

        issuer = makeAddr("fuzz_issuer");
        poolId = PoolId.wrap(bytes32(uint256(keccak256(abi.encode(liquidity, lockDuration, dailyLimit)))));

        IEscrowVault.VestingStep[] memory schedule = new IEscrowVault.VestingStep[](3);
        schedule[0] = IEscrowVault.VestingStep({timeOffset: 7 days, basisPoints: 2000});
        schedule[1] = IEscrowVault.VestingStep({timeOffset: 30 days, basisPoints: 5000});
        schedule[2] = IEscrowVault.VestingStep({timeOffset: 90 days, basisPoints: 10000});

        IEscrowVault.IssuerCommitment memory commitment = IEscrowVault.IssuerCommitment({
            dailyWithdrawLimit: dailyLimit,
            lockDuration: lockDuration,
            maxSellPercent: 10000
        });

        vm.prank(hook);
        escrowId = vault.createEscrow(poolId, issuer, liquidity, schedule, commitment);
    }

    /// @dev Full flow: create escrow → warp → record removal → verify invariants
    function testFuzz_fullFlowRemovalInvariants(
        uint128 liquidity,
        uint40 lockDuration,
        uint16 dailyLimit,
        uint256 warpTime
    ) public {
        // Force dailyLimit to 0 so that removing all removable liquidity at once never hits DailyLimitExceeded
        dailyLimit = 0;
        (uint256 escrowId, , ) = _createEscrowWithParams(liquidity, lockDuration, dailyLimit);
        liquidity = uint128(bound(liquidity, 1e18, type(uint128).max / 2));
        warpTime = bound(warpTime, 0, 365 days);

        vm.warp(block.timestamp + warpTime);

        uint128 removable = vault.getRemovableLiquidity(escrowId);

        if (removable > 0) {
            vm.prank(hook);
            vault.recordLPRemoval(escrowId, removable);

            IEscrowVault.EscrowStatus memory status = vault.getEscrowStatus(escrowId);
            // totalLiquidity >= removedLiquidity
            assertGe(status.totalLiquidity, status.removedLiquidity);
            // remaining = totalLiquidity - removedLiquidity
            assertEq(status.remainingLiquidity, status.totalLiquidity - status.removedLiquidity);
        }
    }

    /// @dev Full flow: create escrow → partial removal → trigger → verify lockdown
    function testFuzz_fullFlowTriggerLockdown(
        uint128 liquidity,
        uint40 lockDuration,
        uint256 warpBeforeTrigger
    ) public {
        (uint256 escrowId, , ) = _createEscrowWithParams(liquidity, lockDuration, 0);
        liquidity = uint128(bound(liquidity, 1e18, type(uint128).max / 2));
        warpBeforeTrigger = bound(warpBeforeTrigger, 0, 365 days);

        vm.warp(block.timestamp + warpBeforeTrigger);

        // Try partial removal
        uint128 removable = vault.getRemovableLiquidity(escrowId);
        uint128 removed;
        if (removable > 0) {
            vm.prank(hook);
            vault.recordLPRemoval(escrowId, removable);
            removed = removable;
        }

        // Trigger lockdown
        vm.prank(oracle);
        vault.triggerLockdown(escrowId, 1);

        // Verify removal returns 0 after trigger
        uint128 removableAfter = vault.getRemovableLiquidity(escrowId);
        assertEq(removableAfter, 0);

        // After lockdown, getEscrowStatus reports remainingLiquidity = 0 (locked down).
        // The actual conservation is: removedLiquidity <= totalLiquidity
        IEscrowVault.EscrowStatus memory status = vault.getEscrowStatus(escrowId);
        assertEq(status.remainingLiquidity, 0, "remaining should be 0 after lockdown");
        assertEq(status.removedLiquidity, removed, "removed should match what was removed before lockdown");
        assertLe(status.removedLiquidity, status.totalLiquidity, "removed must not exceed total");
    }

    /// @dev Insurance pool: deposit → trigger → claim → verify pro-rata
    function testFuzz_insuranceClaimProRata(
        uint256 feeAmount,
        uint256 holderBalance,
        uint256 totalSupply
    ) public {
        feeAmount = bound(feeAmount, 0.01 ether, 1000 ether);
        totalSupply = bound(totalSupply, 1 ether, 1_000_000 ether);
        holderBalance = bound(holderBalance, 1, totalSupply);

        PoolId poolId = PoolId.wrap(bytes32(uint256(0xC1A1)));

        // Deposit
        vm.deal(hook, feeAmount);
        vm.prank(hook);
        pool.depositFee{value: feeAmount}(poolId);

        // Trigger payout (no merkle, uses fallback with balanceOf)
        MockERC20Token claimToken = new MockERC20Token();
        address holder = makeAddr("holder");
        claimToken.mint(holder, holderBalance);

        vm.prank(oracle);
        pool.executePayout(poolId, 1, totalSupply, bytes32(0), address(claimToken));

        // Calculate expected compensation
        uint256 expectedAmount = (feeAmount * holderBalance) / totalSupply;
        if (expectedAmount == 0) return;

        // Claim
        bytes32[] memory proof = new bytes32[](0);
        uint256 holderBalBefore = holder.balance;

        vm.prank(holder);
        uint256 claimed = pool.claimCompensation(poolId, holderBalance, proof);

        // Pro-rata check
        assertEq(claimed, expectedAmount);
        assertEq(holder.balance - holderBalBefore, expectedAmount);

        // Double claim should revert
        vm.prank(holder);
        vm.expectRevert(InsurancePool.AlreadyClaimed.selector);
        pool.claimCompensation(poolId, holderBalance, proof);
    }

    /// @dev Multiple holders claiming never exceeds pool balance
    function testFuzz_multipleHoldersCantExceedPool(
        uint256 feeAmount,
        uint8 numHolders
    ) public {
        feeAmount = bound(feeAmount, 1 ether, 100 ether);
        uint256 holderCount = bound(numHolders, 2, 10);

        PoolId poolId = PoolId.wrap(bytes32(uint256(0xA0A1)));
        MockERC20Token claimToken = new MockERC20Token();

        // Each holder gets equal share
        uint256 balancePerHolder = 100 ether;
        uint256 totalSupply = balancePerHolder * holderCount;

        // Mint tokens to holders
        address[] memory holders = new address[](holderCount);
        for (uint256 i; i < holderCount; ++i) {
            holders[i] = address(uint160(0x5000 + i));
            claimToken.mint(holders[i], balancePerHolder);
        }

        // Deposit and trigger
        vm.deal(hook, feeAmount);
        vm.prank(hook);
        pool.depositFee{value: feeAmount}(poolId);

        vm.prank(oracle);
        pool.executePayout(poolId, 1, totalSupply, bytes32(0), address(claimToken));

        // All holders claim
        uint256 totalClaimed;
        bytes32[] memory proof = new bytes32[](0);
        for (uint256 i; i < holderCount; ++i) {
            vm.prank(holders[i]);
            try pool.claimCompensation(poolId, balancePerHolder, proof) returns (uint256 amt) {
                totalClaimed += amt;
            } catch {}
        }

        // Total claimed must not exceed fee deposited
        assertLe(totalClaimed, feeAmount);
        // Pool should still have non-negative balance (rounding dust)
        IInsurancePool.PoolStatus memory status = pool.getPoolStatus(poolId);
        assertGe(address(pool).balance, status.balance);
    }

    /// @dev Insurance pool fee rate enforcement
    function testFuzz_feeRateBounds(uint16 newRate) public {
        if (newRate > 200) {
            vm.prank(governance);
            vm.expectRevert(InsurancePool.FeeRateTooHigh.selector);
            pool.setFeeRate(newRate);
        } else {
            vm.prank(governance);
            pool.setFeeRate(newRate);
            assertEq(pool.feeRate(), newRate);
        }
    }
}
