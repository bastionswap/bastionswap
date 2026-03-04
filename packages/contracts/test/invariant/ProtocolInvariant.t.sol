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
    MockERC20Token public token;

    address public hook;
    address public oracle;
    address public insuranceAddr;
    address public governance;

    // Fixed escrow parameters
    uint256 public constant NUM_POOLS = 5;
    uint256 public constant ESCROW_AMOUNT = 100 ether;

    // Escrow state tracking
    uint256[] public escrowIds;
    PoolId[] public poolIds;
    address[] public issuers;

    // Ghost variables for invariant verification
    uint256 public ghost_totalLocked;
    uint256 public ghost_totalReleased;
    uint256 public ghost_totalRedistributed;
    uint256 public ghost_totalFeeDeposited;
    uint256 public ghost_totalClaimed;
    mapping(uint256 => bool) public ghost_escrowTriggered;
    mapping(uint256 => uint256) public ghost_escrowReleased;
    mapping(bytes32 => bool) public ghost_poolTriggered;
    mapping(bytes32 => uint256) public ghost_poolTriggerCount;
    uint256 public ghost_releaseAfterTriggerAttempts;
    bool public ghost_releaseAfterTriggerSucceeded;

    // Claim tracking
    mapping(bytes32 => uint256) public ghost_poolTotalClaimed;
    mapping(bytes32 => uint256) public ghost_poolPayoutBalance;

    constructor(
        EscrowVault _vault,
        InsurancePool _pool,
        MockERC20Token _token,
        address _hook,
        address _oracle,
        address _insuranceAddr,
        address _governance
    ) {
        vault = _vault;
        pool = _pool;
        token = _token;
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

            token.mint(hook, ESCROW_AMOUNT);
            vm.prank(hook);
            token.approve(address(vault), type(uint256).max);

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
            uint256 escrowId = vault.createEscrow(poolId, issuer, address(token), ESCROW_AMOUNT, schedule, commitment);
            escrowIds.push(escrowId);

            ghost_totalLocked += ESCROW_AMOUNT;
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

    function releaseVested(uint256 poolIndex) external {
        poolIndex = bound(poolIndex, 0, NUM_POOLS - 1);
        uint256 escrowId = escrowIds[poolIndex];
        address issuer = issuers[poolIndex];

        if (ghost_escrowTriggered[escrowId]) {
            ghost_releaseAfterTriggerAttempts++;
        }

        vm.prank(issuer);
        try vault.releaseVested(escrowId) returns (uint256 amt) {
            ghost_totalReleased += amt;
            ghost_escrowReleased[escrowId] += amt;

            if (ghost_escrowTriggered[escrowId]) {
                ghost_releaseAfterTriggerSucceeded = true;
            }
        } catch {}
    }

    function triggerRedistribution(uint256 poolIndex) external {
        poolIndex = bound(poolIndex, 0, NUM_POOLS - 1);
        uint256 escrowId = escrowIds[poolIndex];
        bytes32 poolKey = PoolId.unwrap(poolIds[poolIndex]);

        vm.prank(oracle);
        try vault.triggerRedistribution(escrowId, 1) returns (uint256 redistributed) {
            ghost_escrowTriggered[escrowId] = true;
            ghost_totalRedistributed += redistributed;
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
    MockERC20Token public token;
    ProtocolHandler public handler;

    address public hook;
    address public oracle;
    address public insuranceAddr;
    address public governance;

    function setUp() public {
        hook = makeAddr("hook");
        oracle = makeAddr("oracle");
        governance = makeAddr("governance");

        token = new MockERC20Token();
        vault = new EscrowVault(hook, oracle, address(0), address(new MockRepEngine()));

        // InsurancePool: hook deposits fees, oracle triggers payouts
        pool = new InsurancePool(hook, oracle, governance);
        insuranceAddr = address(pool);

        handler = new ProtocolHandler(vault, pool, token, hook, oracle, insuranceAddr, governance);

        targetContract(address(handler));
    }

    // ─── Invariant 1: totalLocked >= releasedAmount for every escrow ──

    function invariant_escrowLockedGeReleased() public view {
        for (uint256 i; i < handler.NUM_POOLS(); ++i) {
            uint256 escrowId = handler.escrowIds(i);
            if (handler.ghost_escrowTriggered(escrowId)) continue;

            IEscrowVault.EscrowStatus memory status = vault.getEscrowStatus(escrowId);
            assert(status.totalLocked >= status.released);
        }
    }

    // ─── Invariant 2: InsurancePool balance consistency ───────────────

    function invariant_insurancePoolBalanceConsistency() public view {
        for (uint256 i; i < handler.NUM_POOLS(); ++i) {
            PoolId poolId = handler.poolIds(i);
            IInsurancePool.PoolStatus memory status = pool.getPoolStatus(poolId);
            // balance is uint256 so always >= 0, but verify it's not underflowed
            // by checking address(pool).balance >= sum of all pool balances
            assert(status.balance <= address(pool).balance);
        }
    }

    // ─── Invariant 3: No release after trigger ────────────────────────

    function invariant_noReleaseAfterTrigger() public view {
        assert(!handler.ghost_releaseAfterTriggerSucceeded());
    }

    // ─── Invariant 4: Max 1 trigger per pool (escrow side) ───────────

    function invariant_maxOneTriggerPerPool() public view {
        for (uint256 i; i < handler.NUM_POOLS(); ++i) {
            bytes32 poolKey = PoolId.unwrap(handler.poolIds(i));
            assert(handler.ghost_poolTriggerCount(poolKey) <= 1);
        }
    }

    // ─── Invariant 5: Token balance conservation (EscrowVault) ───────

    function invariant_escrowTokenConservation() public view {
        uint256 vaultBalance = token.balanceOf(address(vault));
        uint256 expectedInVault = handler.ghost_totalLocked()
            - handler.ghost_totalReleased()
            - handler.ghost_totalRedistributed();
        assertEq(vaultBalance, expectedInVault);
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

    // ─── Invariant 8: Released amount matches ghost tracking ─────────

    function invariant_releasedMatchesGhost() public view {
        for (uint256 i; i < handler.NUM_POOLS(); ++i) {
            uint256 escrowId = handler.escrowIds(i);
            if (handler.ghost_escrowTriggered(escrowId)) continue;

            IEscrowVault.EscrowStatus memory status = vault.getEscrowStatus(escrowId);
            assertEq(status.released, handler.ghost_escrowReleased(escrowId));
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  ECONOMIC INVARIANT TESTS
// ═══════════════════════════════════════════════════════════════════════════════

contract EconomicHandler is Test {
    EscrowVault public vault;
    InsurancePool public pool;
    MockERC20Token public token;

    address public hook;
    address public oracle;
    address public insuranceAddr;

    uint256 public escrowId;
    PoolId public poolId;
    address public issuer;
    uint256 public escrowAmount;

    // Ghost: track what issuer actually received
    uint256 public ghost_issuerReceived;
    // Ghost: track what went to insurance (redistributed from escrow)
    uint256 public ghost_insuranceFromEscrow;
    // Ghost: track fee deposits to insurance
    uint256 public ghost_insuranceFees;
    // Ghost: total holder losses (approximated as redistributed amount)
    uint256 public ghost_holderLossCovered;

    bool public ghost_triggered;

    constructor(
        EscrowVault _vault,
        InsurancePool _pool,
        MockERC20Token _token,
        address _hook,
        address _oracle,
        address _insuranceAddr,
        uint256 _amount
    ) {
        vault = _vault;
        pool = _pool;
        token = _token;
        hook = _hook;
        oracle = _oracle;
        insuranceAddr = _insuranceAddr;
        escrowAmount = _amount;

        issuer = makeAddr("econ_issuer");
        poolId = PoolId.wrap(bytes32(uint256(0xECECEC)));
        escrowId = uint256(keccak256(abi.encode(poolId, issuer)));

        // Create escrow
        token.mint(hook, _amount);
        vm.prank(hook);
        token.approve(address(vault), type(uint256).max);

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
        vault.createEscrow(poolId, issuer, address(token), _amount, schedule, commitment);

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

    function releaseVested() external {
        if (ghost_triggered) return;
        vm.prank(issuer);
        try vault.releaseVested(escrowId) returns (uint256 amt) {
            ghost_issuerReceived += amt;
        } catch {}
    }

    function triggerAndRedistribute() external {
        if (ghost_triggered) return;

        vm.prank(oracle);
        try vault.triggerRedistribution(escrowId, 1) returns (uint256 redistributed) {
            ghost_triggered = true;
            ghost_insuranceFromEscrow = redistributed;
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
    MockERC20Token public token;
    EconomicHandler public handler;

    address public hook;
    address public oracle;
    address public governance;
    uint256 constant AMOUNT = 200 ether;

    function setUp() public {
        hook = makeAddr("hook");
        oracle = makeAddr("oracle");
        governance = makeAddr("governance");

        token = new MockERC20Token();
        vault = new EscrowVault(hook, oracle, address(0), address(new MockRepEngine()));
        pool = new InsurancePool(hook, oracle, governance);

        handler = new EconomicHandler(vault, pool, token, hook, oracle, address(pool), AMOUNT);

        targetContract(address(handler));
    }

    /// @dev Issuer can never extract more than the escrow amount
    function invariant_issuerCantExceedEscrowAmount() public view {
        assert(handler.ghost_issuerReceived() <= AMOUNT);
    }

    /// @dev If trigger fires with remaining funds, issuer gets less than full amount (scam cost > 0)
    function invariant_triggerReducesIssuerGains() public view {
        if (!handler.ghost_triggered()) return;
        // If escrow had remaining funds at trigger time, issuer got less than total
        uint256 redistributed = handler.ghost_insuranceFromEscrow();
        if (redistributed > 0) {
            assert(handler.ghost_issuerReceived() < AMOUNT);
        }
        // Either way, issuer never gets more than the total
        assert(handler.ghost_issuerReceived() <= AMOUNT);
    }

    /// @dev After trigger, redistributed + issued = total locked
    function invariant_triggerConservesFunds() public view {
        if (!handler.ghost_triggered()) return;
        uint256 sum = handler.ghost_issuerReceived() + handler.ghost_insuranceFromEscrow();
        assertEq(sum, AMOUNT);
    }

    /// @dev Insurance pool ETH balance tracks deposits minus claims
    function invariant_insurancePoolSolvency() public view {
        uint256 poolBalance = address(pool).balance;
        assert(poolBalance >= handler.ghost_insuranceFees());
    }

    /// @dev Coverage ratio: insurance redistributed is always from remaining escrow
    function invariant_coverageFromRemaining() public view {
        if (!handler.ghost_triggered()) return;
        // Redistributed amount = totalLocked - released (which is what's left in escrow)
        uint256 expectedRedistributed = AMOUNT - handler.ghost_issuerReceived();
        assertEq(handler.ghost_insuranceFromEscrow(), expectedRedistributed);
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
    address public insurancePool_;
    address public governance;

    function setUp() public {
        hook = makeAddr("hook");
        oracle = makeAddr("oracle");
        governance = makeAddr("governance");

        token = new MockERC20Token();
        vault = new EscrowVault(hook, oracle, address(0), address(new MockRepEngine()));
        pool = new InsurancePool(hook, oracle, governance);
        insurancePool_ = address(pool);
    }

    function _createEscrowWithParams(
        uint256 amount,
        uint40 lockDuration,
        uint16 dailyLimit
    ) internal returns (uint256 escrowId, PoolId poolId, address issuer) {
        amount = bound(amount, 1 ether, type(uint128).max);
        lockDuration = uint40(bound(lockDuration, 0, 90 days));
        dailyLimit = uint16(bound(dailyLimit, 0, 10000));

        issuer = makeAddr("fuzz_issuer");
        poolId = PoolId.wrap(bytes32(uint256(keccak256(abi.encode(amount, lockDuration, dailyLimit)))));

        token.mint(hook, amount);
        vm.prank(hook);
        token.approve(address(vault), type(uint256).max);

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
        escrowId = vault.createEscrow(poolId, issuer, address(token), amount, schedule, commitment);
    }

    /// @dev Full flow: create escrow → warp → release → verify invariants
    function testFuzz_fullFlowReleaseInvariants(
        uint256 amount,
        uint40 lockDuration,
        uint16 dailyLimit,
        uint256 warpTime
    ) public {
        (uint256 escrowId, , address issuer) = _createEscrowWithParams(amount, lockDuration, dailyLimit);
        amount = bound(amount, 1 ether, type(uint128).max);
        warpTime = bound(warpTime, 0, 365 days);

        vm.warp(block.timestamp + warpTime);

        uint256 vestedBefore = vault.calculateVestedAmount(escrowId);

        vm.prank(issuer);
        try vault.releaseVested(escrowId) returns (uint256 released) {
            // released <= vested
            assertLe(released, vestedBefore);

            IEscrowVault.EscrowStatus memory status = vault.getEscrowStatus(escrowId);
            // totalLocked >= released
            assertGe(status.totalLocked, status.released);
            // remaining = totalLocked - released
            assertEq(status.remaining, status.totalLocked - status.released);
        } catch {}
    }

    /// @dev Full flow: create escrow → partial release → trigger → verify conservation
    function testFuzz_fullFlowTriggerConservation(
        uint256 amount,
        uint40 lockDuration,
        uint256 warpBeforeTrigger
    ) public {
        (uint256 escrowId, , address issuer) = _createEscrowWithParams(amount, lockDuration, 0);
        amount = bound(amount, 1 ether, type(uint128).max);
        warpBeforeTrigger = bound(warpBeforeTrigger, 0, 365 days);

        vm.warp(block.timestamp + warpBeforeTrigger);

        // Try partial release
        uint256 issuerBalBefore = token.balanceOf(issuer);
        vm.prank(issuer);
        try vault.releaseVested(escrowId) {} catch {}
        uint256 released = token.balanceOf(issuer) - issuerBalBefore;

        // Trigger
        uint256 insuranceBefore = token.balanceOf(address(0));
        vm.prank(oracle);
        uint256 redistributed = vault.triggerRedistribution(escrowId, 1);

        // Conservation: released + redistributed = original amount
        assertEq(released + redistributed, amount);

        // Verify release reverts after trigger
        vm.prank(issuer);
        vm.expectRevert(EscrowVault.EscrowTriggered.selector);
        vault.releaseVested(escrowId);
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
