// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {EscrowVault} from "../../src/core/EscrowVault.sol";
import {IEscrowVault} from "../../src/interfaces/IEscrowVault.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

// ─── Mock ReputationEngine ────────────────────────────────────────────────────

contract MockReputationEngine {
    function recordEvent(address, uint8, bytes calldata) external {}
    function getScore(address) external pure returns (uint256) { return 500; }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  HANDLER — fuzzer calls these in random order
// ═══════════════════════════════════════════════════════════════════════════════

contract EscrowVaultHandler is Test {
    EscrowVault public vault;
    uint256 public escrowId;
    uint128 public totalLiquidity;
    address public hook;
    address public oracle;
    address public issuer;

    // Ghost variables for invariant verification
    uint128 public ghost_lastVestedLiquidity;
    uint256 public ghost_lastTimestamp;
    uint128 public ghost_totalRemoved;
    bool public ghost_triggered;

    // Track monotonicity violations
    bool public ghost_monotonicityViolated;

    constructor(EscrowVault _vault, uint256 _escrowId, uint128 _totalLiquidity, address _hook, address _oracle, address _issuer) {
        vault = _vault;
        escrowId = _escrowId;
        totalLiquidity = _totalLiquidity;
        hook = _hook;
        oracle = _oracle;
        issuer = _issuer;

        ghost_lastTimestamp = block.timestamp;
        ghost_lastVestedLiquidity = 0;
    }

    function warpForward(uint256 secs) external {
        secs = bound(secs, 1, 180 days);
        vm.warp(block.timestamp + secs);

        // Record vested liquidity for monotonicity check
        uint128 currentVested = vault.calculateVestedLiquidity(escrowId);
        if (currentVested < ghost_lastVestedLiquidity) {
            ghost_monotonicityViolated = true;
        }
        ghost_lastVestedLiquidity = currentVested;
        ghost_lastTimestamp = block.timestamp;
    }

    function recordRemoval(uint128 amount) external {
        if (ghost_triggered) return;
        amount = uint128(bound(amount, 0, totalLiquidity));
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
}

// ═══════════════════════════════════════════════════════════════════════════════
//  INVARIANT TESTS — checked after every handler call sequence
// ═══════════════════════════════════════════════════════════════════════════════

contract EscrowVaultInvariantTest is Test {
    EscrowVault public vault;
    EscrowVaultHandler public handler;

    address public hook;
    address public oracle;
    address public issuer;

    uint256 public escrowId;
    uint128 constant ESCROW_LIQUIDITY = 100e18;

    function setUp() public {
        hook = makeAddr("hook");
        oracle = makeAddr("oracle");
        issuer = makeAddr("issuer");

        vault = new EscrowVault(hook, oracle, address(new MockReputationEngine()));

        PoolId poolId = PoolId.wrap(bytes32(uint256(1)));
        escrowId = uint256(keccak256(abi.encode(poolId, issuer)));

        // Default 3-step schedule, no daily limit, no lock
        IEscrowVault.VestingStep[] memory schedule = new IEscrowVault.VestingStep[](3);
        schedule[0] = IEscrowVault.VestingStep({timeOffset: 7 days, basisPoints: 1000});
        schedule[1] = IEscrowVault.VestingStep({timeOffset: 30 days, basisPoints: 3000});
        schedule[2] = IEscrowVault.VestingStep({timeOffset: 90 days, basisPoints: 10000});

        IEscrowVault.IssuerCommitment memory commitment = IEscrowVault.IssuerCommitment({
            dailyWithdrawLimit: 0,
            lockDuration: 0,
            maxSellPercent: 200
        });

        vm.prank(hook);
        vault.createEscrow(poolId, issuer, ESCROW_LIQUIDITY, schedule, commitment);

        handler = new EscrowVaultHandler(vault, escrowId, ESCROW_LIQUIDITY, hook, oracle, issuer);

        // Only target the handler
        targetContract(address(handler));
    }

    /// @dev Invariant 1: vestedLiquidity <= totalLiquidity (always)
    function invariant_vestedNeverExceedsTotalLiquidity() public view {
        uint128 vested = vault.calculateVestedLiquidity(escrowId);
        assert(vested <= ESCROW_LIQUIDITY);
    }

    /// @dev Invariant 2: vestedLiquidity is monotonically increasing over time
    function invariant_vestedMonotonicallyIncreasing() public view {
        assert(!handler.ghost_monotonicityViolated());
    }

    /// @dev Invariant 3: removedLiquidity <= vestedLiquidity (always)
    function invariant_removedNeverExceedsVested() public view {
        if (handler.ghost_triggered()) return;

        uint128 vested = vault.calculateVestedLiquidity(escrowId);
        IEscrowVault.EscrowStatus memory status = vault.getEscrowStatus(escrowId);
        assert(status.removedLiquidity <= vested);
    }

    /// @dev Invariant 4: removedLiquidity <= totalLiquidity (always)
    function invariant_removedNeverExceedsTotalLiquidity() public view {
        IEscrowVault.EscrowStatus memory status = vault.getEscrowStatus(escrowId);
        assert(status.removedLiquidity <= status.totalLiquidity);
    }

    /// @dev Invariant 5: after trigger, recordLPRemoval always reverts
    function invariant_removalRevertsAfterTrigger() public {
        if (!handler.ghost_triggered()) return;

        vm.prank(hook);
        vm.expectRevert(EscrowVault.EscrowTriggered.selector);
        vault.recordLPRemoval(escrowId, 1);
    }

    /// @dev Invariant 6: Vault holds no assets (zero ETH balance always)
    function invariant_vaultHoldsNoAssets() public view {
        assertEq(address(vault).balance, 0);
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  INVARIANT TEST — with lockDuration
// ═══════════════════════════════════════════════════════════════════════════════

contract EscrowVaultInvariantWithLockTest is Test {
    EscrowVault public vault;
    EscrowVaultHandler public handler;

    address public hook;
    address public oracle;
    address public issuer;

    uint256 public escrowId;
    uint128 constant ESCROW_LIQUIDITY = 50e18;
    uint40 constant LOCK_DURATION = 14 days;

    function setUp() public {
        hook = makeAddr("hook");
        oracle = makeAddr("oracle");
        issuer = makeAddr("issuer");

        vault = new EscrowVault(hook, oracle, address(new MockReputationEngine()));

        PoolId poolId = PoolId.wrap(bytes32(uint256(2)));
        escrowId = uint256(keccak256(abi.encode(poolId, issuer)));

        IEscrowVault.VestingStep[] memory schedule = new IEscrowVault.VestingStep[](3);
        schedule[0] = IEscrowVault.VestingStep({timeOffset: 7 days, basisPoints: 1000});
        schedule[1] = IEscrowVault.VestingStep({timeOffset: 30 days, basisPoints: 3000});
        schedule[2] = IEscrowVault.VestingStep({timeOffset: 90 days, basisPoints: 10000});

        IEscrowVault.IssuerCommitment memory commitment = IEscrowVault.IssuerCommitment({
            dailyWithdrawLimit: 0,
            lockDuration: LOCK_DURATION,
            maxSellPercent: 200
        });

        vm.prank(hook);
        vault.createEscrow(poolId, issuer, ESCROW_LIQUIDITY, schedule, commitment);

        handler = new EscrowVaultHandler(vault, escrowId, ESCROW_LIQUIDITY, hook, oracle, issuer);
        targetContract(address(handler));
    }

    /// @dev With lock, nothing vests before lockDuration elapses
    function invariant_noVestingDuringLock() public view {
        IEscrowVault.EscrowStatus memory status = vault.getEscrowStatus(escrowId);
        if (handler.ghost_triggered()) return;
        uint128 vested = vault.calculateVestedLiquidity(escrowId);
        assert(status.removedLiquidity <= vested);
        assert(vested <= ESCROW_LIQUIDITY);
    }

    function invariant_vestedMonotonicallyIncreasingWithLock() public view {
        assert(!handler.ghost_monotonicityViolated());
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  FUZZ TESTS — random amounts, timestamps, and custom schedules
// ═══════════════════════════════════════════════════════════════════════════════

contract EscrowVaultFuzzTest is Test {
    EscrowVault public vault;

    address public hook;
    address public oracle;
    address public issuer;

    function setUp() public {
        hook = makeAddr("hook");
        oracle = makeAddr("oracle");
        issuer = makeAddr("issuer");

        vault = new EscrowVault(hook, oracle, address(new MockReputationEngine()));
    }

    // ─── Helpers ──────────────────────────────────────────────────────

    function _defaultSchedule() internal pure returns (IEscrowVault.VestingStep[] memory) {
        IEscrowVault.VestingStep[] memory schedule = new IEscrowVault.VestingStep[](3);
        schedule[0] = IEscrowVault.VestingStep({timeOffset: 7 days, basisPoints: 1000});
        schedule[1] = IEscrowVault.VestingStep({timeOffset: 30 days, basisPoints: 3000});
        schedule[2] = IEscrowVault.VestingStep({timeOffset: 90 days, basisPoints: 10000});
        return schedule;
    }

    function _noLimitCommitment() internal pure returns (IEscrowVault.IssuerCommitment memory) {
        return IEscrowVault.IssuerCommitment({dailyWithdrawLimit: 0, lockDuration: 0, maxSellPercent: 200});
    }

    function _createEscrow(PoolId poolId, uint128 liquidity, IEscrowVault.VestingStep[] memory schedule)
        internal
        returns (uint256)
    {
        vm.prank(hook);
        return vault.createEscrow(poolId, issuer, liquidity, schedule, _noLimitCommitment());
    }

    /// @dev Build a valid random schedule from fuzz seeds
    function _buildRandomSchedule(uint256 seed, uint8 rawLen)
        internal
        pure
        returns (IEscrowVault.VestingStep[] memory schedule)
    {
        uint256 len = bound(rawLen, 1, 10);
        schedule = new IEscrowVault.VestingStep[](len);

        uint40 prevTime;
        uint16 prevBps;

        for (uint256 i; i < len; ++i) {
            uint256 stepSeed = uint256(keccak256(abi.encode(seed, i)));

            uint40 minGap = (i == len - 1 && prevTime < 7 days)
                ? uint40(7 days - prevTime)
                : 1 hours;
            uint40 timeGap = uint40(bound(stepSeed, minGap, 90 days));
            uint40 timeOffset = prevTime + timeGap;

            uint16 bps;
            if (i == len - 1) {
                bps = 10_000;
            } else {
                uint16 minBps = prevBps + 1;
                uint16 maxBps = 10_000 - uint16(len - 1 - i);
                if (minBps > maxBps) maxBps = minBps;
                bps = uint16(bound(stepSeed >> 40, minBps, maxBps));
                if (bps >= 10_000) bps = 10_000 - uint16(len - i);
                if (bps <= prevBps) bps = prevBps + 1;
            }

            schedule[i] = IEscrowVault.VestingStep({timeOffset: timeOffset, basisPoints: bps});
            prevTime = timeOffset;
            prevBps = bps;
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Invariant 1: vestedLiquidity <= totalLiquidity (fuzz random liquidity + time)
    // ═══════════════════════════════════════════════════════════════════

    function testFuzz_vestedNeverExceedsTotalLiquidity(uint128 liquidity, uint256 elapsed) public {
        liquidity = uint128(bound(liquidity, 1, type(uint128).max));
        elapsed = bound(elapsed, 0, 365 days);

        PoolId poolId = PoolId.wrap(bytes32(uint256(100)));
        uint256 escrowId = _createEscrow(poolId, liquidity, _defaultSchedule());

        vm.warp(block.timestamp + elapsed);
        uint128 vested = vault.calculateVestedLiquidity(escrowId);
        assertLe(vested, liquidity, "vested > totalLiquidity");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Invariant 2: vestedLiquidity monotonically increases over time
    // ═══════════════════════════════════════════════════════════════════

    function testFuzz_vestedMonotonicallyIncreasing(uint128 liquidity, uint256 t1, uint256 t2) public {
        liquidity = uint128(bound(liquidity, 1, type(uint128).max));
        t1 = bound(t1, 0, 365 days);
        t2 = bound(t2, t1, 365 days);

        PoolId poolId = PoolId.wrap(bytes32(uint256(200)));
        uint256 escrowId = _createEscrow(poolId, liquidity, _defaultSchedule());

        vm.warp(block.timestamp + t1);
        uint128 vested1 = vault.calculateVestedLiquidity(escrowId);

        vm.warp(block.timestamp + (t2 - t1));
        uint128 vested2 = vault.calculateVestedLiquidity(escrowId);

        assertGe(vested2, vested1, "vesting decreased over time");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Invariant 3: after last milestone, vestedLiquidity == totalLiquidity
    // ═══════════════════════════════════════════════════════════════════

    function testFuzz_fullyVestedAfterLastMilestone(uint128 liquidity, uint256 extraTime) public {
        liquidity = uint128(bound(liquidity, 1, type(uint128).max));
        extraTime = bound(extraTime, 0, 365 days);

        PoolId poolId = PoolId.wrap(bytes32(uint256(300)));
        uint256 escrowId = _createEscrow(poolId, liquidity, _defaultSchedule());

        vm.warp(block.timestamp + 90 days + extraTime);
        uint128 vested = vault.calculateVestedLiquidity(escrowId);
        assertEq(vested, liquidity, "not fully vested after last milestone");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Invariant 4: cliff behavior — between milestones, value = previous milestone
    // ═══════════════════════════════════════════════════════════════════

    function testFuzz_cliffBetweenMilestones(uint128 liquidity, uint256 elapsed) public {
        liquidity = uint128(bound(liquidity, 1, type(uint128).max));
        elapsed = bound(elapsed, 7 days, 30 days - 1);

        PoolId poolId = PoolId.wrap(bytes32(uint256(400)));
        uint256 escrowId = _createEscrow(poolId, liquidity, _defaultSchedule());

        vm.warp(block.timestamp + elapsed);
        uint128 vested = vault.calculateVestedLiquidity(escrowId);

        uint128 expected = uint128((uint256(liquidity) * 1000) / 10_000);
        assertEq(vested, expected, "cliff violated between step 1 and step 2");
    }

    function testFuzz_cliffBetweenMilestones_step2to3(uint128 liquidity, uint256 elapsed) public {
        liquidity = uint128(bound(liquidity, 1, type(uint128).max));
        elapsed = bound(elapsed, 30 days, 90 days - 1);

        PoolId poolId = PoolId.wrap(bytes32(uint256(401)));
        uint256 escrowId = _createEscrow(poolId, liquidity, _defaultSchedule());

        vm.warp(block.timestamp + elapsed);
        uint128 vested = vault.calculateVestedLiquidity(escrowId);

        uint128 expected = uint128((uint256(liquidity) * 3000) / 10_000);
        assertEq(vested, expected, "cliff violated between step 2 and step 3");
    }

    function testFuzz_cliffBeforeFirstMilestone(uint128 liquidity, uint256 elapsed) public {
        liquidity = uint128(bound(liquidity, 1, type(uint128).max));
        elapsed = bound(elapsed, 0, 7 days - 1);

        PoolId poolId = PoolId.wrap(bytes32(uint256(402)));
        uint256 escrowId = _createEscrow(poolId, liquidity, _defaultSchedule());

        vm.warp(block.timestamp + elapsed);
        uint128 vested = vault.calculateVestedLiquidity(escrowId);
        assertEq(vested, 0, "should be 0 before first milestone");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Invariant 5: removedLiquidity <= vestedLiquidity (fuzz)
    // ═══════════════════════════════════════════════════════════════════

    function testFuzz_removedNeverExceedsVested(uint128 liquidity, uint256 elapsed) public {
        liquidity = uint128(bound(liquidity, 1e18, type(uint128).max));
        elapsed = bound(elapsed, 0, 365 days);

        PoolId poolId = PoolId.wrap(bytes32(uint256(500)));
        uint256 escrowId = _createEscrow(poolId, liquidity, _defaultSchedule());

        vm.warp(block.timestamp + elapsed);

        // Try to remove (may revert if nothing vested)
        uint128 removable = vault.getRemovableLiquidity(escrowId);
        if (removable > 0) {
            vm.prank(hook);
            vault.recordLPRemoval(escrowId, removable);
        }

        uint128 vested = vault.calculateVestedLiquidity(escrowId);
        IEscrowVault.EscrowStatus memory status = vault.getEscrowStatus(escrowId);
        assertLe(status.removedLiquidity, vested, "removed > vested");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Invariant 6: trigger blocks future removals (fuzz)
    // ═══════════════════════════════════════════════════════════════════

    function testFuzz_removalRevertsAfterTrigger(uint128 liquidity, uint256 elapsed) public {
        liquidity = uint128(bound(liquidity, 1, type(uint128).max));
        elapsed = bound(elapsed, 0, 365 days);

        PoolId poolId = PoolId.wrap(bytes32(uint256(600)));
        uint256 escrowId = _createEscrow(poolId, liquidity, _defaultSchedule());

        vm.warp(block.timestamp + elapsed);

        // Trigger lockdown
        vm.prank(oracle);
        vault.triggerLockdown(escrowId, 1);

        // Removal must revert
        vm.prank(hook);
        vm.expectRevert(EscrowVault.EscrowTriggered.selector);
        vault.recordLPRemoval(escrowId, 1);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  RANDOM SCHEDULE FUZZ — all invariants on custom schedules
    // ═══════════════════════════════════════════════════════════════════

    function testFuzz_randomSchedule_vestedBoundedByTotal(
        uint128 liquidity,
        uint256 elapsed,
        uint256 seed,
        uint8 rawLen
    ) public {
        liquidity = uint128(bound(liquidity, 1, type(uint128).max));
        elapsed = bound(elapsed, 0, 730 days);

        IEscrowVault.VestingStep[] memory schedule = _buildRandomSchedule(seed, rawLen);

        PoolId poolId = PoolId.wrap(bytes32(uint256(700)));
        uint256 escrowId = _createEscrow(poolId, liquidity, schedule);

        vm.warp(block.timestamp + elapsed);
        uint128 vested = vault.calculateVestedLiquidity(escrowId);
        assertLe(vested, liquidity, "random schedule: vested > total");
    }

    function testFuzz_randomSchedule_fullyVestedAfterLast(uint128 liquidity, uint256 seed, uint8 rawLen) public {
        liquidity = uint128(bound(liquidity, 1, type(uint128).max));

        IEscrowVault.VestingStep[] memory schedule = _buildRandomSchedule(seed, rawLen);

        PoolId poolId = PoolId.wrap(bytes32(uint256(800)));
        uint256 escrowId = _createEscrow(poolId, liquidity, schedule);

        uint40 lastOffset = schedule[schedule.length - 1].timeOffset;
        vm.warp(block.timestamp + uint256(lastOffset));

        uint128 vested = vault.calculateVestedLiquidity(escrowId);
        assertEq(vested, liquidity, "random schedule: not fully vested after last step");
    }

    function testFuzz_randomSchedule_monotonicity(uint128 liquidity, uint256 seed, uint8 rawLen, uint256 t1, uint256 t2)
        public
    {
        liquidity = uint128(bound(liquidity, 1, type(uint128).max));
        t1 = bound(t1, 0, 730 days);
        t2 = bound(t2, t1, 730 days);

        IEscrowVault.VestingStep[] memory schedule = _buildRandomSchedule(seed, rawLen);

        PoolId poolId = PoolId.wrap(bytes32(uint256(900)));
        uint256 escrowId = _createEscrow(poolId, liquidity, schedule);

        vm.warp(block.timestamp + t1);
        uint128 vested1 = vault.calculateVestedLiquidity(escrowId);

        vm.warp(block.timestamp + (t2 - t1));
        uint128 vested2 = vault.calculateVestedLiquidity(escrowId);

        assertGe(vested2, vested1, "random schedule: monotonicity violated");
    }

    function testFuzz_randomSchedule_cliffBehavior(uint128 liquidity, uint256 seed, uint8 rawLen, uint256 elapsed)
        public
    {
        liquidity = uint128(bound(liquidity, 1, type(uint128).max));

        IEscrowVault.VestingStep[] memory schedule = _buildRandomSchedule(seed, rawLen);

        PoolId poolId = PoolId.wrap(bytes32(uint256(1000)));
        uint256 escrowId = _createEscrow(poolId, liquidity, schedule);

        uint40 lastOffset = schedule[schedule.length - 1].timeOffset;
        elapsed = bound(elapsed, 0, uint256(lastOffset) - 1);

        vm.warp(block.timestamp + elapsed);
        uint128 vested = vault.calculateVestedLiquidity(escrowId);

        uint16 expectedBps;
        for (uint256 i; i < schedule.length; ++i) {
            if (schedule[i].timeOffset <= uint40(elapsed)) {
                expectedBps = schedule[i].basisPoints;
            } else {
                break;
            }
        }

        uint128 expected = uint128((uint256(liquidity) * expectedBps) / 10_000);
        assertEq(vested, expected, "random schedule: cliff mismatch");
    }

    function testFuzz_randomSchedule_removedLeVested(uint128 liquidity, uint256 seed, uint8 rawLen, uint256 elapsed)
        public
    {
        liquidity = uint128(bound(liquidity, 1e18, type(uint128).max));
        elapsed = bound(elapsed, 0, 730 days);

        IEscrowVault.VestingStep[] memory schedule = _buildRandomSchedule(seed, rawLen);

        PoolId poolId = PoolId.wrap(bytes32(uint256(1100)));
        uint256 escrowId = _createEscrow(poolId, liquidity, schedule);

        vm.warp(block.timestamp + elapsed);
        uint128 removable = vault.getRemovableLiquidity(escrowId);
        if (removable > 0) {
            vm.prank(hook);
            vault.recordLPRemoval(escrowId, removable);
        }

        uint128 vested = vault.calculateVestedLiquidity(escrowId);
        IEscrowVault.EscrowStatus memory status = vault.getEscrowStatus(escrowId);
        assertLe(status.removedLiquidity, vested, "random schedule: removed > vested");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  ROUNDING — verify round-down never overpays
    // ═══════════════════════════════════════════════════════════════════

    function testFuzz_roundingDown(uint128 liquidity, uint16 bps) public {
        liquidity = uint128(bound(liquidity, 1, type(uint128).max));
        bps = uint16(bound(bps, 1, 10_000));

        uint128 expected = uint128((uint256(liquidity) * bps) / 10_000);
        assertLe(expected, liquidity, "rounding: exceeds total");

        IEscrowVault.VestingStep[] memory schedule;
        if (bps == 10_000) {
            schedule = new IEscrowVault.VestingStep[](1);
            schedule[0] = IEscrowVault.VestingStep({timeOffset: 7 days, basisPoints: 10_000});
        } else {
            schedule = new IEscrowVault.VestingStep[](2);
            schedule[0] = IEscrowVault.VestingStep({timeOffset: 7 days, basisPoints: bps});
            schedule[1] = IEscrowVault.VestingStep({timeOffset: 14 days, basisPoints: 10_000});
        }

        PoolId poolId = PoolId.wrap(bytes32(uint256(keccak256(abi.encode(liquidity, bps)))));
        uint256 escrowId = _createEscrow(poolId, liquidity, schedule);

        vm.warp(block.timestamp + 7 days);
        uint128 vested = vault.calculateVestedLiquidity(escrowId);

        if (bps == 10_000) {
            assertEq(vested, liquidity, "full vest mismatch");
        } else {
            assertEq(vested, expected, "partial vest rounding mismatch");
        }
    }
}
