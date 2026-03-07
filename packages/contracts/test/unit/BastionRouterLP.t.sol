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
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
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
import {IReputationEngine} from "../../src/interfaces/IReputationEngine.sol";

contract MockReputationEngine2 {
    function recordEvent(address, uint8, bytes calldata) external {}
    function getScore(address) external pure returns (uint256) { return 500; }
}

contract BastionRouterLPTest is Test, Deployers {
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

    int24 constant TICK_LOWER = -887220;
    int24 constant TICK_UPPER = 887220;

    function setUp() public {
        issuerAddr = makeAddr("issuer");
        trader = makeAddr("trader");
        guardian = makeAddr("guardian");
        governance = makeAddr("governance");

        deployFreshManagerAndRouters();

        bastionSwapRouter = new BastionSwapRouter(manager, ISignatureTransfer(address(0)));
        bastionPositionRouter = new BastionPositionRouter(manager, ISignatureTransfer(address(0)));

        uint160 flags = uint160(
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG |
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG |
            Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        address hookAddr = address(flags);

        MockReputationEngine2 mockReputation = new MockReputationEngine2();
        address reputationAddr = address(mockReputation);

        uint64 nonce = vm.getNonce(address(this));
        address escrowAddr = vm.computeCreateAddress(address(this), nonce);
        address insuranceAddr = vm.computeCreateAddress(address(this), nonce + 1);
        address triggerAddr = vm.computeCreateAddress(address(this), nonce + 2);

        escrowVault = new EscrowVault(hookAddr, triggerAddr, reputationAddr);
        insurancePool = new InsurancePool(hookAddr, triggerAddr, governance, escrowAddr, address(0));
        triggerOracle = new TriggerOracle(hookAddr, escrowAddr, insuranceAddr, guardian, reputationAddr);

        bytes memory bytecode = abi.encodePacked(
            type(BastionHook).creationCode,
            abi.encode(address(manager), address(escrowVault), address(insurancePool), address(triggerOracle), reputationAddr, governance, address(0), address(0))
        );
        address deployed;
        assembly { deployed := create(0, add(bytecode, 0x20), mload(bytecode)) }
        vm.etch(hookAddr, deployed.code);
        hook = BastionHook(payable(hookAddr));

        // Wire up routers (hook.setBastionRouter requires _owner which is lost by vm.etch)
        bastionSwapRouter.setBastionHook(hookAddr);
        bastionPositionRouter.setBastionHook(hookAddr);

        issuedToken = new MockERC20("Issued Token", "ISS", 18);
        baseToken = new MockERC20("Base Token", "BASE", 18);

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

        // Approve LP router (issuer)
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

        poolKey = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hookAddr)
        });
        poolId = poolKey.toId();

        manager.initialize(poolKey, SQRT_PRICE_1_1);

        vm.deal(address(hook), 1 ether);

        // Issuer adds liquidity with escrow
        vm.startPrank(issuerAddr);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                liquidityDelta: int256(1000 ether),
                salt: 0
            }),
            _encodeIssuerHookData()
        );
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════
    //  TEST 1: Add liquidity V2 full range (ticks = 0,0)
    // ═══════════════════════════════════════════════════════════════

    function test_addLiquidityV2_fullRange() public {
        uint256 trader0Before = MockERC20(Currency.unwrap(poolKey.currency0)).balanceOf(trader);
        uint256 trader1Before = MockERC20(Currency.unwrap(poolKey.currency1)).balanceOf(trader);

        vm.prank(trader);
        bastionPositionRouter.addLiquidityV2(poolKey, 0, 0, 10 ether, 10 ether, block.timestamp + 3600);

        uint256 trader0After = MockERC20(Currency.unwrap(poolKey.currency0)).balanceOf(trader);
        uint256 trader1After = MockERC20(Currency.unwrap(poolKey.currency1)).balanceOf(trader);

        // Both tokens should have been spent
        assertLt(trader0After, trader0Before, "Token0 should be spent");
        assertLt(trader1After, trader1Before, "Token1 should be spent");

        // Position should exist
        uint128 liq = bastionPositionRouter.getPositionLiquidity(poolKey, trader, 0, 0);
        assertGt(liq, 0, "Position liquidity should be > 0");
    }

    // ═══════════════════════════════════════════════════════════════
    //  TEST 2: Add liquidity V2 custom range
    // ═══════════════════════════════════════════════════════════════

    function test_addLiquidityV2_customRange() public {
        int24 tickLower = -120;
        int24 tickUpper = 120;

        vm.prank(trader);
        bastionPositionRouter.addLiquidityV2(poolKey, tickLower, tickUpper, 10 ether, 10 ether, block.timestamp + 3600);

        uint128 liq = bastionPositionRouter.getPositionLiquidity(poolKey, trader, tickLower, tickUpper);
        assertGt(liq, 0, "Custom range position should have liquidity");
    }

    // ═══════════════════════════════════════════════════════════════
    //  TEST 3: Add liquidity V2 expired reverts
    // ═══════════════════════════════════════════════════════════════

    function test_addLiquidityV2_expired_reverts() public {
        vm.warp(1000);

        vm.prank(trader);
        vm.expectRevert(BastionPositionRouter.Expired.selector);
        bastionPositionRouter.addLiquidityV2(poolKey, 0, 0, 10 ether, 10 ether, 999);
    }

    // ═══════════════════════════════════════════════════════════════
    //  TEST 4: Remove liquidity V2 full range
    // ═══════════════════════════════════════════════════════════════

    function test_removeLiquidityV2_fullRange() public {
        // First add liquidity
        vm.prank(trader);
        bastionPositionRouter.addLiquidityV2(poolKey, 0, 0, 10 ether, 10 ether, block.timestamp + 3600);

        uint128 liq = bastionPositionRouter.getPositionLiquidity(poolKey, trader, 0, 0);
        assertGt(liq, 0, "Should have liquidity");

        uint256 trader0Before = MockERC20(Currency.unwrap(poolKey.currency0)).balanceOf(trader);
        uint256 trader1Before = MockERC20(Currency.unwrap(poolKey.currency1)).balanceOf(trader);

        // Remove all liquidity
        vm.prank(trader);
        bastionPositionRouter.removeLiquidityV2(poolKey, 0, 0, liq, 0, 0, block.timestamp + 3600);

        uint256 trader0After = MockERC20(Currency.unwrap(poolKey.currency0)).balanceOf(trader);
        uint256 trader1After = MockERC20(Currency.unwrap(poolKey.currency1)).balanceOf(trader);

        // Should have received tokens back
        assertGt(trader0After, trader0Before, "Should receive token0 back");
        assertGt(trader1After, trader1Before, "Should receive token1 back");

        // Position should be empty
        uint128 liqAfter = bastionPositionRouter.getPositionLiquidity(poolKey, trader, 0, 0);
        assertEq(liqAfter, 0, "Position should be empty");
    }

    // ═══════════════════════════════════════════════════════════════
    //  TEST 5: Remove liquidity V2 partial
    // ═══════════════════════════════════════════════════════════════

    function test_removeLiquidityV2_partial() public {
        vm.prank(trader);
        bastionPositionRouter.addLiquidityV2(poolKey, 0, 0, 10 ether, 10 ether, block.timestamp + 3600);

        uint128 liq = bastionPositionRouter.getPositionLiquidity(poolKey, trader, 0, 0);

        // Remove 50%
        uint128 half = liq / 2;
        vm.prank(trader);
        bastionPositionRouter.removeLiquidityV2(poolKey, 0, 0, half, 0, 0, block.timestamp + 3600);

        uint128 remaining = bastionPositionRouter.getPositionLiquidity(poolKey, trader, 0, 0);
        assertApproxEqAbs(remaining, liq - half, 1, "Remaining should be ~50%");
    }

    // ═══════════════════════════════════════════════════════════════
    //  TEST 6: Remove liquidity V2 slippage reverts
    // ═══════════════════════════════════════════════════════════════

    function test_removeLiquidityV2_slippage_reverts() public {
        vm.prank(trader);
        bastionPositionRouter.addLiquidityV2(poolKey, 0, 0, 10 ether, 10 ether, block.timestamp + 3600);

        uint128 liq = bastionPositionRouter.getPositionLiquidity(poolKey, trader, 0, 0);

        vm.prank(trader);
        vm.expectRevert(BastionPositionRouter.SlippageExceeded.selector);
        bastionPositionRouter.removeLiquidityV2(poolKey, 0, 0, liq, type(uint256).max, 0, block.timestamp + 3600);
    }

    // ═══════════════════════════════════════════════════════════════
    //  TEST 7: Remove liquidity V2 expired reverts
    // ═══════════════════════════════════════════════════════════════

    function test_removeLiquidityV2_expired_reverts() public {
        vm.warp(1000);

        vm.prank(trader);
        vm.expectRevert(BastionPositionRouter.Expired.selector);
        bastionPositionRouter.removeLiquidityV2(poolKey, 0, 0, 100, 0, 0, 999);
    }

    // ═══════════════════════════════════════════════════════════════
    //  TEST 8: Collect fees after swaps
    // ═══════════════════════════════════════════════════════════════

    function test_collectFees_afterSwaps() public {
        // Add V2 liquidity
        vm.prank(trader);
        bastionPositionRouter.addLiquidityV2(poolKey, 0, 0, 100 ether, 100 ether, block.timestamp + 3600);

        // Execute some swaps to generate fees
        vm.startPrank(trader);
        bastionSwapRouter.swapExactInput(poolKey, true, 1 ether, 0, block.timestamp + 3600);
        bastionSwapRouter.swapExactInput(poolKey, false, 1 ether, 0, block.timestamp + 3600);
        vm.stopPrank();

        uint256 trader0Before = MockERC20(Currency.unwrap(poolKey.currency0)).balanceOf(trader);
        uint256 trader1Before = MockERC20(Currency.unwrap(poolKey.currency1)).balanceOf(trader);

        // Collect fees
        vm.prank(trader);
        bastionPositionRouter.collectFees(poolKey, 0, 0);

        uint256 trader0After = MockERC20(Currency.unwrap(poolKey.currency0)).balanceOf(trader);
        uint256 trader1After = MockERC20(Currency.unwrap(poolKey.currency1)).balanceOf(trader);

        // At least one token should have increased (fees collected)
        bool receivedFees = trader0After > trader0Before || trader1After > trader1Before;
        assertTrue(receivedFees, "Should have collected fees");
    }

    // ═══════════════════════════════════════════════════════════════
    //  TEST 9: General LP not escrowed
    // ═══════════════════════════════════════════════════════════════

    function test_generalLP_notEscrowed() public {
        // Add V2 LP as non-issuer (trader)
        vm.prank(trader);
        bastionPositionRouter.addLiquidityV2(poolKey, 0, 0, 10 ether, 10 ether, block.timestamp + 3600);

        // Position should exist (no revert from escrow check)
        uint128 liq = bastionPositionRouter.getPositionLiquidity(poolKey, trader, 0, 0);
        assertGt(liq, 0, "General LP should have liquidity");

        // Should be able to immediately remove (no vesting)
        vm.prank(trader);
        bastionPositionRouter.removeLiquidityV2(poolKey, 0, 0, liq, 0, 0, block.timestamp + 3600);

        uint128 liqAfter = bastionPositionRouter.getPositionLiquidity(poolKey, trader, 0, 0);
        assertEq(liqAfter, 0, "Should be fully removed");
    }

    // ═══════════════════════════════════════════════════════════════
    //  TEST 10: General LP not affected by trigger
    // ═══════════════════════════════════════════════════════════════

    function test_generalLP_notAffectedByTrigger() public {
        // Add V2 LP as trader
        vm.prank(trader);
        bastionPositionRouter.addLiquidityV2(poolKey, 0, 0, 10 ether, 10 ether, block.timestamp + 3600);

        uint128 liq = bastionPositionRouter.getPositionLiquidity(poolKey, trader, 0, 0);
        assertGt(liq, 0, "Should have liquidity");

        // Execute swaps to change pool state
        vm.startPrank(trader);
        bastionSwapRouter.swapExactInput(poolKey, true, 5 ether, 0, block.timestamp + 3600);
        bastionSwapRouter.swapExactInput(poolKey, false, 5 ether, 0, block.timestamp + 3600);
        vm.stopPrank();

        // Warp time forward (past issuer lock period)
        vm.warp(block.timestamp + 100 days);

        // General LP (V2, salt-isolated) should still be freely removable
        vm.prank(trader);
        bastionPositionRouter.removeLiquidityV2(poolKey, 0, 0, liq, 0, 0, block.timestamp + 3600);

        uint128 liqAfter = bastionPositionRouter.getPositionLiquidity(poolKey, trader, 0, 0);
        assertEq(liqAfter, 0, "General LP should be removable anytime");
    }

    // ═══════════════════════════════════════════════════════════════
    //  TEST 11: LiquidityChanged event emitted
    // ═══════════════════════════════════════════════════════════════

    function test_LiquidityChanged_event() public {
        vm.prank(trader);
        vm.expectEmit(true, true, false, false);
        emit BastionPositionRouter.LiquidityChanged(
            poolId, trader,
            TICK_LOWER, TICK_UPPER,
            0, 0, 0 // We don't check exact values, just indexed fields
        );
        bastionPositionRouter.addLiquidityV2(poolKey, 0, 0, 10 ether, 10 ether, block.timestamp + 3600);
    }

    // ═══════════════════════════════════════════════════════════════
    //  HELPERS
    // ═══════════════════════════════════════════════════════════════

    function _encodeIssuerHookData() internal view returns (bytes memory) {
        uint40 lockDuration = 7 days;
        uint40 vestingDuration = 83 days;

        IEscrowVault.IssuerCommitment memory commitment = IEscrowVault.IssuerCommitment({
            dailyWithdrawLimit: 0,
            maxSellPercent: 200
        });

        ITriggerOracle.TriggerConfig memory triggerConfig = ITriggerOracle.TriggerConfig({
            lpRemovalThreshold: 5000,
            dumpThresholdPercent: 3000,
            dumpWindowSeconds: 86400,
            taxDeviationThreshold: 500,
            slowRugWindowSeconds: 86400,
            slowRugCumulativeThreshold: 8000
        });

        return abi.encode(
            issuerAddr, address(issuedToken), lockDuration, vestingDuration, commitment, triggerConfig
        );
    }
}
