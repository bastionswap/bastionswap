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
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";
import {BastionSwapRouter} from "../../src/router/BastionSwapRouter.sol";
import {BastionPositionRouter} from "../../src/router/BastionPositionRouter.sol";
import {BastionHook} from "../../src/hooks/BastionHook.sol";
import {EscrowVault} from "../../src/core/EscrowVault.sol";
import {InsurancePool} from "../../src/core/InsurancePool.sol";
import {TriggerOracle} from "../../src/core/TriggerOracle.sol";
import {IEscrowVault} from "../../src/interfaces/IEscrowVault.sol";
import {ITriggerOracle} from "../../src/interfaces/ITriggerOracle.sol";

contract MockReputationEngine2 {
    function recordEvent(address, uint8, bytes calldata) external {}
    function getScore(address) external pure returns (uint256) { return 500; }
}

contract BastionRouterMultiHopTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    BastionSwapRouter public bastionSwapRouter;
    BastionPositionRouter public bastionPositionRouter;
    BastionHook public hook;
    EscrowVault public escrowVault;
    InsurancePool public insurancePool;
    TriggerOracle public triggerOracle;

    MockERC20 public btt;
    MockERC20 public alpha;

    address public issuerAddr;
    address public trader;
    address public governance;

    // Two pools: ETH/BTT and ETH/ALPHA
    PoolKey public poolKeyEthBtt;
    PoolKey public poolKeyEthAlpha;

    function setUp() public {
        issuerAddr = makeAddr("issuer");
        trader = makeAddr("trader");
        governance = makeAddr("governance");

        deployFreshManagerAndRouters();

        bastionSwapRouter = new BastionSwapRouter(manager, ISignatureTransfer(address(0)));
        bastionPositionRouter = new BastionPositionRouter(manager, ISignatureTransfer(address(0)));

        // Deploy hook at correct flag address
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
        triggerOracle = new TriggerOracle(hookAddr, escrowAddr, insuranceAddr, governance, reputationAddr);

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

        // Deploy tokens — ensure BTT and ALPHA addresses > address(0) for ETH sorting
        btt = new MockERC20("Bastion Test Token", "BTT", 18);
        alpha = new MockERC20("Alpha Token", "ALPHA", 18);

        // Register ETH (address(0)) as allowed base token (storage lost by vm.etch)
        vm.prank(governance);
        hook.addBaseToken(address(0), 0);

        // Build pool keys: ETH is always currency0 (address(0) < any ERC20)
        poolKeyEthBtt = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(btt)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hookAddr)
        });

        poolKeyEthAlpha = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(alpha)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hookAddr)
        });

        // Mint tokens
        btt.mint(issuerAddr, 1_000_000 ether);
        alpha.mint(issuerAddr, 1_000_000 ether);
        btt.mint(trader, 1_000_000 ether);
        alpha.mint(trader, 1_000_000 ether);
        vm.deal(issuerAddr, 1_000 ether);
        vm.deal(trader, 1_000 ether);

        // Approve LP router
        vm.startPrank(issuerAddr);
        btt.approve(address(modifyLiquidityRouter), type(uint256).max);
        alpha.approve(address(modifyLiquidityRouter), type(uint256).max);
        vm.stopPrank();

        // Approve both routers for trader
        vm.startPrank(trader);
        btt.approve(address(bastionSwapRouter), type(uint256).max);
        alpha.approve(address(bastionSwapRouter), type(uint256).max);
        btt.approve(address(bastionPositionRouter), type(uint256).max);
        alpha.approve(address(bastionPositionRouter), type(uint256).max);
        vm.stopPrank();

        // Initialize both pools
        manager.initialize(poolKeyEthBtt, SQRT_PRICE_1_1);
        manager.initialize(poolKeyEthAlpha, SQRT_PRICE_1_1);

        // Fund hook with ETH for insurance fees
        vm.deal(address(hook), 10 ether);

        // Add liquidity to ETH/BTT pool
        vm.startPrank(issuerAddr);
        modifyLiquidityRouter.modifyLiquidity{value: 100 ether}(
            poolKeyEthBtt,
            ModifyLiquidityParams({
                tickLower: -887220,
                tickUpper: 887220,
                liquidityDelta: int256(100 ether),
                salt: 0
            }),
            _encodeIssuerHookData(address(btt))
        );

        // Add liquidity to ETH/ALPHA pool
        modifyLiquidityRouter.modifyLiquidity{value: 100 ether}(
            poolKeyEthAlpha,
            ModifyLiquidityParams({
                tickLower: -887220,
                tickUpper: 887220,
                liquidityDelta: int256(100 ether),
                salt: 0
            }),
            _encodeIssuerHookData(address(alpha))
        );
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════
    //  TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_multiHopSwap_TwoHops() public {
        // BTT → ETH → ALPHA (trader sells BTT for ALPHA via ETH intermediary)
        uint256 amountIn = 1 ether;

        BastionSwapRouter.SwapStep[] memory steps = new BastionSwapRouter.SwapStep[](2);
        // Step 1: BTT → ETH (sell BTT, currency1→currency0, so zeroForOne=false)
        steps[0] = BastionSwapRouter.SwapStep({
            poolKey: poolKeyEthBtt,
            zeroForOne: false  // BTT (currency1) → ETH (currency0)
        });
        // Step 2: ETH → ALPHA (buy ALPHA with ETH, currency0→currency1, so zeroForOne=true)
        steps[1] = BastionSwapRouter.SwapStep({
            poolKey: poolKeyEthAlpha,
            zeroForOne: true  // ETH (currency0) → ALPHA (currency1)
        });

        uint256 bttBefore = btt.balanceOf(trader);
        uint256 alphaBefore = alpha.balanceOf(trader);

        vm.prank(trader);
        uint256 amountOut = bastionSwapRouter.swapMultiHop(steps, amountIn, 0, block.timestamp + 3600);

        assertGt(amountOut, 0, "Should receive ALPHA tokens");
        assertEq(btt.balanceOf(trader), bttBefore - amountIn, "BTT should be spent");
        assertEq(alpha.balanceOf(trader), alphaBefore + amountOut, "ALPHA should be received");
    }

    function test_multiHopSwap_ReverseDirection() public {
        // ALPHA → ETH → BTT
        uint256 amountIn = 1 ether;

        BastionSwapRouter.SwapStep[] memory steps = new BastionSwapRouter.SwapStep[](2);
        // Step 1: ALPHA → ETH
        steps[0] = BastionSwapRouter.SwapStep({
            poolKey: poolKeyEthAlpha,
            zeroForOne: false  // ALPHA (currency1) → ETH (currency0)
        });
        // Step 2: ETH → BTT
        steps[1] = BastionSwapRouter.SwapStep({
            poolKey: poolKeyEthBtt,
            zeroForOne: true  // ETH (currency0) → BTT (currency1)
        });

        uint256 alphaBefore = alpha.balanceOf(trader);
        uint256 bttBefore = btt.balanceOf(trader);

        vm.prank(trader);
        uint256 amountOut = bastionSwapRouter.swapMultiHop(steps, amountIn, 0, block.timestamp + 3600);

        assertGt(amountOut, 0, "Should receive BTT tokens");
        assertEq(alpha.balanceOf(trader), alphaBefore - amountIn, "ALPHA should be spent");
        assertEq(btt.balanceOf(trader), bttBefore + amountOut, "BTT should be received");
    }

    function test_multiHopSwap_NativeETHInput() public {
        // ETH → BTT using multi-hop (single step)
        uint256 amountIn = 1 ether;

        BastionSwapRouter.SwapStep[] memory steps = new BastionSwapRouter.SwapStep[](1);
        steps[0] = BastionSwapRouter.SwapStep({
            poolKey: poolKeyEthBtt,
            zeroForOne: true  // ETH → BTT
        });

        uint256 bttBefore = btt.balanceOf(trader);
        uint256 ethBefore = trader.balance;

        vm.prank(trader);
        uint256 amountOut = bastionSwapRouter.swapMultiHop{value: amountIn}(steps, amountIn, 0, block.timestamp + 3600);

        assertGt(amountOut, 0, "Should receive BTT tokens");
        assertEq(btt.balanceOf(trader), bttBefore + amountOut, "BTT should be received");
        assertLt(trader.balance, ethBefore, "ETH should be spent");
    }

    function test_multiHopSwap_Slippage_Reverts() public {
        uint256 amountIn = 1 ether;

        BastionSwapRouter.SwapStep[] memory steps = new BastionSwapRouter.SwapStep[](2);
        steps[0] = BastionSwapRouter.SwapStep({ poolKey: poolKeyEthBtt, zeroForOne: false });
        steps[1] = BastionSwapRouter.SwapStep({ poolKey: poolKeyEthAlpha, zeroForOne: true });

        vm.prank(trader);
        vm.expectRevert();
        bastionSwapRouter.swapMultiHop(steps, amountIn, type(uint256).max, block.timestamp + 3600);
    }

    function test_multiHopSwap_Expired_Reverts() public {
        vm.warp(1000);

        BastionSwapRouter.SwapStep[] memory steps = new BastionSwapRouter.SwapStep[](1);
        steps[0] = BastionSwapRouter.SwapStep({ poolKey: poolKeyEthBtt, zeroForOne: true });

        vm.prank(trader);
        vm.expectRevert(BastionSwapRouter.Expired.selector);
        bastionSwapRouter.swapMultiHop(steps, 1 ether, 0, 999);
    }

    function test_multiHopSwap_TooManyHops_Reverts() public {
        BastionSwapRouter.SwapStep[] memory steps = new BastionSwapRouter.SwapStep[](5);
        for (uint256 i = 0; i < 5; i++) {
            steps[i] = BastionSwapRouter.SwapStep({ poolKey: poolKeyEthBtt, zeroForOne: true });
        }

        vm.prank(trader);
        vm.expectRevert(BastionSwapRouter.TooManyHops.selector);
        bastionSwapRouter.swapMultiHop{value: 1 ether}(steps, 1 ether, 0, block.timestamp + 3600);
    }

    function test_multiHopSwap_ZeroHops_Reverts() public {
        BastionSwapRouter.SwapStep[] memory steps = new BastionSwapRouter.SwapStep[](0);

        vm.prank(trader);
        vm.expectRevert(BastionSwapRouter.ZeroHops.selector);
        bastionSwapRouter.swapMultiHop(steps, 1 ether, 0, block.timestamp + 3600);
    }

    // ═══════════════════════════════════════════════════════════════
    //  HELPERS
    // ═══════════════════════════════════════════════════════════════

    function _encodeIssuerHookData(address token) internal view returns (bytes memory) {
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
            issuerAddr, token, lockDuration, vestingDuration, commitment, triggerConfig
        );
    }
}
