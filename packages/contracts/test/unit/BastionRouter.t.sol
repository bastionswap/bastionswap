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
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {SortTokens} from "@uniswap/v4-core/test/utils/SortTokens.sol";

import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";
import {BastionSwapRouter} from "../../src/router/BastionSwapRouter.sol";
import {BastionPositionRouter} from "../../src/router/BastionPositionRouter.sol";
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

contract BastionRouterTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    BastionSwapRouter public bastionSwapRouter;
    BastionPositionRouter public bastionPositionRouter;
    BastionHook public hook;
    EscrowVault public escrowVault;
    InsurancePool public insurancePool;
    TriggerOracle public triggerOracle;

    MockERC20 public issuedToken;
    MockERC20 public baseToken;

    address public issuerAddr;
    address public trader;
    address public guardian;
    address public governance;

    PoolKey public poolKey;
    PoolId public poolId;
    bool public issuedIsToken0;

    function setUp() public {
        issuerAddr = makeAddr("issuer");
        trader = makeAddr("trader");
        guardian = makeAddr("guardian");
        governance = makeAddr("governance");

        // Deploy V4 PoolManager and standard routers
        deployFreshManagerAndRouters();

        // Deploy routers
        bastionSwapRouter = new BastionSwapRouter(manager, ISignatureTransfer(address(0)));
        bastionPositionRouter = new BastionPositionRouter(manager, ISignatureTransfer(address(0)));

        // Deploy hook at correct flag address
        uint160 flags = uint160(
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG |
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG |
            Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        address hookAddr = address(flags);

        MockReputationEngine mockReputation = new MockReputationEngine();
        address reputationAddr = address(mockReputation);

        uint64 nonce = vm.getNonce(address(this));
        address escrowAddr = vm.computeCreateAddress(address(this), nonce);
        address insuranceAddr = vm.computeCreateAddress(address(this), nonce + 1);
        address triggerAddr = vm.computeCreateAddress(address(this), nonce + 2);

        escrowVault = new EscrowVault(hookAddr, triggerAddr, reputationAddr);
        insurancePool = new InsurancePool(hookAddr, triggerAddr, governance, escrowAddr, address(0));
        triggerOracle = new TriggerOracle(hookAddr, escrowAddr, insuranceAddr, guardian, reputationAddr, governance);

        bytes memory bytecode = abi.encodePacked(
            type(BastionHook).creationCode,
            abi.encode(address(manager), address(escrowVault), address(insurancePool), address(triggerOracle), reputationAddr, governance, address(0), address(0))
        );
        address deployed;
        assembly { deployed := create(0, add(bytecode, 0x20), mload(bytecode)) }
        vm.etch(hookAddr, deployed.code);
        // Restore storage lost by vm.etch
        vm.store(hookAddr, bytes32(uint256(24)), bytes32(uint256(uint160(governance))));
        // Restore duration params + LP removal defaults: defaultLockDuration=7days, defaultVestingDuration=83days, minLockDuration=7days, minVestingDuration=7days, dailyLpRemovalBps=1000, weeklyLpRemovalBps=3000
        vm.store(hookAddr, bytes32(uint256(26)), bytes32(uint256(uint40(7 days)) | (uint256(uint40(83 days)) << 40) | (uint256(uint40(7 days)) << 80) | (uint256(uint40(7 days)) << 120) | (uint256(uint16(1000)) << 160) | (uint256(uint16(3000)) << 176)));
        hook = BastionHook(payable(hookAddr));

        // Wire up routers (hook.setBastionRouter requires _owner which is lost by vm.etch)
        bastionSwapRouter.setBastionHook(hookAddr);
        bastionPositionRouter.setBastionHook(hookAddr);

        // Deploy tokens
        issuedToken = new MockERC20("Issued Token", "ISS", 18);
        baseToken = new MockERC20("Base Token", "BASE", 18);

        // Register baseToken as allowed base token (storage lost by vm.etch)
        vm.prank(governance);
        hook.addBaseToken(address(baseToken), 0);

        (Currency c0, Currency c1) = SortTokens.sort(issuedToken, baseToken);
        currency0 = c0;
        currency1 = c1;
        issuedIsToken0 = Currency.unwrap(c0) == address(issuedToken);

        // Mint tokens
        issuedToken.mint(issuerAddr, 1_000_000 ether);
        baseToken.mint(issuerAddr, 1_000_000 ether);
        issuedToken.mint(trader, 1_000_000 ether);
        baseToken.mint(trader, 1_000_000 ether);

        // Approve LP router (issuer) — no hook approval needed
        vm.startPrank(issuerAddr);
        issuedToken.approve(address(modifyLiquidityRouter), type(uint256).max);
        baseToken.approve(address(modifyLiquidityRouter), type(uint256).max);
        vm.stopPrank();

        // Approve both routers (trader)
        vm.startPrank(trader);
        issuedToken.approve(address(bastionSwapRouter), type(uint256).max);
        baseToken.approve(address(bastionSwapRouter), type(uint256).max);
        issuedToken.approve(address(bastionPositionRouter), type(uint256).max);
        baseToken.approve(address(bastionPositionRouter), type(uint256).max);
        vm.stopPrank();

        // Create pool key with hook
        poolKey = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hookAddr)
        });
        poolId = poolKey.toId();

        // Initialize pool
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        // Fund hook with ETH for insurance fees
        vm.deal(address(hook), 1 ether);

        // Issuer adds liquidity with escrow hookData
        vm.startPrank(issuerAddr);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: -887220,
                tickUpper: 887220,
                liquidityDelta: int256(1000 ether),
                salt: 0
            }),
            _encodeIssuerHookData()
        );
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════
    //  TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_SwapExactInput_BuyIssuedToken() public {
        uint256 amountIn = 1 ether;
        // Buy issued token: sell base token
        bool zeroForOne = !issuedIsToken0;

        uint256 traderBaseBefore = baseToken.balanceOf(trader);
        uint256 traderIssuedBefore = issuedToken.balanceOf(trader);

        vm.prank(trader);
        uint256 amountOut = bastionSwapRouter.swapExactInput(
            poolKey, zeroForOne, amountIn, 0, block.timestamp + 3600
        );

        assertGt(amountOut, 0, "Should receive output tokens");

        if (issuedIsToken0) {
            assertEq(baseToken.balanceOf(trader), traderBaseBefore - amountIn, "Base token spent");
            assertEq(issuedToken.balanceOf(trader), traderIssuedBefore + amountOut, "Issued token received");
        } else {
            assertEq(baseToken.balanceOf(trader), traderBaseBefore - amountIn, "Base token spent");
            assertEq(issuedToken.balanceOf(trader), traderIssuedBefore + amountOut, "Issued token received");
        }
    }

    function test_SwapExactInput_SellIssuedToken() public {
        uint256 amountIn = 1 ether;
        // Sell issued token: buy base token
        bool zeroForOne = issuedIsToken0;

        uint256 traderIssuedBefore = issuedToken.balanceOf(trader);
        uint256 traderBaseBefore = baseToken.balanceOf(trader);

        vm.prank(trader);
        uint256 amountOut = bastionSwapRouter.swapExactInput(
            poolKey, zeroForOne, amountIn, 0, block.timestamp + 3600
        );

        assertGt(amountOut, 0, "Should receive output tokens");
        assertEq(issuedToken.balanceOf(trader), traderIssuedBefore - amountIn, "Issued token spent");
        assertGt(baseToken.balanceOf(trader), traderBaseBefore, "Base token received");
    }

    function test_SwapExactOutput() public {
        uint256 desiredOut = 0.5 ether;
        bool zeroForOne = !issuedIsToken0;

        uint256 traderIssuedBefore = issuedToken.balanceOf(trader);

        vm.prank(trader);
        uint256 amountIn = bastionSwapRouter.swapExactOutput(
            poolKey, zeroForOne, desiredOut, 10 ether, block.timestamp + 3600
        );

        assertGt(amountIn, 0, "Should spend input tokens");
        assertEq(issuedToken.balanceOf(trader), traderIssuedBefore + desiredOut, "Should receive exact output");
    }

    function test_SwapExpired_Reverts() public {
        vm.warp(1000);

        vm.prank(trader);
        vm.expectRevert(BastionSwapRouter.Expired.selector);
        bastionSwapRouter.swapExactInput(
            poolKey, true, 1 ether, 0, 999  // deadline in the past
        );
    }

    function test_SwapSlippage_Reverts() public {
        vm.prank(trader);
        vm.expectRevert();  // InsufficientOutput
        bastionSwapRouter.swapExactInput(
            poolKey, !issuedIsToken0, 1 ether, type(uint256).max, block.timestamp + 3600
        );
    }

    function test_SwapExactOutput_ExcessiveInput_Reverts() public {
        vm.prank(trader);
        vm.expectRevert();  // ExcessiveInput
        bastionSwapRouter.swapExactOutput(
            poolKey, !issuedIsToken0, 0.5 ether, 0, block.timestamp + 3600  // maxAmountIn = 0
        );
    }

    function test_ETHRefund_ExcessReturned() public {
        vm.deal(trader, 10 ether);

        uint256 balBefore = trader.balance;

        vm.prank(trader);
        bastionSwapRouter.swapExactInput{value: 1 ether}(
            poolKey, !issuedIsToken0, 1 ether, 0, block.timestamp + 3600
        );

        // Since this is an ERC20/ERC20 pool, no ETH is consumed.
        // All sent ETH should be refunded.
        assertEq(trader.balance, balBefore, "All ETH should be refunded for ERC20 swap");
    }

    function test_OnlyPoolManager_Reverts() public {
        vm.expectRevert(BastionSwapRouter.OnlyPoolManager.selector);
        bastionSwapRouter.unlockCallback("");
    }

    // ═══════════════════════════════════════════════════════════════
    //  CREATE POOL TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_createPool_HookNotSet_Reverts() public {
        // Deploy a fresh position router without setting hook
        BastionPositionRouter freshRouter = new BastionPositionRouter(manager, ISignatureTransfer(address(0)));

        vm.expectRevert(BastionPositionRouter.HookNotSet.selector);
        freshRouter.createPool(
            address(issuedToken),
            address(0),
            3000,
            100 ether,
            SQRT_PRICE_1_1,
            ""
        );
    }

    function test_createPool_ERC20Base_CreatesPoolAndRegistersIssuer() public {
        // Deploy a new issued token so we have a fresh pool
        MockERC20 newToken = new MockERC20("New Token", "NEW", 18);
        newToken.mint(issuerAddr, 1_000_000 ether);

        // Approve bastionPositionRouter for both tokens
        vm.startPrank(issuerAddr);
        newToken.approve(address(bastionPositionRouter), type(uint256).max);
        baseToken.approve(address(bastionPositionRouter), type(uint256).max);

        // Create pool via simplified createPool
        PoolId newPoolId = bastionPositionRouter.createPool(
            address(newToken),
            address(baseToken),
            3000,
            100 ether,
            SQRT_PRICE_1_1,
            _encodeIssuerHookDataForToken(address(newToken))
        );
        vm.stopPrank();

        // Verify pool was created (non-zero poolId)
        assertTrue(PoolId.unwrap(newPoolId) != bytes32(0), "Pool should be created");
    }

    // ═══════════════════════════════════════════════════════════════
    //  HELPERS
    // ═══════════════════════════════════════════════════════════════

    function _encodeIssuerHookDataForToken(address tokenAddr) internal view returns (bytes memory) {
        uint40 lockDuration = 7 days;
        uint40 vestingDuration = 83 days;

        IEscrowVault.IssuerCommitment memory commitment = IEscrowVault.IssuerCommitment({
            dailyWithdrawLimit: 0,
            maxSellPercent: 200
        });

        ITriggerOracle.TriggerConfig memory triggerConfig = ITriggerOracle.TriggerConfig({
            dailyLpRemovalBps: 1000,
            weeklyLpRemovalBps: 3000,
            dumpThresholdPercent: 300,
            dumpWindowSeconds: 86400,
            taxDeviationThreshold: 500,
            weeklyDumpWindowSeconds: 604800,
            weeklyDumpThresholdPercent: 1500
        });

        return abi.encode(
            issuerAddr, tokenAddr, lockDuration, vestingDuration, commitment, triggerConfig
        );
    }

    function _encodeIssuerHookData() internal view returns (bytes memory) {
        uint40 lockDuration = 7 days;
        uint40 vestingDuration = 83 days;

        IEscrowVault.IssuerCommitment memory commitment = IEscrowVault.IssuerCommitment({
            dailyWithdrawLimit: 0,
            maxSellPercent: 200
        });

        ITriggerOracle.TriggerConfig memory triggerConfig = ITriggerOracle.TriggerConfig({
            dailyLpRemovalBps: 1000,
            weeklyLpRemovalBps: 3000,
            dumpThresholdPercent: 300,
            dumpWindowSeconds: 86400,
            taxDeviationThreshold: 500,
            weeklyDumpWindowSeconds: 604800,
            weeklyDumpThresholdPercent: 1500
        });

        return abi.encode(
            issuerAddr, address(issuedToken), lockDuration, vestingDuration, commitment, triggerConfig
        );
    }
}
