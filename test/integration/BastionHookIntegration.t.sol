// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SortTokens} from "@uniswap/v4-core/test/utils/SortTokens.sol";

import {BastionHook} from "../../src/hooks/BastionHook.sol";
import {EscrowVault} from "../../src/core/EscrowVault.sol";
import {InsurancePool} from "../../src/core/InsurancePool.sol";
import {TriggerOracle} from "../../src/core/TriggerOracle.sol";
import {IEscrowVault} from "../../src/interfaces/IEscrowVault.sol";
import {ITriggerOracle} from "../../src/interfaces/ITriggerOracle.sol";
import {IReputationEngine} from "../../src/interfaces/IReputationEngine.sol";

contract MockReputationEngine {
    function recordEvent(address, uint8, bytes calldata) external {}
    function getScore(address) external pure returns (uint256) { return 500; }
}

contract BastionHookIntegrationTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    BastionHook public hook;
    EscrowVault public escrowVault;
    InsurancePool public insurancePool;
    TriggerOracle public triggerOracle;

    MockERC20 public issuedToken;
    MockERC20 public baseToken;

    address public issuerAddr;
    address public guardian;
    address public governance;
    address public trader;

    PoolKey public poolKey;
    PoolId public poolId;

    uint256 constant ESCROW_AMOUNT = 100 ether;

    function setUp() public {
        issuerAddr = makeAddr("issuer");
        guardian = makeAddr("guardian");
        governance = makeAddr("governance");
        trader = makeAddr("trader");

        // Deploy V4 PoolManager and routers
        deployFreshManagerAndRouters();

        // Compute the hook address with correct permission bits
        // beforeAddLiquidity(1<<11) | beforeRemoveLiquidity(1<<9) | afterSwap(1<<6)
        uint160 flags =
            uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG);

        address hookAddr = address(flags);

        // Deploy mock before nonce computation to avoid nonce mismatch
        MockReputationEngine mockReputation = new MockReputationEngine();
        address reputationAddr = address(mockReputation);

        // Pre-compute addresses to resolve circular dependency
        // Deploy order: escrowVault (nonce N), insurancePool (N+1), triggerOracle (N+2)
        uint64 nonce = vm.getNonce(address(this));
        address escrowAddr = vm.computeCreateAddress(address(this), nonce);
        address insuranceAddr = vm.computeCreateAddress(address(this), nonce + 1);
        address triggerAddr = vm.computeCreateAddress(address(this), nonce + 2);

        escrowVault = new EscrowVault(hookAddr, triggerAddr, insuranceAddr, reputationAddr);
        insurancePool = new InsurancePool(hookAddr, triggerAddr, governance);
        triggerOracle = new TriggerOracle(hookAddr, escrowAddr, insuranceAddr, guardian, reputationAddr);

        // Deploy hook implementation and etch it at the correct address
        BastionHook impl =
            new BastionHook(manager, IEscrowVault(address(escrowVault)), insurancePool, triggerOracle, IReputationEngine(reputationAddr));
        vm.etch(hookAddr, address(impl).code);

        // After etch, the code is at hookAddr but storage is empty.
        // We need to re-deploy at the correct address. Use a different approach:
        // Store the immutables by deploying and copying full runtime bytecode including immutables
        // Since vm.etch only copies bytecode, we need to set storage manually for immutables.
        // Actually, Solidity immutables are embedded in the bytecode, so vm.etch should work.
        // But the constructor params are baked into the deployed bytecode, not impl's.
        // We need to re-create impl with the correct hookAddr as the deployment address.

        // Use deployCodeTo pattern instead:
        bytes memory creationCode = type(BastionHook).creationCode;
        bytes memory constructorArgs =
            abi.encode(address(manager), address(escrowVault), address(insurancePool), address(triggerOracle), reputationAddr);
        bytes memory bytecode = abi.encodePacked(creationCode, constructorArgs);

        address deployed;
        assembly {
            deployed := create(0, add(bytecode, 0x20), mload(bytecode))
        }
        // Copy the deployed code (with immutables baked in) to our flag address
        vm.etch(hookAddr, deployed.code);
        hook = BastionHook(payable(hookAddr));

        // Deploy tokens
        issuedToken = new MockERC20("Issued", "ISS", 18);
        baseToken = new MockERC20("Base", "BASE", 18);

        // Sort tokens for V4 pool
        (Currency c0, Currency c1) = SortTokens.sort(issuedToken, baseToken);
        currency0 = c0;
        currency1 = c1;

        // Mint tokens
        issuedToken.mint(issuerAddr, 1_000_000 ether);
        issuedToken.mint(address(this), 1_000_000 ether);
        baseToken.mint(issuerAddr, 1_000_000 ether);
        baseToken.mint(address(this), 1_000_000 ether);
        baseToken.mint(trader, 1_000_000 ether);
        issuedToken.mint(trader, 1_000_000 ether);

        // Approve routers
        issuedToken.approve(address(modifyLiquidityRouter), type(uint256).max);
        baseToken.approve(address(modifyLiquidityRouter), type(uint256).max);
        issuedToken.approve(address(swapRouter), type(uint256).max);
        baseToken.approve(address(swapRouter), type(uint256).max);

        // Approve for issuer
        vm.startPrank(issuerAddr);
        issuedToken.approve(address(hook), type(uint256).max);
        issuedToken.approve(address(modifyLiquidityRouter), type(uint256).max);
        baseToken.approve(address(modifyLiquidityRouter), type(uint256).max);
        vm.stopPrank();

        // Approve for trader
        vm.startPrank(trader);
        issuedToken.approve(address(swapRouter), type(uint256).max);
        baseToken.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    // ─── Helpers ──────────────────────────────────────────────────────

    function _defaultVestingSchedule() internal pure returns (IEscrowVault.VestingStep[] memory) {
        IEscrowVault.VestingStep[] memory schedule = new IEscrowVault.VestingStep[](3);
        schedule[0] = IEscrowVault.VestingStep({timeOffset: 7 days, basisPoints: 1000});
        schedule[1] = IEscrowVault.VestingStep({timeOffset: 30 days, basisPoints: 3000});
        schedule[2] = IEscrowVault.VestingStep({timeOffset: 90 days, basisPoints: 10000});
        return schedule;
    }

    function _defaultCommitment() internal pure returns (IEscrowVault.IssuerCommitment memory) {
        return IEscrowVault.IssuerCommitment({dailyWithdrawLimit: 0, lockDuration: 0, maxSellPercent: 200});
    }

    function _defaultTriggerConfig() internal pure returns (ITriggerOracle.TriggerConfig memory) {
        return ITriggerOracle.TriggerConfig({
            lpRemovalThreshold: 5000,
            dumpThresholdPercent: 3000,
            dumpWindowSeconds: 86400,
            taxDeviationThreshold: 500,
            slowRugWindowSeconds: 86400,
            slowRugCumulativeThreshold: 8000
        });
    }

    function _encodeIssuerHookData() internal view returns (bytes memory) {
        return abi.encode(
            issuerAddr,
            address(issuedToken),
            ESCROW_AMOUNT,
            _defaultVestingSchedule(),
            _defaultCommitment(),
            _defaultTriggerConfig()
        );
    }

    function _initPoolWithIssuer() internal returns (PoolKey memory _key, PoolId _poolId) {
        // Initialize pool
        uint24 fee = 3000;
        int24 tickSpacing = 60;
        _key = PoolKey(currency0, currency1, fee, tickSpacing, IHooks(address(hook)));
        _poolId = _key.toId();
        manager.initialize(_key, SQRT_PRICE_1_1);

        // Issuer adds first liquidity with hookData
        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e18, salt: 0});

        vm.prank(issuerAddr);
        modifyLiquidityRouter.modifyLiquidity(_key, params, _encodeIssuerHookData());

        poolKey = _key;
        poolId = _poolId;
    }

    // ═══════════════════════════════════════════════════════════════════
    //  POOL CREATION & ISSUER REGISTRATION
    // ═══════════════════════════════════════════════════════════════════

    function test_poolCreation_issuerRegistered() public {
        _initPoolWithIssuer();

        assertTrue(hook.isIssuer(poolId, issuerAddr));
        (address registeredIssuer,,,) = hook.getPoolInfo(poolId);
        assertEq(registeredIssuer, issuerAddr);
    }

    function test_poolCreation_escrowCreated() public {
        _initPoolWithIssuer();

        (, uint256 escrowId,,) = hook.getPoolInfo(poolId);
        assertGt(escrowId, 0);

        // EscrowVault should hold the escrowed tokens
        assertEq(issuedToken.balanceOf(address(escrowVault)), ESCROW_AMOUNT);
    }

    function test_poolCreation_triggerConfigSet() public {
        _initPoolWithIssuer();

        assertTrue(triggerOracle.isConfigSet(poolId));
        assertEq(triggerOracle.getPoolIssuer(poolId), issuerAddr);
    }

    function test_poolCreation_secondLPNotIssuer() public {
        _initPoolWithIssuer();

        // Second LP adds liquidity without hookData
        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e18, salt: bytes32(uint256(1))});

        modifyLiquidityRouter.modifyLiquidity(poolKey, params, "");

        // Issuer should still be the same
        assertTrue(hook.isIssuer(poolId, issuerAddr));
        assertFalse(hook.isIssuer(poolId, address(this)));
    }

    // ═══════════════════════════════════════════════════════════════════
    //  SWAP & INSURANCE FEE COLLECTION
    // ═══════════════════════════════════════════════════════════════════

    function test_swap_normalSwapWorks() public {
        _initPoolWithIssuer();

        // Add more liquidity so swaps work
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: -600,
            tickUpper: 600,
            liquidityDelta: 100e18,
            salt: bytes32(uint256(2))
        });
        modifyLiquidityRouter.modifyLiquidity(poolKey, params, "");

        // Trader swaps
        bool zeroForOne = true;
        int256 amountSpecified = -1e15; // exact input

        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        vm.prank(trader);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            settings,
            ""
        );
        // If we get here, swap succeeded without revert
    }

    // ═══════════════════════════════════════════════════════════════════
    //  LP REMOVAL & TRIGGER REPORTING
    // ═══════════════════════════════════════════════════════════════════

    function test_removeLiquidity_reportsToOracle() public {
        _initPoolWithIssuer();

        // Add more liquidity from test contract
        ModifyLiquidityParams memory addParams = ModifyLiquidityParams({
            tickLower: -120,
            tickUpper: 120,
            liquidityDelta: 10e18,
            salt: bytes32(uint256(3))
        });
        modifyLiquidityRouter.modifyLiquidity(poolKey, addParams, "");

        // Remove liquidity
        ModifyLiquidityParams memory removeParams = ModifyLiquidityParams({
            tickLower: -120,
            tickUpper: 120,
            liquidityDelta: -5e18,
            salt: bytes32(uint256(3))
        });
        modifyLiquidityRouter.modifyLiquidity(poolKey, removeParams, "");

        // Should not trigger (small removal)
        assertFalse(triggerOracle.checkTrigger(poolId).triggered);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  VESTING RELEASE FLOW
    // ═══════════════════════════════════════════════════════════════════

    function test_vestingRelease_afterFirstMilestone() public {
        _initPoolWithIssuer();

        (, uint256 escrowId,,) = hook.getPoolInfo(poolId);

        // Before vesting: 0
        assertEq(escrowVault.calculateVestedAmount(escrowId), 0);

        // Warp to 7 days
        vm.warp(block.timestamp + 7 days);

        // 10% should be vested
        uint256 vested = escrowVault.calculateVestedAmount(escrowId);
        assertEq(vested, 10 ether);

        // Release vested
        uint256 balanceBefore = issuedToken.balanceOf(issuerAddr);
        vm.prank(issuerAddr);
        escrowVault.releaseVested(escrowId);
        uint256 balanceAfter = issuedToken.balanceOf(issuerAddr);

        assertEq(balanceAfter - balanceBefore, 10 ether);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  TRIGGER SCENARIO
    // ═══════════════════════════════════════════════════════════════════

    function test_triggerScenario_commitmentBreach() public {
        _initPoolWithIssuer();

        (, uint256 escrowId,,) = hook.getPoolInfo(poolId);

        // Warp to 7 days, release partial
        vm.warp(block.timestamp + 7 days);
        vm.prank(issuerAddr);
        escrowVault.releaseVested(escrowId);

        uint256 issuedBalBefore = issuedToken.balanceOf(address(escrowVault));

        // Simulate commitment breach reported by hook
        vm.prank(address(hook));
        triggerOracle.reportCommitmentBreach(poolId);

        // Grace period
        vm.warp(block.timestamp + 1 hours);

        // Execute trigger
        triggerOracle.executeTrigger(poolId, bytes32(0));

        // Verify trigger activated
        assertTrue(triggerOracle.checkTrigger(poolId).triggered);

        // EscrowVault should have redistributed remaining
        IEscrowVault.EscrowStatus memory status = escrowVault.getEscrowStatus(escrowId);
        assertEq(status.remaining, 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  FULL FLOW TEST
    // ═══════════════════════════════════════════════════════════════════

    function test_fullFlow_createSwapVestTrigger() public {
        // 1. Create pool with issuer
        _initPoolWithIssuer();
        (, uint256 escrowId,,) = hook.getPoolInfo(poolId);
        assertTrue(hook.isIssuer(poolId, issuerAddr));
        assertEq(issuedToken.balanceOf(address(escrowVault)), ESCROW_AMOUNT);

        // 2. Add more liquidity (normal LP, no escrow)
        ModifyLiquidityParams memory addParams = ModifyLiquidityParams({
            tickLower: -600,
            tickUpper: 600,
            liquidityDelta: 100e18,
            salt: bytes32(uint256(10))
        });
        modifyLiquidityRouter.modifyLiquidity(poolKey, addParams, "");

        // 3. Swap (simulated normal trading)
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        vm.prank(trader);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -1e15, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            settings,
            ""
        );

        // 4. Vesting: warp to 30 days, release
        vm.warp(block.timestamp + 30 days);
        uint256 vested = escrowVault.calculateVestedAmount(escrowId);
        assertEq(vested, 30 ether); // 30%

        uint256 balBefore = issuedToken.balanceOf(issuerAddr);
        vm.prank(issuerAddr);
        escrowVault.releaseVested(escrowId);
        assertEq(issuedToken.balanceOf(issuerAddr) - balBefore, 30 ether); // 30% vested at 30 days

        // 5. Trigger scenario: simulate commitment breach
        vm.prank(address(hook));
        triggerOracle.reportCommitmentBreach(poolId);

        vm.warp(block.timestamp + 1 hours);
        triggerOracle.executeTrigger(poolId, bytes32(0));

        // 6. Verify final state
        assertTrue(triggerOracle.checkTrigger(poolId).triggered);
        IEscrowVault.EscrowStatus memory status = escrowVault.getEscrowStatus(escrowId);
        assertEq(status.released, 30 ether);
        assertEq(status.remaining, 0); // triggered, so remaining = 0
    }

    // ═══════════════════════════════════════════════════════════════════
    //  VIEW FUNCTION TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_getPoolInfo_returnsCorrectData() public {
        _initPoolWithIssuer();

        (address iss, uint256 eid, address issTkn, uint256 totalLiq) = hook.getPoolInfo(poolId);
        assertEq(iss, issuerAddr);
        assertGt(eid, 0);
        assertEq(issTkn, address(issuedToken));
        assertGt(totalLiq, 0);
    }

    function test_isIssuer_falseForNonIssuer() public {
        _initPoolWithIssuer();
        assertFalse(hook.isIssuer(poolId, trader));
    }

    function test_getHookPermissions() public view {
        Hooks.Permissions memory perms = hook.getHookPermissions();
        assertTrue(perms.beforeAddLiquidity);
        assertTrue(perms.beforeRemoveLiquidity);
        assertTrue(perms.afterSwap);
        assertFalse(perms.beforeSwap);
        assertFalse(perms.afterAddLiquidity);
        assertFalse(perms.afterRemoveLiquidity);
    }
}
