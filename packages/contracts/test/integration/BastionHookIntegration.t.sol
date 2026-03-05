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
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
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

    function setUp() public {
        issuerAddr = makeAddr("issuer");
        guardian = makeAddr("guardian");
        governance = makeAddr("governance");
        trader = makeAddr("trader");

        // Deploy V4 PoolManager and routers
        deployFreshManagerAndRouters();

        // Compute the hook address with correct permission bits
        uint160 flags =
            uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);

        address hookAddr = address(flags);

        // Deploy mock before nonce computation to avoid nonce mismatch
        MockReputationEngine mockReputation = new MockReputationEngine();
        address reputationAddr = address(mockReputation);

        // Pre-compute addresses to resolve circular dependency
        uint64 nonce = vm.getNonce(address(this));
        address escrowAddr = vm.computeCreateAddress(address(this), nonce);
        address insuranceAddr = vm.computeCreateAddress(address(this), nonce + 1);
        address triggerAddr = vm.computeCreateAddress(address(this), nonce + 2);

        escrowVault = new EscrowVault(hookAddr, triggerAddr, reputationAddr);
        insurancePool = new InsurancePool(hookAddr, triggerAddr, governance, escrowAddr, address(0));
        triggerOracle = new TriggerOracle(hookAddr, escrowAddr, insuranceAddr, guardian, reputationAddr);

        // Deploy hook implementation and etch it at the correct address
        bytes memory creationCode = type(BastionHook).creationCode;
        bytes memory constructorArgs =
            abi.encode(address(manager), address(escrowVault), address(insurancePool), address(triggerOracle), reputationAddr);
        bytes memory bytecode = abi.encodePacked(creationCode, constructorArgs);

        address deployed;
        assembly {
            deployed := create(0, add(bytecode, 0x20), mload(bytecode))
        }
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

        // Approve for issuer — no hook approval needed
        vm.startPrank(issuerAddr);
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

        // EscrowVault should hold NO tokens (LP permission model)
        assertEq(issuedToken.balanceOf(address(escrowVault)), 0);
        assertEq(address(escrowVault).balance, 0);

        // But should have recorded the liquidity
        IEscrowVault.EscrowStatus memory status = escrowVault.getEscrowStatus(escrowId);
        assertGt(status.totalLiquidity, 0);
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

        // Remove liquidity (non-issuer, different router)
        ModifyLiquidityParams memory removeParams = ModifyLiquidityParams({
            tickLower: -120,
            tickUpper: 120,
            liquidityDelta: -5e18,
            salt: bytes32(uint256(3))
        });
        modifyLiquidityRouter.modifyLiquidity(poolKey, removeParams, abi.encode(address(this)));

        // Should not trigger (small removal)
        assertFalse(triggerOracle.checkTrigger(poolId).triggered);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  VESTING & LP REMOVAL FLOW
    // ═══════════════════════════════════════════════════════════════════

    function test_vestingCalculation_afterFirstMilestone() public {
        _initPoolWithIssuer();

        (, uint256 escrowId,,) = hook.getPoolInfo(poolId);

        // Before vesting: 0
        assertEq(escrowVault.calculateVestedLiquidity(escrowId), 0);

        // Warp to 7 days
        vm.warp(block.timestamp + 7 days);

        // 10% should be vested
        uint128 vested = escrowVault.calculateVestedLiquidity(escrowId);
        assertGt(vested, 0);

        // getRemovableLiquidity should match
        uint128 removable = escrowVault.getRemovableLiquidity(escrowId);
        assertEq(removable, vested);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  TRIGGER SCENARIO
    // ═══════════════════════════════════════════════════════════════════

    function test_triggerScenario_commitmentBreach() public {
        _initPoolWithIssuer();

        (, uint256 escrowId,,) = hook.getPoolInfo(poolId);

        // Simulate commitment breach reported by hook
        vm.prank(address(hook));
        triggerOracle.reportCommitmentBreach(poolId);

        // Fallback path: grace + 24h deadline
        vm.warp(block.timestamp + 1 hours + 24 hours);

        // Execute trigger (permissionless)
        triggerOracle.executeTrigger(poolId);

        // Verify trigger activated
        assertTrue(triggerOracle.checkTrigger(poolId).triggered);

        // EscrowVault should have locked down (no LP removal allowed)
        assertEq(escrowVault.getRemovableLiquidity(escrowId), 0);

        IEscrowVault.EscrowStatus memory status = escrowVault.getEscrowStatus(escrowId);
        assertEq(status.remainingLiquidity, 0); // triggered, so remaining = 0
    }

    // ═══════════════════════════════════════════════════════════════════
    //  FULL FLOW TEST
    // ═══════════════════════════════════════════════════════════════════

    function test_fullFlow_createSwapVestTrigger() public {
        // 1. Create pool with issuer
        _initPoolWithIssuer();
        (, uint256 escrowId,,) = hook.getPoolInfo(poolId);
        assertTrue(hook.isIssuer(poolId, issuerAddr));
        // Vault holds no tokens
        assertEq(issuedToken.balanceOf(address(escrowVault)), 0);

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

        // 4. Vesting: warp to 30 days, check vested
        vm.warp(block.timestamp + 30 days);
        uint128 vested = escrowVault.calculateVestedLiquidity(escrowId);
        assertGt(vested, 0); // 30% should be vested

        // 5. Trigger scenario: simulate commitment breach
        vm.prank(address(hook));
        triggerOracle.reportCommitmentBreach(poolId);

        // Fallback path: grace + 24h deadline
        vm.warp(block.timestamp + 1 hours + 24 hours);
        triggerOracle.executeTrigger(poolId);

        // 6. Verify final state
        assertTrue(triggerOracle.checkTrigger(poolId).triggered);
        IEscrowVault.EscrowStatus memory status = escrowVault.getEscrowStatus(escrowId);
        assertEq(status.remainingLiquidity, 0); // triggered, so remaining = 0
        // removedLiquidity should still be 0 (no LP was actually removed before trigger)
        assertEq(status.removedLiquidity, 0);
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
        assertTrue(perms.beforeSwap);
        assertTrue(perms.afterSwap);
        assertFalse(perms.afterAddLiquidity);
        assertFalse(perms.afterRemoveLiquidity);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  ISSUER SALE DETECTION (covers _reportIssuerSale)
    // ═══════════════════════════════════════════════════════════════════

    function test_afterSwap_issuerSell_reportsToOracle() public {
        _initPoolWithIssuer();

        // Add deep liquidity so swaps work
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: -600,
            tickUpper: 600,
            liquidityDelta: 100e18,
            salt: bytes32(uint256(20))
        });
        modifyLiquidityRouter.modifyLiquidity(poolKey, params, "");

        // Issuer sells issued tokens
        address issuedAddr = address(issuedToken);
        bool issuedIsToken0 = Currency.unwrap(currency0) == issuedAddr;
        bool zeroForOne = issuedIsToken0;

        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        vm.startPrank(issuerAddr);
        issuedToken.approve(address(swapRouter), type(uint256).max);
        baseToken.approve(address(swapRouter), type(uint256).max);

        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -1e15,
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            settings,
            ""
        );
        vm.stopPrank();
    }

    function test_afterSwap_issuerBuy_doesNotReportSale() public {
        _initPoolWithIssuer();

        // Add deep liquidity
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: -600,
            tickUpper: 600,
            liquidityDelta: 100e18,
            salt: bytes32(uint256(21))
        });
        modifyLiquidityRouter.modifyLiquidity(poolKey, params, "");

        // Issuer buys issued tokens
        address issuedAddr = address(issuedToken);
        bool issuedIsToken0 = Currency.unwrap(currency0) == issuedAddr;
        bool zeroForOne = !issuedIsToken0;

        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        vm.startPrank(issuerAddr);
        issuedToken.approve(address(swapRouter), type(uint256).max);
        baseToken.approve(address(swapRouter), type(uint256).max);

        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -1e15,
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            settings,
            ""
        );
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════
    //  INSURANCE FEE COLLECTION BRANCHES
    // ═══════════════════════════════════════════════════════════════════

    function test_afterSwap_buyWithZeroFeeRate_noFeeCollected() public {
        _initPoolWithIssuer();

        // Set fee rate to 0
        vm.prank(governance);
        insurancePool.setFeeRate(0);

        // Add deep liquidity
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: -600,
            tickUpper: 600,
            liquidityDelta: 100e18,
            salt: bytes32(uint256(22))
        });
        modifyLiquidityRouter.modifyLiquidity(poolKey, params, "");

        // Buy issued token
        address issuedAddr = address(issuedToken);
        bool issuedIsToken0 = Currency.unwrap(currency0) == issuedAddr;
        bool zeroForOne = !issuedIsToken0;

        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        vm.prank(trader);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -1e15,
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            settings,
            ""
        );
    }

    function test_afterSwap_nonIssuerSell_noSaleReport() public {
        _initPoolWithIssuer();

        // Add deep liquidity
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: -600,
            tickUpper: 600,
            liquidityDelta: 100e18,
            salt: bytes32(uint256(23))
        });
        modifyLiquidityRouter.modifyLiquidity(poolKey, params, "");

        // Trader (non-issuer) sells issued tokens
        address issuedAddr = address(issuedToken);
        bool issuedIsToken0 = Currency.unwrap(currency0) == issuedAddr;
        bool zeroForOne = issuedIsToken0;

        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        vm.prank(trader);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -1e15,
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            settings,
            ""
        );
    }

    // ═══════════════════════════════════════════════════════════════════
    //  LP REMOVAL OVERFLOW PROTECTION
    // ═══════════════════════════════════════════════════════════════════

    function test_removeLiquidity_overflowProtection() public {
        _initPoolWithIssuer();

        // Add liquidity with different salt
        ModifyLiquidityParams memory addParams = ModifyLiquidityParams({
            tickLower: -120,
            tickUpper: 120,
            liquidityDelta: 2e18,
            salt: bytes32(uint256(30))
        });
        modifyLiquidityRouter.modifyLiquidity(poolKey, addParams, "");

        // Remove the added liquidity
        ModifyLiquidityParams memory removeParams = ModifyLiquidityParams({
            tickLower: -120,
            tickUpper: 120,
            liquidityDelta: -2e18,
            salt: bytes32(uint256(30))
        });
        modifyLiquidityRouter.modifyLiquidity(poolKey, removeParams, abi.encode(address(this)));
    }

    // ═══════════════════════════════════════════════════════════════════
    //  DIRECT afterSwap TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_afterSwap_directCall_issuerSell_reportsToOracle() public {
        _initPoolWithIssuer();

        address issuedAddr = address(issuedToken);
        bool issuedIsToken0 = Currency.unwrap(currency0) == issuedAddr;

        BalanceDelta delta;
        if (issuedIsToken0) {
            delta = toBalanceDelta(-1e15, 1e15);
        } else {
            delta = toBalanceDelta(1e15, -1e15);
        }

        SwapParams memory params = SwapParams({
            zeroForOne: issuedIsToken0,
            amountSpecified: -1e15,
            sqrtPriceLimitX96: issuedIsToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
        });

        vm.prank(address(manager));
        hook.afterSwap(issuerAddr, poolKey, params, delta, "");
    }

    function test_afterSwap_directCall_buySwap_collectsFee() public {
        _initPoolWithIssuer();

        address issuedAddr = address(issuedToken);
        bool issuedIsToken0 = Currency.unwrap(currency0) == issuedAddr;

        BalanceDelta delta;
        SwapParams memory params;

        if (issuedIsToken0) {
            delta = toBalanceDelta(1e15, -1e15);
            params = SwapParams({
                zeroForOne: false,
                amountSpecified: -1e15,
                sqrtPriceLimitX96: MAX_PRICE_LIMIT
            });
        } else {
            delta = toBalanceDelta(-1e15, 1e15);
            params = SwapParams({
                zeroForOne: true,
                amountSpecified: -1e15,
                sqrtPriceLimitX96: MIN_PRICE_LIMIT
            });
        }

        // Fund the hook with ETH for fee deposit
        vm.deal(address(hook), 1 ether);

        vm.prank(address(manager));
        hook.afterSwap(trader, poolKey, params, delta, "");
    }

    function test_afterSwap_directCall_feeAmountZero() public {
        _initPoolWithIssuer();

        vm.prank(governance);
        insurancePool.setFeeRate(1); // 0.01%

        address issuedAddr = address(issuedToken);
        bool issuedIsToken0 = Currency.unwrap(currency0) == issuedAddr;

        BalanceDelta delta;
        SwapParams memory params;

        if (issuedIsToken0) {
            delta = toBalanceDelta(100, -100);
            params = SwapParams({zeroForOne: false, amountSpecified: -100, sqrtPriceLimitX96: MAX_PRICE_LIMIT});
        } else {
            delta = toBalanceDelta(-100, 100);
            params = SwapParams({zeroForOne: true, amountSpecified: -100, sqrtPriceLimitX96: MIN_PRICE_LIMIT});
        }

        vm.prank(address(manager));
        hook.afterSwap(trader, poolKey, params, delta, "");
    }

    function test_beforeRemoveLiquidity_triggerOracleCallFails() public {
        _initPoolWithIssuer();

        // Pause the oracle
        vm.prank(guardian);
        triggerOracle.pause();

        // Add liquidity first
        ModifyLiquidityParams memory addParams = ModifyLiquidityParams({
            tickLower: -120,
            tickUpper: 120,
            liquidityDelta: 10e18,
            salt: bytes32(uint256(50))
        });
        modifyLiquidityRouter.modifyLiquidity(poolKey, addParams, "");

        // Remove liquidity - should trigger the catch branch
        ModifyLiquidityParams memory removeParams = ModifyLiquidityParams({
            tickLower: -120,
            tickUpper: 120,
            liquidityDelta: -5e18,
            salt: bytes32(uint256(50))
        });
        modifyLiquidityRouter.modifyLiquidity(poolKey, removeParams, abi.encode(address(this)));
    }

    function test_beforeRemoveLiquidity_overflowProtection_setsToZero() public {
        _initPoolWithIssuer();

        // Get current tracked liquidity
        (,,, uint256 totalLiq) = hook.getPoolInfo(poolId);
        assertGt(totalLiq, 0);

        // Directly call beforeRemoveLiquidity with removeAmount > totalLiquidity
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: -120,
            tickUpper: 120,
            liquidityDelta: -int256(totalLiq + 1e18),
            salt: 0
        });

        vm.prank(address(manager));
        hook.beforeRemoveLiquidity(address(this), poolKey, params, "");

        // totalLiquidity should be 0 (overflow protection)
        (,,, uint256 newTotalLiq) = hook.getPoolInfo(poolId);
        assertEq(newTotalLiq, 0);
    }

    function test_onlyPoolManager_reverts() public {
        _initPoolWithIssuer();

        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: -120,
            tickUpper: 120,
            liquidityDelta: 1e18,
            salt: 0
        });
        vm.expectRevert(BastionHook.OnlyPoolManager.selector);
        hook.beforeAddLiquidity(address(this), poolKey, params, "");
    }

    function test_afterSwap_noIssuedToken_skipsAll() public {
        // Create a pool without hookData (no issuer registered)
        uint24 fee = 3000;
        int24 tickSpacing = 60;
        PoolKey memory bareKey = PoolKey(currency0, currency1, fee, tickSpacing, IHooks(address(hook)));
        manager.initialize(bareKey, SQRT_PRICE_1_1);

        // Add liquidity without hookData
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: -600,
            tickUpper: 600,
            liquidityDelta: 100e18,
            salt: bytes32(uint256(40))
        });
        modifyLiquidityRouter.modifyLiquidity(bareKey, params, "");

        // Swap on pool with no issuer => skips all logic
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        vm.prank(trader);
        swapRouter.swap(
            bareKey,
            SwapParams({zeroForOne: true, amountSpecified: -1e15, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            settings,
            ""
        );
    }

    // ═══════════════════════════════════════════════════════════════════
    //  ISSUER DUMP DETECTION VIA ROUTER BYPASS
    // ═══════════════════════════════════════════════════════════════════

    function test_issuer_dump_detected_via_router() public {
        _initPoolWithIssuer();

        // Add deep liquidity
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: -600,
            tickUpper: 600,
            liquidityDelta: 100e18,
            salt: bytes32(uint256(60))
        });
        modifyLiquidityRouter.modifyLiquidity(poolKey, params, "");

        // Issuer transfers tokens to a router contract
        address routerProxy = makeAddr("routerProxy");

        vm.prank(issuerAddr);
        issuedToken.transfer(routerProxy, 500_000 ether);

        address issuedAddr = address(issuedToken);
        bool issuedIsToken0 = Currency.unwrap(currency0) == issuedAddr;

        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        vm.startPrank(routerProxy);
        issuedToken.approve(address(swapRouter), type(uint256).max);
        baseToken.approve(address(swapRouter), type(uint256).max);

        bool zeroForOne = issuedIsToken0;
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -1e15,
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            settings,
            ""
        );
        vm.stopPrank();
    }

    function test_non_issuer_swap_no_false_positive() public {
        _initPoolWithIssuer();

        // Add deep liquidity
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: -600,
            tickUpper: 600,
            liquidityDelta: 100e18,
            salt: bytes32(uint256(61))
        });
        modifyLiquidityRouter.modifyLiquidity(poolKey, params, "");

        uint256 issuerBalBefore = issuedToken.balanceOf(issuerAddr);

        address issuedAddr = address(issuedToken);
        bool issuedIsToken0 = Currency.unwrap(currency0) == issuedAddr;

        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        vm.prank(trader);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: issuedIsToken0,
                amountSpecified: -1e15,
                sqrtPriceLimitX96: issuedIsToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            settings,
            ""
        );

        uint256 issuerBalAfter = issuedToken.balanceOf(issuerAddr);
        assertEq(issuerBalAfter, issuerBalBefore);
    }
}
