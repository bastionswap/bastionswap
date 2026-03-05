// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
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

contract MockRepEngine {
    function recordEvent(address, uint8, bytes calldata) external {}
    function getScore(address) external pure returns (uint256) { return 500; }
}

contract GasBenchmarkTest is Test, Deployers {
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

        deployFreshManagerAndRouters();

        uint160 flags = uint160(
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG |
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        address hookAddr = address(flags);

        MockRepEngine mockReputation = new MockRepEngine();
        address reputationAddr = address(mockReputation);

        uint64 nonce = vm.getNonce(address(this));
        address escrowAddr = vm.computeCreateAddress(address(this), nonce);
        address insuranceAddr = vm.computeCreateAddress(address(this), nonce + 1);
        address triggerAddr = vm.computeCreateAddress(address(this), nonce + 2);

        escrowVault = new EscrowVault(hookAddr, triggerAddr, reputationAddr);
        insurancePool = new InsurancePool(hookAddr, triggerAddr, governance, escrowAddr, address(0));
        triggerOracle = new TriggerOracle(hookAddr, escrowAddr, insuranceAddr, guardian, reputationAddr);

        bytes memory creationCode = type(BastionHook).creationCode;
        bytes memory constructorArgs = abi.encode(
            address(manager), address(escrowVault), address(insurancePool),
            address(triggerOracle), reputationAddr, governance, address(0), address(0)
        );
        bytes memory bytecode = abi.encodePacked(creationCode, constructorArgs);
        address deployed;
        assembly { deployed := create(0, add(bytecode, 0x20), mload(bytecode)) }
        vm.etch(hookAddr, deployed.code);
        hook = BastionHook(payable(hookAddr));

        issuedToken = new MockERC20("Issued", "ISS", 18);
        baseToken = new MockERC20("Base", "BASE", 18);

        // Register baseToken as allowed base token (storage lost by vm.etch)
        vm.prank(governance);
        hook.addBaseToken(address(baseToken), 0);

        (Currency c0, Currency c1) = SortTokens.sort(issuedToken, baseToken);
        currency0 = c0;
        currency1 = c1;

        issuedToken.mint(issuerAddr, 1_000_000 ether);
        issuedToken.mint(address(this), 1_000_000 ether);
        baseToken.mint(issuerAddr, 1_000_000 ether);
        baseToken.mint(address(this), 1_000_000 ether);
        baseToken.mint(trader, 1_000_000 ether);
        issuedToken.mint(trader, 1_000_000 ether);

        issuedToken.approve(address(modifyLiquidityRouter), type(uint256).max);
        baseToken.approve(address(modifyLiquidityRouter), type(uint256).max);
        issuedToken.approve(address(swapRouter), type(uint256).max);
        baseToken.approve(address(swapRouter), type(uint256).max);

        vm.startPrank(issuerAddr);
        issuedToken.approve(address(modifyLiquidityRouter), type(uint256).max);
        baseToken.approve(address(modifyLiquidityRouter), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(trader);
        issuedToken.approve(address(swapRouter), type(uint256).max);
        baseToken.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _defaultVestingSchedule() internal pure returns (IEscrowVault.VestingStep[] memory) {
        IEscrowVault.VestingStep[] memory schedule = new IEscrowVault.VestingStep[](3);
        schedule[0] = IEscrowVault.VestingStep({timeOffset: 7 days, basisPoints: 1000});
        schedule[1] = IEscrowVault.VestingStep({timeOffset: 30 days, basisPoints: 3000});
        schedule[2] = IEscrowVault.VestingStep({timeOffset: 90 days, basisPoints: 10000});
        return schedule;
    }

    function _encodeIssuerHookData() internal view returns (bytes memory) {
        return abi.encode(
            issuerAddr, address(issuedToken),
            _defaultVestingSchedule(),
            IEscrowVault.IssuerCommitment({dailyWithdrawLimit: 0, lockDuration: 0, maxSellPercent: 200}),
            ITriggerOracle.TriggerConfig({
                lpRemovalThreshold: 5000, dumpThresholdPercent: 3000,
                dumpWindowSeconds: 86400, taxDeviationThreshold: 500,
                slowRugWindowSeconds: 86400, slowRugCumulativeThreshold: 8000
            })
        );
    }

    function _initPoolWithIssuer() internal {
        uint24 fee = 3000;
        int24 tickSpacing = 60;
        poolKey = PoolKey(currency0, currency1, fee, tickSpacing, IHooks(address(hook)));
        poolId = poolKey.toId();
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        vm.prank(issuerAddr);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e18, salt: 0}),
            _encodeIssuerHookData()
        );

        // Fund hook for insurance fees
        vm.deal(address(hook), 100 ether);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  GAS BENCHMARKS
    // ═══════════════════════════════════════════════════════════════════

    function test_gasBenchmark_beforeAddLiquidity_issuerFirstLP() public {
        uint24 fee = 3000;
        int24 tickSpacing = 60;
        poolKey = PoolKey(currency0, currency1, fee, tickSpacing, IHooks(address(hook)));
        poolId = poolKey.toId();
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        uint256 gasBefore = gasleft();
        vm.prank(issuerAddr);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e18, salt: 0}),
            _encodeIssuerHookData()
        );
        uint256 gasUsed = gasBefore - gasleft();
        console.log("beforeAddLiquidity (issuer first LP, full tx):", gasUsed);
    }

    function test_gasBenchmark_beforeAddLiquidity_subsequentLP() public {
        _initPoolWithIssuer();

        // Second LP addition (no hookData, not issuer)
        uint256 gasBefore = gasleft();
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 0.5e18, salt: 0}),
            ""
        );
        uint256 gasUsed = gasBefore - gasleft();
        console.log("beforeAddLiquidity (subsequent LP):", gasUsed);
    }

    function test_gasBenchmark_afterSwap_buySwap() public {
        _initPoolWithIssuer();

        // Additional liquidity for trading
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 100e18, salt: 0}),
            ""
        );

        bool zeroForOne = Currency.unwrap(currency0) != address(issuedToken);
        SwapParams memory swapParams = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -1e15,
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1
        });

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        uint256 gasBefore = gasleft();
        swapRouter.swap(poolKey, swapParams, testSettings, "");
        uint256 gasUsed = gasBefore - gasleft();
        console.log("afterSwap (buy swap with fee, full tx):", gasUsed);
    }

    function test_gasBenchmark_afterSwap_nonIssuerSell() public {
        _initPoolWithIssuer();

        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 100e18, salt: 0}),
            ""
        );

        bool zeroForOne = Currency.unwrap(currency0) == address(issuedToken);
        SwapParams memory swapParams = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -1e15,
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1
        });

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        uint256 gasBefore = gasleft();
        vm.prank(trader);
        swapRouter.swap(poolKey, swapParams, testSettings, "");
        uint256 gasUsed = gasBefore - gasleft();
        console.log("afterSwap (non-issuer sell, full tx):", gasUsed);
    }

    function test_gasBenchmark_beforeRemoveLiquidity() public {
        _initPoolWithIssuer();

        // Add more liquidity to have something to remove
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 10e18, salt: 0}),
            ""
        );

        // Must pass hookData with user address since modifyLiquidityRouter == _issuerLPOwner
        bytes memory hookData = abi.encode(address(this));

        uint256 gasBefore = gasleft();
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: -5e18, salt: 0}),
            hookData
        );
        uint256 gasUsed = gasBefore - gasleft();
        console.log("beforeRemoveLiquidity (with oracle report):", gasUsed);
    }

    function test_gasBenchmark_claimCompensation() public {
        _initPoolWithIssuer();

        PoolId pid = poolId;
        // Deposit ETH to insurance pool
        vm.prank(address(hook));
        insurancePool.depositFee{value: 10 ether}(pid);

        // Create mock token for fallback claims
        MockERC20 claimToken = new MockERC20("Claim", "CLM", 18);
        address holder = makeAddr("holder");
        claimToken.mint(holder, 100 ether);

        // Trigger payout (fallback mode)
        vm.prank(address(triggerOracle));
        insurancePool.executePayout(pid, 1, 1000 ether, bytes32(0), address(claimToken));

        bytes32[] memory proof = new bytes32[](0);

        uint256 gasBefore = gasleft();
        vm.prank(holder);
        insurancePool.claimCompensation(pid, 100 ether, proof);
        uint256 gasUsed = gasBefore - gasleft();
        console.log("claimCompensation (fallback mode):", gasUsed);
    }

    function test_gasBenchmark_claimCompensation_merkle() public {
        _initPoolWithIssuer();

        PoolId pid = poolId;
        vm.prank(address(hook));
        insurancePool.depositFee{value: 10 ether}(pid);

        // Single holder merkle tree (leaf is the root)
        address holder = makeAddr("holder");
        uint256 holderBalance = 100 ether;
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(holder, holderBalance))));

        vm.prank(address(triggerOracle));
        insurancePool.executePayout(pid, 1, 1000 ether, leaf, address(0));

        bytes32[] memory proof = new bytes32[](0);

        uint256 gasBefore = gasleft();
        vm.prank(holder);
        insurancePool.claimCompensation(pid, holderBalance, proof);
        uint256 gasUsed = gasBefore - gasleft();
        console.log("claimCompensation (merkle mode):", gasUsed);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  BASELINE (no-hook pool for comparison)
    // ═══════════════════════════════════════════════════════════════════

    function test_gasBenchmark_baseline_swap() public {
        // Create a pool without hooks
        PoolKey memory noHookKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(0)));
        manager.initialize(noHookKey, SQRT_PRICE_1_1);

        modifyLiquidityRouter.modifyLiquidity(
            noHookKey,
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 100e18, salt: 0}),
            ""
        );

        SwapParams memory swapParams = SwapParams({
            zeroForOne: true,
            amountSpecified: -1e15,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        uint256 gasBefore = gasleft();
        swapRouter.swap(noHookKey, swapParams, testSettings, "");
        uint256 gasUsed = gasBefore - gasleft();
        console.log("BASELINE swap (no hook):", gasUsed);
    }

    function test_gasBenchmark_baseline_addLiquidity() public {
        PoolKey memory noHookKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(0)));
        manager.initialize(noHookKey, SQRT_PRICE_1_1);

        uint256 gasBefore = gasleft();
        modifyLiquidityRouter.modifyLiquidity(
            noHookKey,
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e18, salt: 0}),
            ""
        );
        uint256 gasUsed = gasBefore - gasleft();
        console.log("BASELINE addLiquidity (no hook):", gasUsed);
    }

    function test_gasBenchmark_baseline_removeLiquidity() public {
        PoolKey memory noHookKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(0)));
        manager.initialize(noHookKey, SQRT_PRICE_1_1);

        modifyLiquidityRouter.modifyLiquidity(
            noHookKey,
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 10e18, salt: 0}),
            ""
        );

        uint256 gasBefore = gasleft();
        modifyLiquidityRouter.modifyLiquidity(
            noHookKey,
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: -5e18, salt: 0}),
            ""
        );
        uint256 gasUsed = gasBefore - gasleft();
        console.log("BASELINE removeLiquidity (no hook):", gasUsed);
    }

    function test_gasBenchmark_recordLPRemoval() public {
        _initPoolWithIssuer();

        vm.warp(block.timestamp + 30 days);

        uint256 escrowId = uint256(keccak256(abi.encode(poolId, issuerAddr)));
        uint128 removable = escrowVault.getRemovableLiquidity(escrowId);

        uint256 gasBefore = gasleft();
        vm.prank(address(hook));
        escrowVault.recordLPRemoval(escrowId, removable);
        uint256 gasUsed = gasBefore - gasleft();
        console.log("recordLPRemoval:", gasUsed);
    }
}
