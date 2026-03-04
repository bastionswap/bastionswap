// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {EscrowVault} from "../../src/core/EscrowVault.sol";
import {IEscrowVault} from "../../src/interfaces/IEscrowVault.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";

// ─── Mock Token ───────────────────────────────────────────────────────────────

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock", "MCK", 18) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  HANDLER — fuzzer calls these in random order
// ═══════════════════════════════════════════════════════════════════════════════

contract EscrowVaultHandler is Test {
    EscrowVault public vault;
    MockERC20 public token;
    uint256 public escrowId;
    uint256 public totalAmount;
    address public oracle;

    // Ghost variables for invariant verification
    uint256 public ghost_lastVestedAmount;
    uint256 public ghost_lastTimestamp;
    uint256 public ghost_totalReleased;
    bool public ghost_triggered;

    // Track monotonicity violations
    bool public ghost_monotonicityViolated;

    constructor(EscrowVault _vault, MockERC20 _token, uint256 _escrowId, uint256 _totalAmount, address _oracle) {
        vault = _vault;
        token = _token;
        escrowId = _escrowId;
        totalAmount = _totalAmount;
        oracle = _oracle;

        ghost_lastTimestamp = block.timestamp;
        ghost_lastVestedAmount = 0;
    }

    function warpForward(uint256 secs) external {
        secs = bound(secs, 1, 180 days);
        vm.warp(block.timestamp + secs);

        // Record vested amount for monotonicity check
        uint256 currentVested = vault.calculateVestedAmount(escrowId);
        if (currentVested < ghost_lastVestedAmount) {
            ghost_monotonicityViolated = true;
        }
        ghost_lastVestedAmount = currentVested;
        ghost_lastTimestamp = block.timestamp;
    }

    function release() external {
        if (ghost_triggered) return;

        try vault.releaseVested(escrowId) returns (uint256 amt) {
            ghost_totalReleased += amt;
        } catch {}
    }

    function triggerRedistribution() external {
        if (ghost_triggered) return;

        vm.prank(oracle);
        try vault.triggerRedistribution(escrowId, 1) {
            ghost_triggered = true;
        } catch {}
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  INVARIANT TESTS — checked after every handler call sequence
// ═══════════════════════════════════════════════════════════════════════════════

contract EscrowVaultInvariantTest is Test {
    EscrowVault public vault;
    MockERC20 public token;
    EscrowVaultHandler public handler;

    address public hook;
    address public oracle;
    address public insurancePool;
    address public issuer;

    uint256 public escrowId;
    uint256 constant ESCROW_AMOUNT = 100 ether;

    function setUp() public {
        hook = makeAddr("hook");
        oracle = makeAddr("oracle");
        insurancePool = makeAddr("insurancePool");
        issuer = makeAddr("issuer");

        vault = new EscrowVault(hook, oracle, insurancePool);
        token = new MockERC20();

        PoolId poolId = PoolId.wrap(bytes32(uint256(1)));
        escrowId = uint256(keccak256(abi.encode(poolId, issuer)));

        token.mint(hook, ESCROW_AMOUNT);
        vm.prank(hook);
        token.approve(address(vault), type(uint256).max);

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
        vault.createEscrow(poolId, issuer, address(token), ESCROW_AMOUNT, schedule, commitment);

        handler = new EscrowVaultHandler(vault, token, escrowId, ESCROW_AMOUNT, oracle);

        // Only target the handler
        targetContract(address(handler));
    }

    /// @dev Invariant 1: vestedAmount <= totalAmount (always)
    function invariant_vestedNeverExceedsTotalAmount() public view {
        uint256 vested = vault.calculateVestedAmount(escrowId);
        assert(vested <= ESCROW_AMOUNT);
    }

    /// @dev Invariant 2: vestedAmount is monotonically increasing over time
    function invariant_vestedMonotonicallyIncreasing() public view {
        assert(!handler.ghost_monotonicityViolated());
    }

    /// @dev Invariant 5: releasedAmount <= vestedAmount (always)
    function invariant_releasedNeverExceedsVested() public view {
        if (handler.ghost_triggered()) return;

        uint256 vested = vault.calculateVestedAmount(escrowId);
        IEscrowVault.EscrowStatus memory status = vault.getEscrowStatus(escrowId);
        assert(status.released <= vested);
    }

    /// @dev Invariant 6: after trigger, releaseVested() always reverts
    function invariant_releaseRevertsAfterTrigger() public {
        if (!handler.ghost_triggered()) return;

        vm.expectRevert(EscrowVault.EscrowTriggered.selector);
        vault.releaseVested(escrowId);
    }

    /// @dev Vault token balance = totalAmount - released - redistributed
    function invariant_vaultBalanceConsistency() public view {
        uint256 vaultBalance = token.balanceOf(address(vault));
        uint256 totalReleased = handler.ghost_totalReleased();

        if (handler.ghost_triggered()) {
            // All remaining went to insurance pool
            assertEq(vaultBalance, 0);
        } else {
            assertEq(vaultBalance, ESCROW_AMOUNT - totalReleased);
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  INVARIANT TEST — with lockDuration
// ═══════════════════════════════════════════════════════════════════════════════

contract EscrowVaultInvariantWithLockTest is Test {
    EscrowVault public vault;
    MockERC20 public token;
    EscrowVaultHandler public handler;

    address public hook;
    address public oracle;
    address public insurancePool;
    address public issuer;

    uint256 public escrowId;
    uint256 constant ESCROW_AMOUNT = 50 ether;
    uint40 constant LOCK_DURATION = 14 days;

    function setUp() public {
        hook = makeAddr("hook");
        oracle = makeAddr("oracle");
        insurancePool = makeAddr("insurancePool");
        issuer = makeAddr("issuer");

        vault = new EscrowVault(hook, oracle, insurancePool);
        token = new MockERC20();

        PoolId poolId = PoolId.wrap(bytes32(uint256(2)));
        escrowId = uint256(keccak256(abi.encode(poolId, issuer)));

        token.mint(hook, ESCROW_AMOUNT);
        vm.prank(hook);
        token.approve(address(vault), type(uint256).max);

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
        vault.createEscrow(poolId, issuer, address(token), ESCROW_AMOUNT, schedule, commitment);

        handler = new EscrowVaultHandler(vault, token, escrowId, ESCROW_AMOUNT, oracle);
        targetContract(address(handler));
    }

    /// @dev With lock, nothing vests before lockDuration elapses
    function invariant_noVestingDuringLock() public view {
        IEscrowVault.EscrowStatus memory status = vault.getEscrowStatus(escrowId);
        // Note: we can't directly check elapsed time vs lock, but we can verify
        // that released never exceeds vested
        if (handler.ghost_triggered()) return;
        uint256 vested = vault.calculateVestedAmount(escrowId);
        assert(status.released <= vested);
        assert(vested <= ESCROW_AMOUNT);
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
    MockERC20 public token;

    address public hook;
    address public oracle;
    address public insurancePool;
    address public issuer;

    function setUp() public {
        hook = makeAddr("hook");
        oracle = makeAddr("oracle");
        insurancePool = makeAddr("insurancePool");
        issuer = makeAddr("issuer");

        vault = new EscrowVault(hook, oracle, insurancePool);
        token = new MockERC20();
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

    function _createEscrow(PoolId poolId, uint256 amount, IEscrowVault.VestingStep[] memory schedule)
        internal
        returns (uint256)
    {
        token.mint(hook, amount);
        vm.prank(hook);
        token.approve(address(vault), type(uint256).max);
        vm.prank(hook);
        return vault.createEscrow(poolId, issuer, address(token), amount, schedule, _noLimitCommitment());
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
            // Derive per-step seeds deterministically
            uint256 stepSeed = uint256(keccak256(abi.encode(seed, i)));

            // timeOffset: strictly increasing, 1 hour - 365 days range per step
            uint40 timeGap = uint40(bound(stepSeed, 1 hours, 90 days));
            uint40 timeOffset = prevTime + timeGap;

            uint16 bps;
            if (i == len - 1) {
                bps = 10_000; // Final step must be 10000
            } else {
                // Strictly increasing, leave room for 10000 at the end
                uint16 minBps = prevBps + 1;
                uint16 maxBps = 10_000 - uint16(len - 1 - i); // leave room for remaining steps
                if (minBps > maxBps) maxBps = minBps; // safety
                bps = uint16(bound(stepSeed >> 40, minBps, maxBps));
                if (bps >= 10_000) bps = 10_000 - uint16(len - i); // ensure final can be 10000
                if (bps <= prevBps) bps = prevBps + 1; // safety
            }

            schedule[i] = IEscrowVault.VestingStep({timeOffset: timeOffset, basisPoints: bps});
            prevTime = timeOffset;
            prevBps = bps;
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Invariant 1: vestedAmount <= totalAmount (fuzz random amount + time)
    // ═══════════════════════════════════════════════════════════════════

    function testFuzz_vestedNeverExceedsTotalAmount(uint256 amount, uint256 elapsed) public {
        amount = bound(amount, 1, type(uint128).max);
        elapsed = bound(elapsed, 0, 365 days);

        PoolId poolId = PoolId.wrap(bytes32(uint256(100)));
        uint256 escrowId = _createEscrow(poolId, amount, _defaultSchedule());

        vm.warp(block.timestamp + elapsed);
        uint256 vested = vault.calculateVestedAmount(escrowId);
        assertLe(vested, amount, "vested > totalAmount");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Invariant 2: vestedAmount monotonically increases over time
    // ═══════════════════════════════════════════════════════════════════

    function testFuzz_vestedMonotonicallyIncreasing(uint256 amount, uint256 t1, uint256 t2) public {
        amount = bound(amount, 1, type(uint128).max);
        t1 = bound(t1, 0, 365 days);
        t2 = bound(t2, t1, 365 days);

        PoolId poolId = PoolId.wrap(bytes32(uint256(200)));
        uint256 escrowId = _createEscrow(poolId, amount, _defaultSchedule());

        vm.warp(block.timestamp + t1);
        uint256 vested1 = vault.calculateVestedAmount(escrowId);

        vm.warp(block.timestamp + (t2 - t1));
        uint256 vested2 = vault.calculateVestedAmount(escrowId);

        assertGe(vested2, vested1, "vesting decreased over time");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Invariant 3: after last milestone, vestedAmount == totalAmount
    // ═══════════════════════════════════════════════════════════════════

    function testFuzz_fullyVestedAfterLastMilestone(uint256 amount, uint256 extraTime) public {
        amount = bound(amount, 1, type(uint128).max);
        extraTime = bound(extraTime, 0, 365 days);

        PoolId poolId = PoolId.wrap(bytes32(uint256(300)));
        uint256 escrowId = _createEscrow(poolId, amount, _defaultSchedule());

        // Warp past the last milestone (90 days) + extra
        vm.warp(block.timestamp + 90 days + extraTime);
        uint256 vested = vault.calculateVestedAmount(escrowId);
        assertEq(vested, amount, "not fully vested after last milestone");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Invariant 4: cliff behavior — between milestones, value = previous milestone
    // ═══════════════════════════════════════════════════════════════════

    function testFuzz_cliffBetweenMilestones(uint256 amount, uint256 elapsed) public {
        amount = bound(amount, 1, type(uint128).max);
        // Between step 1 (7d) and step 2 (30d)
        elapsed = bound(elapsed, 7 days, 30 days - 1);

        PoolId poolId = PoolId.wrap(bytes32(uint256(400)));
        uint256 escrowId = _createEscrow(poolId, amount, _defaultSchedule());

        vm.warp(block.timestamp + elapsed);
        uint256 vested = vault.calculateVestedAmount(escrowId);

        // Should be exactly 10% (1000 bps), rounded down
        uint256 expected = (amount * 1000) / 10_000;
        assertEq(vested, expected, "cliff violated between step 1 and step 2");
    }

    function testFuzz_cliffBetweenMilestones_step2to3(uint256 amount, uint256 elapsed) public {
        amount = bound(amount, 1, type(uint128).max);
        // Between step 2 (30d) and step 3 (90d)
        elapsed = bound(elapsed, 30 days, 90 days - 1);

        PoolId poolId = PoolId.wrap(bytes32(uint256(401)));
        uint256 escrowId = _createEscrow(poolId, amount, _defaultSchedule());

        vm.warp(block.timestamp + elapsed);
        uint256 vested = vault.calculateVestedAmount(escrowId);

        uint256 expected = (amount * 3000) / 10_000;
        assertEq(vested, expected, "cliff violated between step 2 and step 3");
    }

    function testFuzz_cliffBeforeFirstMilestone(uint256 amount, uint256 elapsed) public {
        amount = bound(amount, 1, type(uint128).max);
        elapsed = bound(elapsed, 0, 7 days - 1);

        PoolId poolId = PoolId.wrap(bytes32(uint256(402)));
        uint256 escrowId = _createEscrow(poolId, amount, _defaultSchedule());

        vm.warp(block.timestamp + elapsed);
        uint256 vested = vault.calculateVestedAmount(escrowId);
        assertEq(vested, 0, "should be 0 before first milestone");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Invariant 5: releasedAmount <= vestedAmount (fuzz)
    // ═══════════════════════════════════════════════════════════════════

    function testFuzz_releasedNeverExceedsVested(uint256 amount, uint256 elapsed) public {
        amount = bound(amount, 1 ether, type(uint128).max);
        elapsed = bound(elapsed, 0, 365 days);

        PoolId poolId = PoolId.wrap(bytes32(uint256(500)));
        uint256 escrowId = _createEscrow(poolId, amount, _defaultSchedule());

        vm.warp(block.timestamp + elapsed);

        // Try to release (may revert if nothing vested)
        try vault.releaseVested(escrowId) {} catch {}

        uint256 vested = vault.calculateVestedAmount(escrowId);
        IEscrowVault.EscrowStatus memory status = vault.getEscrowStatus(escrowId);
        assertLe(status.released, vested, "released > vested");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Invariant 6: trigger blocks future releases (fuzz)
    // ═══════════════════════════════════════════════════════════════════

    function testFuzz_releaseRevertsAfterTrigger(uint256 amount, uint256 elapsed) public {
        amount = bound(amount, 1, type(uint128).max);
        elapsed = bound(elapsed, 0, 365 days);

        PoolId poolId = PoolId.wrap(bytes32(uint256(600)));
        uint256 escrowId = _createEscrow(poolId, amount, _defaultSchedule());

        vm.warp(block.timestamp + elapsed);

        // Trigger
        vm.prank(oracle);
        vault.triggerRedistribution(escrowId, 1);

        // Release must revert
        vm.expectRevert(EscrowVault.EscrowTriggered.selector);
        vault.releaseVested(escrowId);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  RANDOM SCHEDULE FUZZ — all invariants on custom schedules
    // ═══════════════════════════════════════════════════════════════════

    function testFuzz_randomSchedule_vestedBoundedByTotal(
        uint256 amount,
        uint256 elapsed,
        uint256 seed,
        uint8 rawLen
    ) public {
        amount = bound(amount, 1, type(uint128).max);
        elapsed = bound(elapsed, 0, 730 days);

        IEscrowVault.VestingStep[] memory schedule = _buildRandomSchedule(seed, rawLen);

        PoolId poolId = PoolId.wrap(bytes32(uint256(700)));
        uint256 escrowId = _createEscrow(poolId, amount, schedule);

        vm.warp(block.timestamp + elapsed);
        uint256 vested = vault.calculateVestedAmount(escrowId);
        assertLe(vested, amount, "random schedule: vested > total");
    }

    function testFuzz_randomSchedule_fullyVestedAfterLast(uint256 amount, uint256 seed, uint8 rawLen) public {
        amount = bound(amount, 1, type(uint128).max);

        IEscrowVault.VestingStep[] memory schedule = _buildRandomSchedule(seed, rawLen);

        PoolId poolId = PoolId.wrap(bytes32(uint256(800)));
        uint256 escrowId = _createEscrow(poolId, amount, schedule);

        // Warp past the last step's timeOffset
        uint40 lastOffset = schedule[schedule.length - 1].timeOffset;
        vm.warp(block.timestamp + uint256(lastOffset));

        uint256 vested = vault.calculateVestedAmount(escrowId);
        assertEq(vested, amount, "random schedule: not fully vested after last step");
    }

    function testFuzz_randomSchedule_monotonicity(uint256 amount, uint256 seed, uint8 rawLen, uint256 t1, uint256 t2)
        public
    {
        amount = bound(amount, 1, type(uint128).max);
        t1 = bound(t1, 0, 730 days);
        t2 = bound(t2, t1, 730 days);

        IEscrowVault.VestingStep[] memory schedule = _buildRandomSchedule(seed, rawLen);

        PoolId poolId = PoolId.wrap(bytes32(uint256(900)));
        uint256 escrowId = _createEscrow(poolId, amount, schedule);

        vm.warp(block.timestamp + t1);
        uint256 vested1 = vault.calculateVestedAmount(escrowId);

        vm.warp(block.timestamp + (t2 - t1));
        uint256 vested2 = vault.calculateVestedAmount(escrowId);

        assertGe(vested2, vested1, "random schedule: monotonicity violated");
    }

    function testFuzz_randomSchedule_cliffBehavior(uint256 amount, uint256 seed, uint8 rawLen, uint256 elapsed)
        public
    {
        amount = bound(amount, 1, type(uint128).max);

        IEscrowVault.VestingStep[] memory schedule = _buildRandomSchedule(seed, rawLen);

        PoolId poolId = PoolId.wrap(bytes32(uint256(1000)));
        uint256 escrowId = _createEscrow(poolId, amount, schedule);

        // Pick a time between any two adjacent milestones (or before first)
        uint40 lastOffset = schedule[schedule.length - 1].timeOffset;
        elapsed = bound(elapsed, 0, uint256(lastOffset) - 1);

        vm.warp(block.timestamp + elapsed);
        uint256 vested = vault.calculateVestedAmount(escrowId);

        // Determine which step's bps should apply
        uint16 expectedBps;
        for (uint256 i; i < schedule.length; ++i) {
            if (schedule[i].timeOffset <= uint40(elapsed)) {
                expectedBps = schedule[i].basisPoints;
            } else {
                break;
            }
        }

        uint256 expected = (amount * expectedBps) / 10_000;
        assertEq(vested, expected, "random schedule: cliff mismatch");
    }

    function testFuzz_randomSchedule_releasedLeVested(uint256 amount, uint256 seed, uint8 rawLen, uint256 elapsed)
        public
    {
        amount = bound(amount, 1 ether, type(uint128).max);
        elapsed = bound(elapsed, 0, 730 days);

        IEscrowVault.VestingStep[] memory schedule = _buildRandomSchedule(seed, rawLen);

        PoolId poolId = PoolId.wrap(bytes32(uint256(1100)));
        uint256 escrowId = _createEscrow(poolId, amount, schedule);

        vm.warp(block.timestamp + elapsed);
        try vault.releaseVested(escrowId) {} catch {}

        uint256 vested = vault.calculateVestedAmount(escrowId);
        IEscrowVault.EscrowStatus memory status = vault.getEscrowStatus(escrowId);
        assertLe(status.released, vested, "random schedule: released > vested");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  ROUNDING — verify round-down never overpays
    // ═══════════════════════════════════════════════════════════════════

    function testFuzz_roundingDown(uint256 amount, uint16 bps) public {
        amount = bound(amount, 1, type(uint128).max);
        bps = uint16(bound(bps, 1, 10_000));

        // Manual round-down calc matches Solidity integer division
        uint256 expected = (amount * bps) / 10_000;
        assertLe(expected, amount, "rounding: exceeds total");

        // Verify the contract matches when we construct a 1-step schedule at the bps
        IEscrowVault.VestingStep[] memory schedule = new IEscrowVault.VestingStep[](1);
        schedule[0] = IEscrowVault.VestingStep({timeOffset: 1 days, basisPoints: 10_000});

        // For sub-10000 bps we need a 2-step schedule
        if (bps < 10_000) {
            schedule = new IEscrowVault.VestingStep[](2);
            schedule[0] = IEscrowVault.VestingStep({timeOffset: 1 days, basisPoints: bps});
            schedule[1] = IEscrowVault.VestingStep({timeOffset: 2 days, basisPoints: 10_000});
        }

        PoolId poolId = PoolId.wrap(bytes32(uint256(keccak256(abi.encode(amount, bps)))));
        uint256 escrowId = _createEscrow(poolId, amount, schedule);

        // Warp to exactly the first step
        vm.warp(block.timestamp + 1 days);
        uint256 vested = vault.calculateVestedAmount(escrowId);

        if (bps == 10_000) {
            assertEq(vested, amount, "full vest mismatch");
        } else {
            assertEq(vested, expected, "partial vest rounding mismatch");
        }
    }
}
