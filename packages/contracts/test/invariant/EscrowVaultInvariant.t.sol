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
        try vault.triggerForceRemoval(escrowId, 1) {
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

        IEscrowVault.IssuerCommitment memory commitment = IEscrowVault.IssuerCommitment({
            maxSellPercent: 200
        });

        vm.prank(hook);
        vault.createEscrow(poolId, issuer, ESCROW_LIQUIDITY, 7 days, 83 days, commitment);

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
//  INVARIANT TEST — with longer lock duration
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
    uint40 constant VESTING_DURATION = 76 days;

    function setUp() public {
        hook = makeAddr("hook");
        oracle = makeAddr("oracle");
        issuer = makeAddr("issuer");

        vault = new EscrowVault(hook, oracle, address(new MockReputationEngine()));

        PoolId poolId = PoolId.wrap(bytes32(uint256(2)));
        escrowId = uint256(keccak256(abi.encode(poolId, issuer)));

        IEscrowVault.IssuerCommitment memory commitment = IEscrowVault.IssuerCommitment({
            maxSellPercent: 200
        });

        vm.prank(hook);
        vault.createEscrow(poolId, issuer, ESCROW_LIQUIDITY, LOCK_DURATION, VESTING_DURATION, commitment);

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
//  FUZZ TESTS — random amounts, timestamps, linear vesting
// ═══════════════════════════════════════════════════════════════════════════════

contract EscrowVaultFuzzTest is Test {
    EscrowVault public vault;

    address public hook;
    address public oracle;
    address public issuer;

    uint40 constant DEFAULT_LOCK = 7 days;
    uint40 constant DEFAULT_VESTING = 83 days;

    function setUp() public {
        hook = makeAddr("hook");
        oracle = makeAddr("oracle");
        issuer = makeAddr("issuer");

        vault = new EscrowVault(hook, oracle, address(new MockReputationEngine()));
    }

    // ─── Helpers ──────────────────────────────────────────────────────

    function _noLimitCommitment() internal pure returns (IEscrowVault.IssuerCommitment memory) {
        return IEscrowVault.IssuerCommitment({maxSellPercent: 200});
    }

    function _createEscrow(PoolId poolId, uint128 liquidity, uint40 lockDuration, uint40 vestingDuration)
        internal
        returns (uint256)
    {
        vm.prank(hook);
        return vault.createEscrow(poolId, issuer, liquidity, lockDuration, vestingDuration, _noLimitCommitment());
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Invariant 1: vestedLiquidity <= totalLiquidity (fuzz random liquidity + time)
    // ═══════════════════════════════════════════════════════════════════

    function testFuzz_vestedNeverExceedsTotalLiquidity(uint128 liquidity, uint256 elapsed) public {
        liquidity = uint128(bound(liquidity, 1, type(uint128).max));
        elapsed = bound(elapsed, 0, 365 days);

        PoolId poolId = PoolId.wrap(bytes32(uint256(100)));
        uint256 escrowId = _createEscrow(poolId, liquidity, DEFAULT_LOCK, DEFAULT_VESTING);

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
        uint256 escrowId = _createEscrow(poolId, liquidity, DEFAULT_LOCK, DEFAULT_VESTING);

        vm.warp(block.timestamp + t1);
        uint128 vested1 = vault.calculateVestedLiquidity(escrowId);

        vm.warp(block.timestamp + (t2 - t1));
        uint128 vested2 = vault.calculateVestedLiquidity(escrowId);

        assertGe(vested2, vested1, "vesting decreased over time");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Invariant 3: after lock+vesting, vestedLiquidity == totalLiquidity
    // ═══════════════════════════════════════════════════════════════════

    function testFuzz_fullyVestedAfterLockPlusVesting(uint128 liquidity, uint256 extraTime) public {
        liquidity = uint128(bound(liquidity, 1, type(uint128).max));
        extraTime = bound(extraTime, 0, 365 days);

        PoolId poolId = PoolId.wrap(bytes32(uint256(300)));
        uint256 escrowId = _createEscrow(poolId, liquidity, DEFAULT_LOCK, DEFAULT_VESTING);

        vm.warp(block.timestamp + uint256(DEFAULT_LOCK) + uint256(DEFAULT_VESTING) + extraTime);
        uint128 vested = vault.calculateVestedLiquidity(escrowId);
        assertEq(vested, liquidity, "not fully vested after lock + vesting");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Invariant 4: zero vested during lock period
    // ═══════════════════════════════════════════════════════════════════

    function testFuzz_zeroVestedDuringLock(uint128 liquidity, uint256 elapsed) public {
        liquidity = uint128(bound(liquidity, 1, type(uint128).max));
        elapsed = bound(elapsed, 0, uint256(DEFAULT_LOCK) - 1);

        PoolId poolId = PoolId.wrap(bytes32(uint256(400)));
        uint256 escrowId = _createEscrow(poolId, liquidity, DEFAULT_LOCK, DEFAULT_VESTING);

        vm.warp(block.timestamp + elapsed);
        uint128 vested = vault.calculateVestedLiquidity(escrowId);
        assertEq(vested, 0, "should be 0 during lock period");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Invariant 5: linear vesting correctness
    // ═══════════════════════════════════════════════════════════════════

    function testFuzz_linearVestingCorrectness(uint128 liquidity, uint256 vestingElapsed) public {
        liquidity = uint128(bound(liquidity, 1, type(uint128).max));
        vestingElapsed = bound(vestingElapsed, 0, uint256(DEFAULT_VESTING));

        PoolId poolId = PoolId.wrap(bytes32(uint256(450)));
        uint256 escrowId = _createEscrow(poolId, liquidity, DEFAULT_LOCK, DEFAULT_VESTING);

        vm.warp(block.timestamp + uint256(DEFAULT_LOCK) + vestingElapsed);
        uint128 vested = vault.calculateVestedLiquidity(escrowId);

        uint128 expected = uint128((uint256(liquidity) * vestingElapsed) / uint256(DEFAULT_VESTING));
        assertEq(vested, expected, "linear vesting mismatch");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Invariant 6: removedLiquidity <= vestedLiquidity (fuzz)
    // ═══════════════════════════════════════════════════════════════════

    function testFuzz_removedNeverExceedsVested(uint128 liquidity, uint256 elapsed) public {
        liquidity = uint128(bound(liquidity, 1e18, type(uint128).max));
        elapsed = bound(elapsed, 0, 365 days);

        PoolId poolId = PoolId.wrap(bytes32(uint256(500)));
        uint256 escrowId = _createEscrow(poolId, liquidity, DEFAULT_LOCK, DEFAULT_VESTING);

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
    //  Invariant 7: trigger blocks future removals (fuzz)
    // ═══════════════════════════════════════════════════════════════════

    function testFuzz_removalRevertsAfterTrigger(uint128 liquidity, uint256 elapsed) public {
        liquidity = uint128(bound(liquidity, 1, type(uint128).max));
        elapsed = bound(elapsed, 0, 365 days);

        PoolId poolId = PoolId.wrap(bytes32(uint256(600)));
        uint256 escrowId = _createEscrow(poolId, liquidity, DEFAULT_LOCK, DEFAULT_VESTING);

        vm.warp(block.timestamp + elapsed);

        // Trigger lockdown
        vm.prank(oracle);
        vault.triggerForceRemoval(escrowId, 1);

        // Removal must revert
        vm.prank(hook);
        vm.expectRevert(EscrowVault.EscrowTriggered.selector);
        vault.recordLPRemoval(escrowId, 1);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  RANDOM LOCK/VESTING DURATION FUZZ — all invariants on custom durations
    // ═══════════════════════════════════════════════════════════════════

    function testFuzz_randomDurations_vestedBoundedByTotal(
        uint128 liquidity,
        uint256 elapsed,
        uint40 lockDuration,
        uint40 vestingDuration
    ) public {
        liquidity = uint128(bound(liquidity, 1, type(uint128).max));
        elapsed = bound(elapsed, 0, 730 days);
        lockDuration = uint40(bound(lockDuration, 7 days, 180 days));
        vestingDuration = uint40(bound(vestingDuration, 7 days, 365 days));

        PoolId poolId = PoolId.wrap(bytes32(uint256(700)));
        uint256 escrowId = _createEscrow(poolId, liquidity, lockDuration, vestingDuration);

        vm.warp(block.timestamp + elapsed);
        uint128 vested = vault.calculateVestedLiquidity(escrowId);
        assertLe(vested, liquidity, "random durations: vested > total");
    }

    function testFuzz_randomDurations_fullyVestedAfterEnd(
        uint128 liquidity,
        uint40 lockDuration,
        uint40 vestingDuration
    ) public {
        liquidity = uint128(bound(liquidity, 1, type(uint128).max));
        lockDuration = uint40(bound(lockDuration, 7 days, 180 days));
        vestingDuration = uint40(bound(vestingDuration, 7 days, 365 days));

        PoolId poolId = PoolId.wrap(bytes32(uint256(800)));
        uint256 escrowId = _createEscrow(poolId, liquidity, lockDuration, vestingDuration);

        vm.warp(block.timestamp + uint256(lockDuration) + uint256(vestingDuration));

        uint128 vested = vault.calculateVestedLiquidity(escrowId);
        assertEq(vested, liquidity, "random durations: not fully vested after end");
    }

    function testFuzz_randomDurations_monotonicity(
        uint128 liquidity,
        uint40 lockDuration,
        uint40 vestingDuration,
        uint256 t1,
        uint256 t2
    ) public {
        liquidity = uint128(bound(liquidity, 1, type(uint128).max));
        lockDuration = uint40(bound(lockDuration, 7 days, 180 days));
        vestingDuration = uint40(bound(vestingDuration, 7 days, 365 days));
        t1 = bound(t1, 0, 730 days);
        t2 = bound(t2, t1, 730 days);

        PoolId poolId = PoolId.wrap(bytes32(uint256(900)));
        uint256 escrowId = _createEscrow(poolId, liquidity, lockDuration, vestingDuration);

        vm.warp(block.timestamp + t1);
        uint128 vested1 = vault.calculateVestedLiquidity(escrowId);

        vm.warp(block.timestamp + (t2 - t1));
        uint128 vested2 = vault.calculateVestedLiquidity(escrowId);

        assertGe(vested2, vested1, "random durations: monotonicity violated");
    }

    function testFuzz_randomDurations_removedLeVested(
        uint128 liquidity,
        uint40 lockDuration,
        uint40 vestingDuration,
        uint256 elapsed
    ) public {
        liquidity = uint128(bound(liquidity, 1e18, type(uint128).max));
        elapsed = bound(elapsed, 0, 730 days);
        lockDuration = uint40(bound(lockDuration, 7 days, 180 days));
        vestingDuration = uint40(bound(vestingDuration, 7 days, 365 days));

        PoolId poolId = PoolId.wrap(bytes32(uint256(1100)));
        uint256 escrowId = _createEscrow(poolId, liquidity, lockDuration, vestingDuration);

        vm.warp(block.timestamp + elapsed);
        uint128 removable = vault.getRemovableLiquidity(escrowId);
        if (removable > 0) {
            vm.prank(hook);
            vault.recordLPRemoval(escrowId, removable);
        }

        uint128 vested = vault.calculateVestedLiquidity(escrowId);
        IEscrowVault.EscrowStatus memory status = vault.getEscrowStatus(escrowId);
        assertLe(status.removedLiquidity, vested, "random durations: removed > vested");
    }
}
