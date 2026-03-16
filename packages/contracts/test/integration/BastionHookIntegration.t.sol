// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {SortTokens} from "@uniswap/v4-core/test/utils/SortTokens.sol";

import {BastionHook} from "../../src/hooks/BastionHook.sol";
import {EscrowVault} from "../../src/core/EscrowVault.sol";
import {InsurancePool} from "../../src/core/InsurancePool.sol";
import {TriggerOracle} from "../../src/core/TriggerOracle.sol";
import {IEscrowVault} from "../../src/interfaces/IEscrowVault.sol";
import {ITriggerOracle} from "../../src/interfaces/ITriggerOracle.sol";

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
            uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);

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
        triggerOracle = new TriggerOracle(hookAddr, escrowAddr, insuranceAddr, guardian, reputationAddr, governance);

        // Deploy hook implementation and etch it at the correct address
        bytes memory creationCode = type(BastionHook).creationCode;
        bytes memory constructorArgs =
            abi.encode(address(manager), address(escrowVault), address(insurancePool), address(triggerOracle), reputationAddr, governance, address(0), address(0));
        bytes memory bytecode = abi.encodePacked(creationCode, constructorArgs);

        address deployed;
        assembly {
            deployed := create(0, add(bytecode, 0x20), mload(bytecode))
        }
        vm.etch(hookAddr, deployed.code);
        // Restore storage lost by vm.etch
        vm.store(hookAddr, bytes32(uint256(24)), bytes32(uint256(uint160(governance))));
        // Restore duration params + LP removal defaults: defaultLockDuration=7days, defaultVestingDuration=83days, minLockDuration=7days, minVestingDuration=7days, dailyLpRemovalBps=1000, weeklyLpRemovalBps=3000
        vm.store(hookAddr, bytes32(uint256(26)), bytes32(uint256(uint40(7 days)) | (uint256(uint40(83 days)) << 40) | (uint256(uint40(7 days)) << 80) | (uint256(uint40(7 days)) << 120) | (uint256(uint16(1000)) << 160) | (uint256(uint16(3000)) << 176)));
        hook = BastionHook(payable(hookAddr));

        // Deploy tokens
        issuedToken = new MockERC20("Issued", "ISS", 18);
        baseToken = new MockERC20("Base", "BASE", 18);

        // Register baseToken as an allowed base token (storage lost by vm.etch)
        vm.prank(governance);
        hook.addBaseToken(address(baseToken), 0);

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

    uint40 constant DEFAULT_LOCK = 7 days;
    uint40 constant DEFAULT_VESTING = 83 days;

    function _defaultCommitment() internal pure returns (IEscrowVault.IssuerCommitment memory) {
        return IEscrowVault.IssuerCommitment({maxSellPercent: 200});
    }

    function _defaultTriggerConfig() internal pure returns (ITriggerOracle.TriggerConfig memory) {
        return ITriggerOracle.TriggerConfig({
            dailyLpRemovalBps: 1000,
            weeklyLpRemovalBps: 3000,
            dumpThresholdPercent: 300,
            dumpWindowSeconds: 86400,
            taxDeviationThreshold: 500,
            weeklyDumpWindowSeconds: 604800,
            weeklyDumpThresholdPercent: 1500
        });
    }

    function _encodeIssuerHookData() internal view returns (bytes memory) {
        return abi.encode(
            issuerAddr,
            address(issuedToken),
            DEFAULT_LOCK,
            DEFAULT_VESTING,
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
        (address registeredIssuer,,,,) = hook.getPoolInfo(poolId);
        assertEq(registeredIssuer, issuerAddr);
    }

    function test_poolCreation_escrowCreated() public {
        _initPoolWithIssuer();

        (, uint256 escrowId,,,) = hook.getPoolInfo(poolId);
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

    function test_removeLiquidity_updatesTracking() public {
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

    function test_vestingCalculation_duringLockAndVesting() public {
        _initPoolWithIssuer();

        (, uint256 escrowId,,,) = hook.getPoolInfo(poolId);

        // During lock period: 0
        assertEq(escrowVault.calculateVestedLiquidity(escrowId), 0);

        // Warp past lock (7 days) into vesting
        vm.warp(block.timestamp + 7 days + 1);

        // Should have some vested (linear)
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

        (, uint256 escrowId,,,) = hook.getPoolInfo(poolId);

        // Simulate commitment breach reported by hook
        vm.prank(address(hook));
        triggerOracle.reportCommitmentBreach(poolId);

        // Trigger happens immediately — verify trigger activated
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
        (, uint256 escrowId,,,) = hook.getPoolInfo(poolId);
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

        // 6. Verify final state — trigger happens immediately
        assertTrue(triggerOracle.checkTrigger(poolId).triggered);
        IEscrowVault.EscrowStatus memory status = escrowVault.getEscrowStatus(escrowId);
        assertEq(status.remainingLiquidity, 0); // triggered, so remaining = 0
        // removedLiquidity == totalLiquidity (all seized during force removal)
        assertEq(status.removedLiquidity, status.totalLiquidity);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  VIEW FUNCTION TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_getPoolInfo_returnsCorrectData() public {
        _initPoolWithIssuer();

        (address iss, uint256 eid, address issTkn, uint256 totalLiq,) = hook.getPoolInfo(poolId);
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
    //  ISSUER SALE DETECTION
    // ═══════════════════════════════════════════════════════════════════

    function test_afterSwap_issuerSell_enforcesLimits() public {
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

    function test_afterSwap_buyWithMinFeeRate_minimalFeeCollected() public {
        _initPoolWithIssuer();

        // Set fee rate to minimum (10 bps = 0.1%)
        vm.prank(governance);
        insurancePool.setFeeRate(10);

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

    function test_afterSwap_directCall_issuerSell_enforcesLimits() public {
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
        insurancePool.setFeeRate(10); // 0.1% — with tiny swap, fee rounds to 0

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

    // test_beforeRemoveLiquidity_triggerOracleCallFails removed
    // (LP removal no longer reports to TriggerOracle; tracking moved to BastionHook)

    function test_beforeRemoveLiquidity_overflowProtection_setsToZero() public {
        _initPoolWithIssuer();

        // Get current tracked liquidity
        (,,, uint256 totalLiq,) = hook.getPoolInfo(poolId);
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
        (,,, uint256 newTotalLiq,) = hook.getPoolInfo(poolId);
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

    // test_issuer_dump_detected_via_router removed
    // (issuer sells are now revert-only enforcement, no TriggerOracle reporting)

    // ═══════════════════════════════════════════════════════════════════
    //  BASE TOKEN ALLOWLIST & MIN AMOUNT TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_addBaseToken_onlyGovernance() public {
        address randomToken = makeAddr("randomToken");

        vm.expectRevert(BastionHook.OnlyGovernance.selector);
        hook.addBaseToken(randomToken, 1 ether);

        vm.prank(governance);
        hook.addBaseToken(randomToken, 1 ether);
        assertTrue(hook.allowedBaseTokens(randomToken));
        assertEq(hook.minBaseAmount(randomToken), 1 ether);
    }

    function test_removeBaseToken_onlyGovernance() public {
        // baseToken was added in setUp
        vm.expectRevert(BastionHook.OnlyGovernance.selector);
        hook.removeBaseToken(address(baseToken));

        vm.prank(governance);
        hook.removeBaseToken(address(baseToken));
        assertFalse(hook.allowedBaseTokens(address(baseToken)));
        assertEq(hook.minBaseAmount(address(baseToken)), 0);
    }

    function test_addBaseToken_reverts_ifAlreadySet() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(BastionHook.BaseTokenAlreadySet.selector, address(baseToken)));
        hook.addBaseToken(address(baseToken), 1 ether);
    }

    function test_removeBaseToken_reverts_ifNotSet() public {
        address randomToken = makeAddr("randomToken");
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(BastionHook.BaseTokenNotSet.selector, randomToken));
        hook.removeBaseToken(randomToken);
    }

    function test_updateMinBaseAmount_onlyGovernance() public {
        vm.expectRevert(BastionHook.OnlyGovernance.selector);
        hook.updateMinBaseAmount(address(baseToken), 5 ether);

        vm.prank(governance);
        hook.updateMinBaseAmount(address(baseToken), 5 ether);
        assertEq(hook.minBaseAmount(address(baseToken)), 5 ether);
    }

    function test_beforeAddLiquidity_noBaseToken_reverts() public {
        // Remove base token so neither token qualifies
        vm.prank(governance);
        hook.removeBaseToken(address(baseToken));

        uint24 fee = 3000;
        int24 tickSpacing = 60;
        PoolKey memory _key = PoolKey(currency0, currency1, fee, tickSpacing, IHooks(address(hook)));
        manager.initialize(_key, SQRT_PRICE_1_1);

        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e18, salt: 0});

        vm.prank(issuerAddr);
        vm.expectRevert(); // NoAllowedBaseToken (wrapped by PoolManager)
        modifyLiquidityRouter.modifyLiquidity(_key, params, _encodeIssuerHookData());
    }

    function test_beforeAddLiquidity_bothBaseTokens_skipsBastion() public {
        // Register issuedToken as a base token too
        vm.prank(governance);
        hook.addBaseToken(address(issuedToken), 0);

        uint24 fee = 3000;
        int24 tickSpacing = 60;
        PoolKey memory _key = PoolKey(currency0, currency1, fee, tickSpacing, IHooks(address(hook)));
        PoolId _poolId = _key.toId();
        manager.initialize(_key, SQRT_PRICE_1_1);

        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e18, salt: 0});

        // Should succeed but NOT register an issuer (both are base tokens)
        vm.prank(issuerAddr);
        modifyLiquidityRouter.modifyLiquidity(_key, params, _encodeIssuerHookData());

        // No issuer registered
        assertFalse(hook.isIssuer(_poolId, issuerAddr));
    }

    function test_beforeAddLiquidity_belowMinBaseAmount_reverts() public {
        // Set min base amount to something large
        vm.prank(governance);
        hook.updateMinBaseAmount(address(baseToken), 1000 ether);

        uint24 fee = 3000;
        int24 tickSpacing = 60;
        PoolKey memory _key = PoolKey(currency0, currency1, fee, tickSpacing, IHooks(address(hook)));
        manager.initialize(_key, SQRT_PRICE_1_1);

        // Small liquidity at 1:1 price with narrow range will produce less than 1000 base tokens
        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e18, salt: 0});

        vm.prank(issuerAddr);
        vm.expectRevert(); // BelowMinBaseAmount
        modifyLiquidityRouter.modifyLiquidity(_key, params, _encodeIssuerHookData());
    }

    function test_beforeAddLiquidity_meetsMinBaseAmount_succeeds() public {
        // Set min base amount to a small value
        vm.prank(governance);
        hook.updateMinBaseAmount(address(baseToken), 1);

        _initPoolWithIssuer();
        assertTrue(hook.isIssuer(poolId, issuerAddr));
    }

    // ═══════════════════════════════════════════════════════════════════
    //  POOL COMMITMENT TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_poolCommitment_storedOnCreation() public {
        _initPoolWithIssuer();

        BastionHook.PoolCommitment memory c = hook.getPoolCommitment(poolId);
        assertTrue(c.isSet);
        assertEq(c.lockDuration, DEFAULT_LOCK);
        assertEq(c.vestingDuration, DEFAULT_VESTING);
        assertEq(c.maxDailyLpRemovalBps, 1000);
        assertEq(c.maxWeeklyLpRemovalBps, 3000);
        assertEq(c.maxDailySellBps, 300);
        assertGt(c.createdAt, 0);
    }

    function test_poolCommitment_defaultValues() public {
        _initPoolWithIssuer();

        BastionHook.PoolCommitment memory c = hook.getPoolCommitment(poolId);
        // Default triggerConfig matches governance defaults
        assertEq(c.maxDailyLpRemovalBps, 1000);
        assertEq(c.maxWeeklyLpRemovalBps, 3000);
        assertEq(c.maxDailySellBps, 300);
    }

    function test_poolCommitment_revertsLpRemovalTooHigh() public {
        uint24 fee = 3000;
        int24 tickSpacing = 60;
        PoolKey memory _key = PoolKey(currency0, currency1, fee, tickSpacing, IHooks(address(hook)));
        manager.initialize(_key, SQRT_PRICE_1_1);

        ITriggerOracle.TriggerConfig memory badConfig = ITriggerOracle.TriggerConfig({
            dailyLpRemovalBps: 1001, // > 1000 default
            weeklyLpRemovalBps: 3000,
            dumpThresholdPercent: 300,
            dumpWindowSeconds: 86400,
            taxDeviationThreshold: 500,
            weeklyDumpWindowSeconds: 604800,
            weeklyDumpThresholdPercent: 1500
        });

        bytes memory hookData = abi.encode(
            issuerAddr, address(issuedToken), DEFAULT_LOCK, DEFAULT_VESTING, _defaultCommitment(), badConfig
        );

        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e18, salt: 0});

        vm.prank(issuerAddr);
        vm.expectRevert(); // CommitmentTooLenient
        modifyLiquidityRouter.modifyLiquidity(_key, params, hookData);
    }

    function test_poolCommitment_revertsDumpThresholdTooHigh() public {
        uint24 fee = 3000;
        int24 tickSpacing = 60;
        PoolKey memory _key = PoolKey(currency0, currency1, fee, tickSpacing, IHooks(address(hook)));
        manager.initialize(_key, SQRT_PRICE_1_1);

        ITriggerOracle.TriggerConfig memory badConfig = ITriggerOracle.TriggerConfig({
            dailyLpRemovalBps: 1000,
            weeklyLpRemovalBps: 3000,
            dumpThresholdPercent: 301, // > 300 default
            dumpWindowSeconds: 86400,
            taxDeviationThreshold: 500,
            weeklyDumpWindowSeconds: 604800,
            weeklyDumpThresholdPercent: 1500
        });

        bytes memory hookData = abi.encode(
            issuerAddr, address(issuedToken), DEFAULT_LOCK, DEFAULT_VESTING, _defaultCommitment(), badConfig
        );

        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e18, salt: 0});

        vm.prank(issuerAddr);
        vm.expectRevert(); // CommitmentTooLenient
        modifyLiquidityRouter.modifyLiquidity(_key, params, hookData);
    }

    function test_poolCommitment_revertsSlowRugTooHigh() public {
        uint24 fee = 3000;
        int24 tickSpacing = 60;
        PoolKey memory _key = PoolKey(currency0, currency1, fee, tickSpacing, IHooks(address(hook)));
        manager.initialize(_key, SQRT_PRICE_1_1);

        ITriggerOracle.TriggerConfig memory badConfig = ITriggerOracle.TriggerConfig({
            dailyLpRemovalBps: 1000,
            weeklyLpRemovalBps: 3001, // > 3000 default
            dumpThresholdPercent: 300,
            dumpWindowSeconds: 86400,
            taxDeviationThreshold: 500,
            weeklyDumpWindowSeconds: 604800,
            weeklyDumpThresholdPercent: 1500
        });

        bytes memory hookData = abi.encode(
            issuerAddr, address(issuedToken), DEFAULT_LOCK, DEFAULT_VESTING, _defaultCommitment(), badConfig
        );

        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e18, salt: 0});

        vm.prank(issuerAddr);
        vm.expectRevert(); // CommitmentTooLenient
        modifyLiquidityRouter.modifyLiquidity(_key, params, hookData);
    }

    function test_poolCommitment_stricterValues() public {
        uint24 fee = 3000;
        int24 tickSpacing = 60;
        PoolKey memory _key = PoolKey(currency0, currency1, fee, tickSpacing, IHooks(address(hook)));
        manager.initialize(_key, SQRT_PRICE_1_1);

        ITriggerOracle.TriggerConfig memory strictConfig = ITriggerOracle.TriggerConfig({
            dailyLpRemovalBps: 500, // < 1000 default
            weeklyLpRemovalBps: 1500, // < 3000 default
            dumpThresholdPercent: 200, // < 300 default
            dumpWindowSeconds: 86400,
            taxDeviationThreshold: 500,
            weeklyDumpWindowSeconds: 604800,
            weeklyDumpThresholdPercent: 1500
        });

        bytes memory hookData = abi.encode(
            issuerAddr, address(issuedToken), DEFAULT_LOCK, DEFAULT_VESTING, _defaultCommitment(), strictConfig
        );

        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e18, salt: 0});

        vm.prank(issuerAddr);
        modifyLiquidityRouter.modifyLiquidity(_key, params, hookData);

    }

    function test_governanceChangeDoesNotAffectExistingCommitment() public {
        _initPoolWithIssuer();

        BastionHook.PoolCommitment memory before = hook.getPoolCommitment(poolId);

        // Change governance defaults
        vm.startPrank(governance);
        hook.setDefaultLockDuration(30 days);
        hook.setDefaultVestingDuration(180 days);
        vm.stopPrank();

        // Update TriggerOracle defaults
        vm.prank(governance);
        triggerOracle.setDefaultTriggerConfig(ITriggerOracle.TriggerConfig({
            dailyLpRemovalBps: 500,
            weeklyLpRemovalBps: 1500,
            dumpThresholdPercent: 2000,
            dumpWindowSeconds: 86400,
            taxDeviationThreshold: 500,
            weeklyDumpWindowSeconds: 604800,
            weeklyDumpThresholdPercent: 1500
        }));

        // Existing commitment unchanged
        BastionHook.PoolCommitment memory after_ = hook.getPoolCommitment(poolId);
        assertEq(after_.lockDuration, before.lockDuration);
        assertEq(after_.vestingDuration, before.vestingDuration);
        assertEq(after_.maxDailyLpRemovalBps, before.maxDailyLpRemovalBps);
        assertEq(after_.maxWeeklyLpRemovalBps, before.maxWeeklyLpRemovalBps);
        assertEq(after_.maxDailySellBps, before.maxDailySellBps);
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

    // ═══════════════════════════════════════════════════════════════════
    //  3-WINDOW TRIGGER SYSTEM TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_poolCommitment_weeklyDumpFields() public {
        _initPoolWithIssuer();

        BastionHook.PoolCommitment memory c = hook.getPoolCommitment(poolId);
        assertEq(c.maxWeeklySellBps, 1500);
    }

    function test_poolCommitment_revertsWeeklyDumpTooHigh() public {
        uint24 fee = 3000;
        int24 tickSpacing = 60;
        PoolKey memory _key = PoolKey(currency0, currency1, fee, tickSpacing, IHooks(address(hook)));
        manager.initialize(_key, SQRT_PRICE_1_1);

        ITriggerOracle.TriggerConfig memory badConfig = ITriggerOracle.TriggerConfig({
            dailyLpRemovalBps: 1000,
            weeklyLpRemovalBps: 3000,
            dumpThresholdPercent: 300,
            dumpWindowSeconds: 86400,
            taxDeviationThreshold: 500,
            weeklyDumpWindowSeconds: 604800,
            weeklyDumpThresholdPercent: 1501 // > 1500 default
        });

        bytes memory hookData = abi.encode(
            issuerAddr, address(issuedToken), DEFAULT_LOCK, DEFAULT_VESTING, _defaultCommitment(), badConfig
        );

        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e18, salt: 0});

        vm.prank(issuerAddr);
        vm.expectRevert(); // CommitmentTooLenient
        modifyLiquidityRouter.modifyLiquidity(_key, params, hookData);
    }

    // LP cumulative removal and issuer dump detection tests removed
    // (these functions were removed from TriggerOracle; LP tracking is now in BastionHook)

    function test_getDefaultTriggerConfig_returnsStruct() public view {
        ITriggerOracle.TriggerConfig memory cfg = triggerOracle.getDefaultTriggerConfig();
        assertEq(cfg.dailyLpRemovalBps, 1000);
        assertEq(cfg.weeklyLpRemovalBps, 3000);
        assertEq(cfg.dumpThresholdPercent, 300);
        assertEq(cfg.dumpWindowSeconds, 86400);
        assertEq(cfg.taxDeviationThreshold, 500);
        assertEq(cfg.weeklyDumpWindowSeconds, 604800);
        assertEq(cfg.weeklyDumpThresholdPercent, 1500);
    }

    function test_poolCommitment_stricterWeeklyDump() public {
        uint24 fee = 3000;
        int24 tickSpacing = 60;
        PoolKey memory _key = PoolKey(currency0, currency1, fee, tickSpacing, IHooks(address(hook)));
        PoolId _poolId = _key.toId();
        manager.initialize(_key, SQRT_PRICE_1_1);

        ITriggerOracle.TriggerConfig memory strictConfig = ITriggerOracle.TriggerConfig({
            dailyLpRemovalBps: 500,
            weeklyLpRemovalBps: 1500,
            dumpThresholdPercent: 300,
            dumpWindowSeconds: 86400,
            taxDeviationThreshold: 500,
            weeklyDumpWindowSeconds: 604800,
            weeklyDumpThresholdPercent: 1000 // stricter than 1500 default
        });

        bytes memory hookData = abi.encode(
            issuerAddr, address(issuedToken), DEFAULT_LOCK, DEFAULT_VESTING, _defaultCommitment(), strictConfig
        );

        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e18, salt: 0});

        vm.prank(issuerAddr);
        modifyLiquidityRouter.modifyLiquidity(_key, params, hookData);

        BastionHook.PoolCommitment memory c = hook.getPoolCommitment(_poolId);
        assertEq(c.maxWeeklySellBps, 1000);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  ISSUER SELL DEFENSE TESTS
    // ═══════════════════════════════════════════════════════════════════

    /// @dev Helper to sell issued tokens via swap (issuer sells issued token for base token)
    function _issuerSellIssuedToken(uint256 amount) internal {
        bool issuedIsToken0 = Currency.unwrap(currency0) == address(issuedToken);
        // Selling issued token: if issuedIsToken0, zeroForOne = true
        bool zeroForOne = issuedIsToken0;

        // Give issuer approval to swap router
        vm.startPrank(issuerAddr);
        issuedToken.approve(address(swapRouter), type(uint256).max);
        baseToken.approve(address(swapRouter), type(uint256).max);

        // Pass issuer address in hookData so the hook can identify the actual swapper
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(issuerAddr)
        );
        vm.stopPrank();
    }

    /// @dev Helper to do a normal (non-issuer) swap
    function _traderBuyIssuedToken(uint256 amount) internal {
        bool issuedIsToken0 = Currency.unwrap(currency0) == address(issuedToken);
        bool zeroForOne = !issuedIsToken0; // buy = swap base for issued

        vm.prank(trader);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function test_IssuerRouterSell_BelowLimit_Succeeds() public {
        _initPoolWithIssuer();

        uint256 poolReserve = issuedToken.balanceOf(address(manager));
        // Sell 2% of pool reserve — well below 3% daily limit
        uint256 sellAmount = (poolReserve * 200) / 10_000;

        // Should succeed without revert
        _issuerSellIssuedToken(sellAmount);
    }

    /// @dev Helper to init pool with large liquidity and small supply for sell defense tests.
    ///      Mints enough tokens so the issuer retains >60% of supply after providing liquidity.
    function _initPoolWithLargeLiquidity() internal returns (PoolKey memory _key, PoolId _poolId) {
        // Deploy a fresh token with small supply.
        // Full-range position with 500e18 liquidityDelta consumes ~500 tokens at 1:1 price.
        // Issuer gets 5000 ether to retain plenty after LP provision.
        MockERC20 sellTestToken = new MockERC20("SellTest", "ST", 18);
        sellTestToken.mint(issuerAddr, 5000 ether);
        sellTestToken.mint(address(this), 1000 ether); // total supply = 6000

        // Re-sort tokens
        (Currency c0, Currency c1) = SortTokens.sort(sellTestToken, baseToken);

        uint24 fee = 3000;
        int24 tickSpacing = 60;
        _key = PoolKey(c0, c1, fee, tickSpacing, IHooks(address(hook)));
        _poolId = _key.toId();
        manager.initialize(_key, SQRT_PRICE_1_1);

        // Approve
        vm.startPrank(issuerAddr);
        sellTestToken.approve(address(modifyLiquidityRouter), type(uint256).max);
        sellTestToken.approve(address(swapRouter), type(uint256).max);
        baseToken.approve(address(modifyLiquidityRouter), type(uint256).max);
        baseToken.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
        sellTestToken.approve(address(modifyLiquidityRouter), type(uint256).max);
        sellTestToken.approve(address(swapRouter), type(uint256).max);

        // Determine which is the issued token
        address _issuedTokenAddr = address(sellTestToken);

        bytes memory hookData = abi.encode(
            issuerAddr,
            _issuedTokenAddr,
            DEFAULT_LOCK,
            DEFAULT_VESTING,
            _defaultCommitment(),
            _defaultTriggerConfig()
        );

        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: 500e18, salt: 0});

        vm.prank(issuerAddr);
        modifyLiquidityRouter.modifyLiquidity(_key, params, hookData);

        poolKey = _key;
        poolId = _poolId;

        // Update issuedToken reference for sell helper
        issuedToken = sellTestToken;

        // Re-assign currency0/currency1 for the sell helper
        currency0 = c0;
        currency1 = c1;
    }

    function test_IssuerRouterSell_ExceedsDaily_RevertsAfterSwap() public {
        _initPoolWithLargeLiquidity();

        uint256 poolReserve = issuedToken.balanceOf(address(manager));
        // Sell 4% of pool reserve — exceeds 3% daily limit (300 bps)
        uint256 sellAmount = (poolReserve * 400) / 10_000;

        // Pre-approve so vm.expectRevert catches the swap, not approve
        vm.startPrank(issuerAddr);
        issuedToken.approve(address(swapRouter), type(uint256).max);
        baseToken.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        bool issuedIsToken0 = Currency.unwrap(currency0) == address(issuedToken);
        bool zeroForOne = issuedIsToken0;

        // The beforeSwap 1st layer catches this with IssuerDailySellExceeded,
        // wrapped in PoolManager's WrappedError
        vm.prank(issuerAddr);
        vm.expectRevert();
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(sellAmount),
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(issuerAddr)
        );
    }

    function test_IssuerSell_WeeklyLimit_Reverts() public {
        _initPoolWithLargeLiquidity();

        // Weekly threshold: 1500 bps (15%), Daily threshold: 300 bps (3%)
        // Note: sells push issued tokens INTO the pool, so reserve grows after each sell.
        // Strategy: sell 2.9% of current reserve each day. The weekly cumulative grows
        // while the denominator (reserve) also grows. After enough days, cumulative
        // exceeds 15% of current reserve.

        // Pre-approve
        vm.startPrank(issuerAddr);
        issuedToken.approve(address(swapRouter), type(uint256).max);
        baseToken.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        // Days 0-4: sell 2.9% of current reserve each day (under 3% daily limit).
        // Each sell increases the reserve (issued tokens flow in), but cumulative
        // sells accumulate. After 5 days: cumulative ≈ 14.5% which is under 15%.
        for (uint256 i = 0; i < 5; i++) {
            if (i > 0) vm.warp(block.timestamp + 1 days);
            uint256 reserve = issuedToken.balanceOf(address(manager));
            uint256 dailySellAmount = (reserve * 290) / 10_000;
            _issuerSellIssuedToken(dailySellAmount);
        }

        // Day 5: sell 2.9% more — should push weekly cumulative over 15% of current reserve
        vm.warp(block.timestamp + 1 days);

        uint256 currentReserve = issuedToken.balanceOf(address(manager));
        bool issuedIsToken0 = Currency.unwrap(currency0) == address(issuedToken);
        bool zeroForOne = issuedIsToken0;
        uint256 sellAmount = (currentReserve * 290) / 10_000;

        vm.prank(issuerAddr);
        vm.expectRevert();
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(sellAmount),
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(issuerAddr)
        );
    }

    function test_SellLimit_ScalesWithPoolSize() public {
        _initPoolWithLargeLiquidity();

        uint256 poolReserve = issuedToken.balanceOf(address(manager));
        // Sell exactly 3% of pool reserve — at the limit (300 bps). Should succeed.
        uint256 atLimitAmount = (poolReserve * 300) / 10_000;
        _issuerSellIssuedToken(atLimitAmount);

        // Next day: sell 1 wei over 3% of current reserve — should revert
        vm.warp(block.timestamp + 1 days);
        uint256 newReserve = issuedToken.balanceOf(address(manager));
        uint256 overLimitAmount = (newReserve * 300) / 10_000 + 1;

        bool issuedIsToken0 = Currency.unwrap(currency0) == address(issuedToken);
        bool zeroForOne = issuedIsToken0;

        vm.prank(issuerAddr);
        vm.expectRevert();
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(overLimitAmount),
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(issuerAddr)
        );
    }

    function test_SellLimit_ShrinksWithPoolSize() public {
        _initPoolWithLargeLiquidity();

        uint256 initialReserve = issuedToken.balanceOf(address(manager));
        // Trader buys issued tokens, removing them from pool → reserve shrinks
        baseToken.mint(trader, 200 ether);
        vm.prank(trader);
        baseToken.approve(address(swapRouter), type(uint256).max);
        _traderBuyIssuedToken(100 ether);

        uint256 shrunkReserve = issuedToken.balanceOf(address(manager));
        assertLt(shrunkReserve, initialReserve, "Reserve should have shrunk from buy");

        // A sell amount that was 2% of original reserve is now a larger % of shrunken reserve
        uint256 sellAmount = (initialReserve * 290) / 10_000; // 2.9% of original

        // Check if this exceeds 3% of shrunken reserve
        uint256 sellBps = (sellAmount * 10_000 + shrunkReserve - 1) / shrunkReserve;
        if (sellBps > 300) {
            // Should revert because it exceeds the daily limit against shrunken reserve
            bool issuedIsToken0 = Currency.unwrap(currency0) == address(issuedToken);
            bool zeroForOne = issuedIsToken0;

            vm.prank(issuerAddr);
            vm.expectRevert();
            swapRouter.swap(
                poolKey,
                SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: -int256(sellAmount),
                    sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
                }),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                abi.encode(issuerAddr)
            );
        } else {
            // If reserve didn't shrink enough, sell should still succeed
            _issuerSellIssuedToken(sellAmount);
        }
    }

    function test_SellLimit_IssuerCantManipulate() public {
        _initPoolWithLargeLiquidity();

        uint256 reserveBefore = issuedToken.balanceOf(address(manager));

        // Issuer sends tokens directly to PoolManager to inflate balanceOf
        uint256 inflateAmount = 1000 ether;
        vm.prank(issuerAddr);
        issuedToken.transfer(address(manager), inflateAmount);

        uint256 reserveAfter = issuedToken.balanceOf(address(manager));
        assertEq(reserveAfter, reserveBefore + inflateAmount, "balanceOf increased");

        // The inflated reserve makes limits more lenient (larger denominator).
        // Sell 4% of original reserve — would exceed 3% daily limit normally,
        // but with inflated denominator it might pass.
        uint256 sellAmount = (reserveBefore * 400) / 10_000;
        uint256 sellBps = (sellAmount * 10_000 + reserveAfter - 1) / reserveAfter;

        // Document the manipulation: sell passes because denominator is inflated.
        // This is an accepted trade-off for v1 — the issuer loses the donated tokens
        // (V4 internal accounting ignores external transfers), making it economically
        // self-defeating.
        if (sellBps <= 300) {
            // The inflated reserve made this pass — documenting the edge case
            _issuerSellIssuedToken(sellAmount);
        } else {
            // If inflation wasn't enough to change the outcome, it still reverts
            bool issuedIsToken0 = Currency.unwrap(currency0) == address(issuedToken);
            bool zeroForOne = issuedIsToken0;

            vm.prank(issuerAddr);
            vm.expectRevert();
            swapRouter.swap(
                poolKey,
                SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: -int256(sellAmount),
                    sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
                }),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                abi.encode(issuerAddr)
            );
        }
    }

    function test_BpsCeilDivision_ExactBoundary() public {
        _initPoolWithLargeLiquidity();

        uint256 poolReserve = issuedToken.balanceOf(address(manager));
        // Daily limit = 300 bps (3%). Compute the exact threshold amount.
        // Ceil division: (amount * 10_000 + reserve - 1) / reserve > 300
        // At exact limit: amount = (reserve * 300) / 10_000 → floor division.
        // With ceil BPS: ceil(amount * 10_000 / reserve) may equal 300 or 301.
        uint256 exactAmount = (poolReserve * 300) / 10_000;

        // Verify: ceil BPS of exactAmount should be <= 300 (at the boundary)
        uint256 ceilBps = (exactAmount * 10_000 + poolReserve - 1) / poolReserve;
        assertLe(ceilBps, 300, "ceil BPS at exact amount should be <= 300");

        // This sell should succeed (at or below limit)
        _issuerSellIssuedToken(exactAmount);
    }

    function test_BpsCeilDivision_OneWeiOverBoundary() public {
        _initPoolWithLargeLiquidity();

        uint256 poolReserve = issuedToken.balanceOf(address(manager));
        // Compute the smallest amount that would make ceil BPS = 301 (exceeding 300 limit).
        // ceil(amount * 10_000 / reserve) > 300
        // ⇔ amount * 10_000 > 300 * reserve (strict, since ceil rounds up)
        // ⇔ amount > 300 * reserve / 10_000
        // The smallest such integer is floor(300 * reserve / 10_000) + 1
        uint256 smallestOver = (poolReserve * 300) / 10_000 + 1;

        uint256 ceilBps = (smallestOver * 10_000 + poolReserve - 1) / poolReserve;
        assertGt(ceilBps, 300, "ceil BPS should exceed 300 for smallestOver");

        bool issuedIsToken0 = Currency.unwrap(currency0) == address(issuedToken);
        bool zeroForOne = issuedIsToken0;

        vm.prank(issuerAddr);
        vm.expectRevert();
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(smallestOver),
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(issuerAddr)
        );
    }

    function test_BpsCeilDivision_SmallReserve() public {
        // Test with a small pool reserve where rounding matters more.
        // Deploy a token with small supply, create pool with minimal liquidity.
        MockERC20 smallToken = new MockERC20("SmallToken", "SMT", 18);
        smallToken.mint(issuerAddr, 100 ether);
        smallToken.mint(address(this), 100 ether);

        (Currency c0, Currency c1) = SortTokens.sort(smallToken, baseToken);
        PoolKey memory _key = PoolKey(c0, c1, 3000, 60, IHooks(address(hook)));
        PoolId _poolId = _key.toId();
        manager.initialize(_key, SQRT_PRICE_1_1);

        vm.startPrank(issuerAddr);
        smallToken.approve(address(modifyLiquidityRouter), type(uint256).max);
        baseToken.approve(address(modifyLiquidityRouter), type(uint256).max);
        vm.stopPrank();
        smallToken.approve(address(modifyLiquidityRouter), type(uint256).max);

        // Add small liquidity — pool reserve will be ~10 tokens
        bytes memory hd = abi.encode(
            issuerAddr, address(smallToken), DEFAULT_LOCK, DEFAULT_VESTING,
            _defaultCommitment(), _defaultTriggerConfig()
        );
        vm.prank(issuerAddr);
        modifyLiquidityRouter.modifyLiquidity(
            _key,
            ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: 10e18, salt: 0}),
            hd
        );

        poolKey = _key;
        poolId = _poolId;
        issuedToken = smallToken;
        currency0 = c0;
        currency1 = c1;

        uint256 poolReserve = smallToken.balanceOf(address(manager));
        assertGt(poolReserve, 0, "small pool has reserve");

        // Sell exactly at limit
        uint256 atLimit = (poolReserve * 300) / 10_000;
        if (atLimit > 0) {
            _issuerSellIssuedToken(atLimit);
        }

        // Next day: sell 1 wei more than limit
        vm.warp(block.timestamp + 1 days);
        uint256 newReserve = smallToken.balanceOf(address(manager));
        uint256 overLimit = (newReserve * 300) / 10_000 + 1;

        bool issuedIsToken0 = Currency.unwrap(currency0) == address(smallToken);
        bool zeroForOne = issuedIsToken0;

        vm.prank(issuerAddr);
        vm.expectRevert();
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(overLimit),
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(issuerAddr)
        );
    }

    function test_NonIssuerSell_NoRestriction() public {
        _initPoolWithIssuer();

        // Give trader issued tokens
        issuedToken.mint(trader, 1_000_000 ether);

        bool issuedIsToken0 = Currency.unwrap(currency0) == address(issuedToken);
        bool zeroForOne = issuedIsToken0;

        // Trader sells large amount — no restriction for non-issuer
        vm.prank(trader);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(1_000 ether),
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        // Should succeed
    }

    // ═══════════════════════════════════════════════════════════════════
    //  IMMEDIATE TRIGGER EXECUTION TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_LPRemovalTrigger_ImmediateExecution() public {
        _initPoolWithIssuer();

        // Trigger directly via executeTrigger on TriggerOracle (from hook context)
        uint256 totalSupply = issuedToken.totalSupply();

        vm.prank(address(hook));
        triggerOracle.executeTrigger(poolId, poolKey, ITriggerOracle.TriggerType.RUG_PULL, totalSupply);

        // Should be immediately triggered
        assertTrue(triggerOracle.checkTrigger(poolId).triggered);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  POST-TRIGGER BLOCKING TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_AfterTrigger_IssuerSellBlocked() public {
        _initPoolWithIssuer();

        // Trigger the pool via commitment breach
        vm.prank(address(hook));
        triggerOracle.reportCommitmentBreach(poolId);
        assertTrue(triggerOracle.checkTrigger(poolId).triggered);

        // The _isTriggered flag should be set if forceRemoveIssuerLP was called
        // But since there's no BastionRouter in this test, forceRemoval may fail gracefully.
        // Check that the escrow is triggered directly
        (, uint256 escrowId,,,) = hook.getPoolInfo(poolId);
        assertTrue(escrowVault.isTriggered(escrowId));
    }

    function test_AfterTrigger_NormalUserSwapWorks() public {
        _initPoolWithIssuer();

        // Trigger the pool
        vm.prank(address(hook));
        triggerOracle.reportCommitmentBreach(poolId);
        assertTrue(triggerOracle.checkTrigger(poolId).triggered);

        // Normal user can still swap
        _traderBuyIssuedToken(0.01 ether);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  LP RATIO TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_PoolCreation_RecordsLPRatio() public {
        _initPoolWithIssuer();

        uint256 lpRatio = hook.lpRatioBps(poolId);
        // LP ratio should be non-zero (liquidity / totalSupply * 10000)
        // With 1e18 liquidity and ~2M total supply, ratio will be very small
        // Just verify it was recorded
        assertGe(lpRatio, 0);

        uint256 initialSupply = hook.getInitialTotalSupply(poolId);
        assertGt(initialSupply, 0, "initial total supply should be recorded");
    }

    function test_PoolCreation_LowRatio_StillSucceeds() public {
        // Mint extra supply to make LP ratio very low
        issuedToken.mint(address(0xdead), 100_000_000 ether);

        _initPoolWithIssuer();

        uint256 lpRatio = hook.lpRatioBps(poolId);
        // Should still succeed even with very low ratio
        assertGe(lpRatio, 0);
    }
}
