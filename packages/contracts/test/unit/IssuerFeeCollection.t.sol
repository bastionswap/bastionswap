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

contract MockReputation3 {
    function recordEvent(address, uint8, bytes calldata) external {}
    function getScore(address) external pure returns (uint256) { return 500; }
}

contract IssuerFeeCollectionTest is Test, Deployers {
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
            Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG |
            Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        address hookAddr = address(flags);

        MockReputation3 mockReputation = new MockReputation3();
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

        // Wire up routers
        bastionSwapRouter.setBastionHook(hookAddr);
        bastionPositionRouter.setBastionHook(hookAddr);

        // Set bastionRouter and _owner on hook (storage lost by vm.etch)
        // bastionRouter = slot 7, _owner = slot 8
        vm.store(hookAddr, bytes32(uint256(21)), bytes32(uint256(uint160(governance))));
        vm.prank(governance);
        hook.setBastionRouter(address(bastionPositionRouter));

        // Deploy tokens
        issuedToken = new MockERC20("Issued Token", "ISS", 18);
        baseToken = new MockERC20("Base Token", "BASE", 18);

        vm.prank(governance);
        hook.addBaseToken(address(baseToken), 0);

        // Mint tokens
        issuedToken.mint(issuerAddr, 1_000_000 ether);
        baseToken.mint(issuerAddr, 1_000_000 ether);
        issuedToken.mint(trader, 1_000_000 ether);
        baseToken.mint(trader, 1_000_000 ether);

        // Approve routers for issuer
        vm.startPrank(issuerAddr);
        issuedToken.approve(address(bastionPositionRouter), type(uint256).max);
        baseToken.approve(address(bastionPositionRouter), type(uint256).max);
        vm.stopPrank();

        // Approve routers for trader
        vm.startPrank(trader);
        issuedToken.approve(address(bastionPositionRouter), type(uint256).max);
        baseToken.approve(address(bastionPositionRouter), type(uint256).max);
        issuedToken.approve(address(bastionSwapRouter), type(uint256).max);
        baseToken.approve(address(bastionSwapRouter), type(uint256).max);
        vm.stopPrank();

        // Fund hook for any ETH needs
        vm.deal(address(hook), 1 ether);
    }

    // ═══════════════════════════════════════════════════════════════
    //  HELPERS
    // ═══════════════════════════════════════════════════════════════

    function _createPool() internal {
        IEscrowVault.IssuerCommitment memory commitment = IEscrowVault.IssuerCommitment({
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

        bytes memory hookData = abi.encode(
            issuerAddr, address(issuedToken), uint40(7 days), uint40(83 days), commitment, triggerConfig
        );

        vm.prank(issuerAddr);
        poolId = bastionPositionRouter.createPool(
            address(issuedToken),
            address(baseToken),
            3000,
            100 ether,
            SQRT_PRICE_1_1,
            hookData
        );

        // Reconstruct poolKey
        (Currency c0, Currency c1) = SortTokens.sort(issuedToken, baseToken);
        poolKey = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }

    function _generateFees() internal {
        _generateFeesWithTraderLP(true);
    }

    function _generateFeesWithTraderLP(bool addTraderLP) internal {
        if (addTraderLP) {
            // Add trader LP for deeper liquidity
            vm.prank(trader);
            bastionPositionRouter.addLiquidityV2(poolKey, 0, 0, 100 ether, 100 ether, block.timestamp + 3600);
        }

        // Execute swaps to generate fees
        vm.startPrank(trader);
        bastionSwapRouter.swapExactInput(poolKey, true, 1 ether, 0, block.timestamp + 3600);
        bastionSwapRouter.swapExactInput(poolKey, false, 1 ether, 0, block.timestamp + 3600);
        vm.stopPrank();
    }

    function _triggerEscrow() internal {
        vm.prank(address(hook));
        triggerOracle.reportCommitmentBreach(poolId);
        // Trigger happens immediately — no warp or executeTrigger needed
    }

    // ═══════════════════════════════════════════════════════════════
    //  TEST 1: Issuer can collect fees during lockup
    // ═══════════════════════════════════════════════════════════════

    function test_IssuerCollectFees_DuringLockup_Succeeds() public {
        _createPool();
        _generateFees();

        // Still in lockup period (< 7 days)
        uint256 issuer0Before = MockERC20(Currency.unwrap(poolKey.currency0)).balanceOf(issuerAddr);
        uint256 issuer1Before = MockERC20(Currency.unwrap(poolKey.currency1)).balanceOf(issuerAddr);

        vm.prank(issuerAddr);
        bastionPositionRouter.collectIssuerFees(poolKey);

        uint256 issuer0After = MockERC20(Currency.unwrap(poolKey.currency0)).balanceOf(issuerAddr);
        uint256 issuer1After = MockERC20(Currency.unwrap(poolKey.currency1)).balanceOf(issuerAddr);

        bool receivedFees = issuer0After > issuer0Before || issuer1After > issuer1Before;
        assertTrue(receivedFees, "Issuer should receive fees during lockup");
    }

    // ═══════════════════════════════════════════════════════════════
    //  TEST 2: Issuer can collect fees during vesting
    // ═══════════════════════════════════════════════════════════════

    function test_IssuerCollectFees_DuringVesting_Succeeds() public {
        _createPool();
        _generateFees();

        // Warp past lockup into vesting period
        vm.warp(block.timestamp + 7 days + 1);

        uint256 issuer0Before = MockERC20(Currency.unwrap(poolKey.currency0)).balanceOf(issuerAddr);
        uint256 issuer1Before = MockERC20(Currency.unwrap(poolKey.currency1)).balanceOf(issuerAddr);

        vm.prank(issuerAddr);
        bastionPositionRouter.collectIssuerFees(poolKey);

        uint256 issuer0After = MockERC20(Currency.unwrap(poolKey.currency0)).balanceOf(issuerAddr);
        uint256 issuer1After = MockERC20(Currency.unwrap(poolKey.currency1)).balanceOf(issuerAddr);

        bool receivedFees = issuer0After > issuer0Before || issuer1After > issuer1Before;
        assertTrue(receivedFees, "Issuer should receive fees during vesting");
    }

    // ═══════════════════════════════════════════════════════════════
    //  TEST 3: Issuer fee collection reverts after trigger
    // ═══════════════════════════════════════════════════════════════

    function test_IssuerCollectFees_AfterTrigger_Reverts() public {
        _createPool();
        _generateFees();

        // Trigger the escrow
        _triggerEscrow();

        // Issuer fee collection should revert
        vm.prank(issuerAddr);
        vm.expectRevert();
        bastionPositionRouter.collectIssuerFees(poolKey);
    }

    // ═══════════════════════════════════════════════════════════════
    //  TEST 4: Force removal collects unclaimed fees
    // ═══════════════════════════════════════════════════════════════

    function test_ForceRemoval_CollectsUnclaimedFees() public {
        _createPool();
        // Only use issuer's LP (no trader LP) so _totalLiquidity matches issuer position
        _generateFeesWithTraderLP(false);

        // Check InsurancePool balances before trigger
        uint256 ip0Before = MockERC20(Currency.unwrap(poolKey.currency0)).balanceOf(address(insurancePool));
        uint256 ip1Before = MockERC20(Currency.unwrap(poolKey.currency1)).balanceOf(address(insurancePool));

        // Trigger → force removal (collects fees + LP)
        _triggerEscrow();

        uint256 ip0After = MockERC20(Currency.unwrap(poolKey.currency0)).balanceOf(address(insurancePool));
        uint256 ip1After = MockERC20(Currency.unwrap(poolKey.currency1)).balanceOf(address(insurancePool));

        // InsurancePool should have received both LP assets and fees
        bool receivedFunds = ip0After > ip0Before || ip1After > ip1Before;
        assertTrue(receivedFunds, "InsurancePool should receive LP assets and fees from force removal");
    }
}
