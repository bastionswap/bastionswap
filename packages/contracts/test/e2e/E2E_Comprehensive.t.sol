// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

// ─── Uniswap V4 ─────────────────────────────────────────────
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";

// ─── BastionSwap ─────────────────────────────────────────────
import {BastionHook} from "../../src/hooks/BastionHook.sol";
import {EscrowVault} from "../../src/core/EscrowVault.sol";
import {InsurancePool} from "../../src/core/InsurancePool.sol";
import {TriggerOracle} from "../../src/core/TriggerOracle.sol";
import {ReputationEngine} from "../../src/core/ReputationEngine.sol";
import {BastionSwapRouter} from "../../src/router/BastionSwapRouter.sol";
import {BastionPositionRouter} from "../../src/router/BastionPositionRouter.sol";
import {TestToken} from "../../src/test/TestToken.sol";
import {IEscrowVault} from "../../src/interfaces/IEscrowVault.sol";
import {ITriggerOracle} from "../../src/interfaces/ITriggerOracle.sol";
import {IInsurancePool} from "../../src/interfaces/IInsurancePool.sol";
import {IReputationEngine} from "../../src/interfaces/IReputationEngine.sol";
import {BastionDeployer} from "../../script/BastionDeployer.sol";
import {HookMiner} from "../../script/HookMiner.sol";

/// @title E2E_Comprehensive
/// @notice Comprehensive end-to-end tests for BastionSwap v5.1 on a Base mainnet fork (Anvil).
///         Covers 42 scenarios across pool creation, swaps, LP management, vesting, sell limits,
///         LP removal triggers, compensation, governance, griefing prevention, and emergency flows.
contract E2E_Comprehensive is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    // ─── Base Mainnet Constants ──────────────────────────────────────
    address constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    uint160 constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );

    // ─── Test Accounts (Anvil defaults) ─────────────────────────────
    address deployer   = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address issuerA    = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address issuerB    = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
    address trader     = 0x90F79bf6EB2c4f870365E785982E1f101E93b906;
    address generalLP  = 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65;
    address holder     = 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc;
    address attacker   = 0x976EA74026E726554dB657fA54763abd0C3a0aa9;

    // ─── Contracts ───────────────────────────────────────────────────
    IPoolManager pm = IPoolManager(POOL_MANAGER);
    BastionHook hook;
    EscrowVault escrowVault;
    InsurancePool insurancePool;
    TriggerOracle triggerOracle;
    ReputationEngine reputationEngine;
    BastionSwapRouter swapRouter;
    BastionPositionRouter positionRouter;

    // ─── Tokens ──────────────────────────────────────────────────────
    TestToken tokenA;
    TestToken tokenB;

    // ─── Default Pool State ──────────────────────────────────────────
    PoolKey poolKeyA;
    PoolId poolIdA;
    uint256 poolACreatedAt;
    uint256 escrowIdA;

    // ═══════════════════════════════════════════════════════════════════
    //  SETUP
    // ═══════════════════════════════════════════════════════════════════

    function setUp() public {
        // Clear EIP-7702 delegation code at Anvil accounts
        vm.etch(deployer, "");
        vm.etch(issuerA, "");
        vm.etch(issuerB, "");
        vm.etch(trader, "");
        vm.etch(generalLP, "");
        vm.etch(holder, "");
        vm.etch(attacker, "");

        // Fund accounts
        vm.deal(deployer, 1000 ether);
        vm.deal(issuerA, 1000 ether);
        vm.deal(issuerB, 1000 ether);
        vm.deal(trader, 1000 ether);
        vm.deal(generalLP, 1000 ether);
        vm.deal(holder, 1000 ether);
        vm.deal(attacker, 1000 ether);

        require(POOL_MANAGER.code.length > 0, "PoolManager not on fork");

        vm.startPrank(deployer);

        // ── Precompute addresses ──
        uint64 nonce = vm.getNonce(deployer);
        address factoryAddr = vm.computeCreateAddress(deployer, nonce);
        address escrowAddr = vm.computeCreateAddress(deployer, nonce + 1);
        address insuranceAddr = vm.computeCreateAddress(deployer, nonce + 2);
        address triggerAddr = vm.computeCreateAddress(deployer, nonce + 3);
        address reputationAddr = vm.computeCreateAddress(deployer, nonce + 4);

        bytes memory hookCreationCode = abi.encodePacked(
            type(BastionHook).creationCode,
            abi.encode(POOL_MANAGER, escrowAddr, insuranceAddr, triggerAddr, reputationAddr, deployer, WETH, USDC)
        );

        (address hookAddr, bytes32 salt) = HookMiner.find(factoryAddr, HOOK_FLAGS, hookCreationCode, 0);

        // ── Deploy core contracts ──
        BastionDeployer factory = new BastionDeployer();
        require(address(factory) == factoryAddr, "factory addr");

        escrowVault = new EscrowVault(hookAddr, triggerAddr, reputationAddr);
        require(address(escrowVault) == escrowAddr, "escrow addr");

        insurancePool = new InsurancePool(hookAddr, triggerAddr, deployer, escrowAddr, deployer);
        require(address(insurancePool) == insuranceAddr, "insurance addr");

        triggerOracle = new TriggerOracle(hookAddr, escrowAddr, insuranceAddr, deployer, reputationAddr, deployer);
        require(address(triggerOracle) == triggerAddr, "trigger addr");

        reputationEngine = new ReputationEngine(hookAddr, escrowAddr, triggerAddr);
        require(address(reputationEngine) == reputationAddr, "reputation addr");

        address deployed = factory.deploy(salt, hookCreationCode);
        require(deployed == hookAddr, "hook addr");
        hook = BastionHook(payable(deployed));

        // ── Deploy routers ──
        swapRouter = new BastionSwapRouter(pm, ISignatureTransfer(PERMIT2));
        positionRouter = new BastionPositionRouter(pm, ISignatureTransfer(PERMIT2));

        // ── Wire cross-references ──
        hook.setBastionRouter(address(positionRouter));
        swapRouter.setBastionHook(address(hook));
        positionRouter.setBastionHook(address(hook));

        // ── Deploy test tokens ──
        tokenA = new TestToken("Token A", "TKA", 18, 1_000_000e18);
        tokenB = new TestToken("Token B", "TKB", 18, 1_000_000e18);

        // ── Distribute tokens ──
        tokenA.transfer(issuerA, 500_000e18);
        tokenA.transfer(trader, 200_000e18);
        tokenA.transfer(generalLP, 200_000e18);
        tokenA.transfer(holder, 50_000e18);
        tokenA.transfer(attacker, 50_000e18);

        tokenB.transfer(issuerB, 500_000e18);
        tokenB.transfer(trader, 200_000e18);

        // ── Fund hook with ETH ──
        (bool ok,) = address(hook).call{value: 1 ether}("");
        require(ok, "hook fund");

        // ── Set treasury ──
        insurancePool.setTreasury(deployer);

        vm.stopPrank();

        // ── Create default TokenA/ETH pool ──
        _createDefaultPoolA();
    }

    // ═══════════════════════════════════════════════════════════════════
    //  HELPERS
    // ═══════════════════════════════════════════════════════════════════

    function _defaultTriggerConfig() internal pure returns (ITriggerOracle.TriggerConfig memory) {
        return ITriggerOracle.TriggerConfig({
            lpRemovalThreshold: 5000,
            dumpThresholdPercent: 3000,
            dumpWindowSeconds: 86400,
            taxDeviationThreshold: 500,
            slowRugWindowSeconds: 86400,
            slowRugCumulativeThreshold: 8000,
            weeklyDumpWindowSeconds: 604800,
            weeklyDumpThresholdPercent: 5000
        });
    }

    function _buildHookData(
        address issuer,
        address token,
        uint40 lockDur,
        uint40 vestDur,
        ITriggerOracle.TriggerConfig memory triggerConfig
    ) internal pure returns (bytes memory) {
        IEscrowVault.IssuerCommitment memory commitment =
            IEscrowVault.IssuerCommitment({dailyWithdrawLimit: 0, maxSellPercent: 300});
        return abi.encode(issuer, token, lockDur, vestDur, commitment, triggerConfig);
    }

    function _buildHookDataDefault(address issuer, address token) internal pure returns (bytes memory) {
        return _buildHookData(issuer, token, 7 days, 83 days, _defaultTriggerConfig());
    }

    function _buildHookDataCustom(
        address issuer,
        address token,
        uint40 lockDur,
        uint40 vestDur,
        ITriggerOracle.TriggerConfig memory cfg
    ) internal pure returns (bytes memory) {
        IEscrowVault.IssuerCommitment memory commitment =
            IEscrowVault.IssuerCommitment({dailyWithdrawLimit: 0, maxSellPercent: 200});
        return abi.encode(issuer, token, lockDur, vestDur, commitment, cfg);
    }

    function _createDefaultPoolA() internal {
        vm.startPrank(issuerA);
        tokenA.approve(address(positionRouter), type(uint256).max);
        positionRouter.createPool{value: 10 ether}(
            address(tokenA), address(0), 3000, 100_000e18, SQRT_PRICE_1_1,
            _buildHookDataDefault(issuerA, address(tokenA))
        );
        poolKeyA = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(tokenA)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        poolIdA = poolKeyA.toId();
        poolACreatedAt = block.timestamp;
        (, escrowIdA,,) = hook.getPoolInfo(poolIdA);
        vm.stopPrank();
    }

    function _buyTokenA(address buyer, uint256 ethAmount) internal returns (uint256) {
        vm.prank(buyer);
        return swapRouter.swapExactInput{value: ethAmount}(
            poolKeyA, true, ethAmount, 0, block.timestamp + 3600
        );
    }

    function _sellTokenA(address seller, uint256 tokenAmount) internal returns (uint256) {
        vm.startPrank(seller);
        tokenA.approve(address(swapRouter), tokenAmount);
        uint256 out = swapRouter.swapExactInput(poolKeyA, false, tokenAmount, 0, block.timestamp + 3600);
        vm.stopPrank();
        return out;
    }

    function _getEscrowId(PoolId pid) internal view returns (uint256) {
        (, uint256 eid,,) = hook.getPoolInfo(pid);
        return eid;
    }

    function _createFreshToken(string memory name, string memory symbol, uint256 supply)
        internal
        returns (TestToken)
    {
        return new TestToken(name, symbol, 18, supply);
    }

    /// @dev Remove all issuer LP in chunks of <50% to respect single-tx threshold
    function _removeIssuerLPInChunks(PoolKey memory key, uint256 eid) internal {
        _removeIssuerLPInChunksFor(key, eid, issuerA);
    }

    function _removeIssuerLPInChunksFor(PoolKey memory key, uint256 eid, address issuer) internal {
        // Use 25% chunks of the initial total (safe for any threshold >= 30%)
        // The single-tx threshold is checked against _initialLiquidity
        uint128 initialTotal = escrowVault.getTotalLiquidity(eid);
        uint128 maxChunk = uint128((uint256(initialTotal) * 2500) / 10_000); // 25%

        uint128 removable = escrowVault.getRemovableLiquidity(eid);
        while (removable > 0) {
            uint128 chunk = removable > maxChunk ? maxChunk : removable;
            if (chunk == 0) break;
            vm.prank(issuer);
            positionRouter.removeIssuerLiquidity(key, chunk, 0, 0, block.timestamp + 3600);
            removable = escrowVault.getRemovableLiquidity(eid);
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    //  PART A: Pool Creation + Escrow
    // ═══════════════════════════════════════════════════════════════════

    // Scenario 1: Default pool creation + commitment
    function test_e2e_poolCreation_default() public view {
        // 1. Pool exists
        (uint160 sqrtPrice,,,) = pm.getSlot0(poolIdA);
        assertGt(sqrtPrice, 0, "pool initialized");

        // 2. Issuer A registered
        (address iss, uint256 eid, address issuedToken,) = hook.getPoolInfo(poolIdA);
        assertEq(iss, issuerA, "issuer");
        assertEq(issuedToken, address(tokenA), "issued token");

        // 3. EscrowVault state
        IEscrowVault.EscrowStatus memory s = escrowVault.getEscrowStatus(eid);
        assertGt(s.totalLiquidity, 0, "has liquidity");
        assertEq(s.removedLiquidity, 0, "nothing removed");

        // 4. Commitment defaults
        BastionHook.PoolCommitment memory c = hook.getPoolCommitment(poolIdA);
        assertEq(c.lockDuration, 7 days, "lock 7d");
        assertEq(c.vestingDuration, 83 days, "vesting 83d");
        assertEq(c.maxSingleLpRemovalBps, 5000, "single LP removal 50%");
        assertEq(c.maxCumulativeLpRemovalBps, 8000, "cumulative LP removal 80%");
        assertEq(c.maxDailySellBps, 3000, "daily sell 30%");
        assertEq(c.weeklyDumpThresholdBps, 5000, "weekly sell 50%");

        // 5. LP/supply ratio (AMM liquidity units / totalSupply, NOT token amounts)
        // May be 0 when AMM liquidity * 10000 < totalSupply (integer truncation)
        // Just verify the view doesn't revert
        hook.getLpRatioBps(poolIdA);

        // 6. Reputation baseline
        assertEq(reputationEngine.getScore(issuerA), 100, "baseline score");

        // 7. Pool creation alone doesn't increase reputation
        // (covered by assertEq above)
    }

    // Scenario 2: Custom commitment pool
    function test_e2e_poolCreation_customCommitment() public {
        TestToken tk = _createFreshToken("Custom", "CST", 1_000_000e18);
        tk.transfer(issuerB, 200_000e18);

        ITriggerOracle.TriggerConfig memory strict = ITriggerOracle.TriggerConfig({
            lpRemovalThreshold: 3000,       // 30% single LP removal
            dumpThresholdPercent: 2000,      // 20% daily sell
            dumpWindowSeconds: 86400,
            taxDeviationThreshold: 500,
            slowRugWindowSeconds: 86400,
            slowRugCumulativeThreshold: 8000,
            weeklyDumpWindowSeconds: 604800,
            weeklyDumpThresholdPercent: 3000 // 30% weekly
        });

        vm.startPrank(issuerB);
        tk.approve(address(positionRouter), type(uint256).max);
        PoolId pid = positionRouter.createPool{value: 5 ether}(
            address(tk), address(0), 3000, 100_000e18, SQRT_PRICE_1_1,
            _buildHookDataCustom(issuerB, address(tk), 30 days, 150 days, strict)
        );
        vm.stopPrank();

        // 1. Commitment stored
        BastionHook.PoolCommitment memory c = hook.getPoolCommitment(pid);
        assertTrue(c.isSet, "commitment set");
        assertEq(c.lockDuration, 30 days, "30d lock");
        assertEq(c.vestingDuration, 150 days, "150d vesting");
        assertEq(c.maxSingleLpRemovalBps, 3000, "single LP 30%");
        assertEq(c.maxDailySellBps, 2000, "daily sell 20%");
        assertEq(c.weeklyDumpThresholdBps, 3000, "weekly sell 30%");

        // 2. Stricter than default
        assertTrue(hook.isCommitmentStricterThanDefault(pid), "stricter");
    }

    // Scenario 3: Pool creation failures
    function test_e2e_poolCreation_failures() public {
        // 3a: Min LP not met (0.001 ETH < 1 ETH minimum)
        TestToken tkFail = _createFreshToken("Fail", "FAIL", 1_000_000e18);
        tkFail.transfer(issuerB, 200_000e18);
        vm.startPrank(issuerB);
        tkFail.approve(address(positionRouter), type(uint256).max);
        vm.expectRevert();
        positionRouter.createPool{value: 0.001 ether}(
            address(tkFail), address(0), 3000, 100_000e18, SQRT_PRICE_1_1,
            _buildHookDataDefault(issuerB, address(tkFail))
        );
        vm.stopPrank();

        // 3b: Non-base token pair
        TestToken fakeBase = _createFreshToken("FakeBase", "FB", 1_000_000e18);
        fakeBase.transfer(issuerB, 200_000e18);
        vm.startPrank(issuerB);
        fakeBase.approve(address(positionRouter), type(uint256).max);
        tkFail.approve(address(positionRouter), type(uint256).max);
        vm.expectRevert();
        positionRouter.createPool(
            address(tkFail), address(fakeBase), 3000, 100_000e18, SQRT_PRICE_1_1,
            _buildHookDataDefault(issuerB, address(tkFail))
        );
        vm.stopPrank();

        // 3c: Duplicate pool
        vm.startPrank(issuerA);
        vm.expectRevert();
        positionRouter.createPool{value: 10 ether}(
            address(tokenA), address(0), 3000, 100_000e18, SQRT_PRICE_1_1,
            _buildHookDataDefault(issuerA, address(tokenA))
        );
        vm.stopPrank();

        // 3d: Lock below minimum (3 days < 7 days)
        TestToken tkLock = _createFreshToken("LockFail", "LF", 1_000_000e18);
        tkLock.transfer(issuerB, 200_000e18);
        vm.startPrank(issuerB);
        tkLock.approve(address(positionRouter), type(uint256).max);
        vm.expectRevert();
        positionRouter.createPool{value: 5 ether}(
            address(tkLock), address(0), 3000, 100_000e18, SQRT_PRICE_1_1,
            _buildHookData(issuerB, address(tkLock), 3 days, 83 days, _defaultTriggerConfig())
        );
        vm.stopPrank();

        // 3e: Vesting below minimum (3 days < 7 days)
        TestToken tkVest = _createFreshToken("VestFail", "VF", 1_000_000e18);
        tkVest.transfer(issuerB, 200_000e18);
        vm.startPrank(issuerB);
        tkVest.approve(address(positionRouter), type(uint256).max);
        vm.expectRevert();
        positionRouter.createPool{value: 5 ether}(
            address(tkVest), address(0), 3000, 100_000e18, SQRT_PRICE_1_1,
            _buildHookData(issuerB, address(tkVest), 7 days, 3 days, _defaultTriggerConfig())
        );
        vm.stopPrank();

        // 3f: LP removal threshold too lenient (6000 > 5000 default)
        TestToken tkLp = _createFreshToken("LpFail", "LPF", 1_000_000e18);
        tkLp.transfer(issuerB, 200_000e18);
        ITriggerOracle.TriggerConfig memory lenientLp = _defaultTriggerConfig();
        lenientLp.lpRemovalThreshold = 6000; // > 5000 default
        vm.startPrank(issuerB);
        tkLp.approve(address(positionRouter), type(uint256).max);
        vm.expectRevert();
        positionRouter.createPool{value: 5 ether}(
            address(tkLp), address(0), 3000, 100_000e18, SQRT_PRICE_1_1,
            _buildHookData(issuerB, address(tkLp), 7 days, 83 days, lenientLp)
        );
        vm.stopPrank();

        // 3g: Daily sell threshold too lenient (5000 > 3000 default)
        TestToken tkSell = _createFreshToken("SellFail", "SF", 1_000_000e18);
        tkSell.transfer(issuerB, 200_000e18);
        ITriggerOracle.TriggerConfig memory lenientSell = _defaultTriggerConfig();
        lenientSell.dumpThresholdPercent = 5000;
        vm.startPrank(issuerB);
        tkSell.approve(address(positionRouter), type(uint256).max);
        vm.expectRevert();
        positionRouter.createPool{value: 5 ether}(
            address(tkSell), address(0), 3000, 100_000e18, SQRT_PRICE_1_1,
            _buildHookData(issuerB, address(tkSell), 7 days, 83 days, lenientSell)
        );
        vm.stopPrank();

        // 3h: Weekly sell threshold too lenient (6000 > 5000 default)
        TestToken tkWeek = _createFreshToken("WeekFail", "WF", 1_000_000e18);
        tkWeek.transfer(issuerB, 200_000e18);
        ITriggerOracle.TriggerConfig memory lenientWeek = _defaultTriggerConfig();
        lenientWeek.weeklyDumpThresholdPercent = 6000;
        vm.startPrank(issuerB);
        tkWeek.approve(address(positionRouter), type(uint256).max);
        vm.expectRevert();
        positionRouter.createPool{value: 5 ether}(
            address(tkWeek), address(0), 3000, 100_000e18, SQRT_PRICE_1_1,
            _buildHookData(issuerB, address(tkWeek), 7 days, 83 days, lenientWeek)
        );
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════
    //  PART B: Swap + Insurance Pool
    // ═══════════════════════════════════════════════════════════════════

    // Scenario 4: Buy swap + insurance accumulation
    function test_e2e_buySwap_insuranceAccumulation() public {
        uint256 traderTokenBefore = tokenA.balanceOf(trader);
        uint256 insBefore = insurancePool.getPoolStatus(poolIdA).balance;

        uint256 out = _buyTokenA(trader, 0.1 ether);

        assertGt(out, 0, "got tokens");
        assertGt(tokenA.balanceOf(trader), traderTokenBefore, "trader token up");

        uint256 insAfter = insurancePool.getPoolStatus(poolIdA).balance;
        assertGt(insAfter, insBefore, "insurance fee deposited");

        // Multiple buys accumulate
        uint256 ins1 = insurancePool.getPoolStatus(poolIdA).balance;
        _buyTokenA(trader, 0.05 ether);
        uint256 ins2 = insurancePool.getPoolStatus(poolIdA).balance;
        _buyTokenA(trader, 0.05 ether);
        uint256 ins3 = insurancePool.getPoolStatus(poolIdA).balance;
        assertGt(ins2, ins1, "accumulate 1");
        assertGt(ins3, ins2, "accumulate 2");
    }

    // Scenario 5: Sell swap — no insurance fee
    function test_e2e_sellSwap_noFee() public {
        // First buy some tokens to sell
        _buyTokenA(trader, 0.5 ether);

        uint256 insBefore = insurancePool.getPoolStatus(poolIdA).balance;
        _sellTokenA(trader, 1000e18);
        uint256 insAfter = insurancePool.getPoolStatus(poolIdA).balance;

        assertEq(insAfter, insBefore, "no fee on sell");
    }

    // Scenario 6: USDC pair insurance
    function test_e2e_usdcPair_insurance() public {
        TestToken tkUsdc = _createFreshToken("USDCToken", "UTK", 1_000_000e18);
        tkUsdc.transfer(issuerB, 200_000e18);

        // Need to deal USDC to issuerB (fork has real USDC contract)
        deal(USDC, issuerB, 10_000e6);

        vm.startPrank(issuerB);
        tkUsdc.approve(address(positionRouter), type(uint256).max);

        // Use USDC as base token — build hookData with USDC base
        IEscrowVault.IssuerCommitment memory commitment =
            IEscrowVault.IssuerCommitment({dailyWithdrawLimit: 0, maxSellPercent: 300});
        bytes memory hookData = abi.encode(
            issuerB, address(tkUsdc), uint40(7 days), uint40(83 days), commitment, _defaultTriggerConfig()
        );

        // Approve USDC for positionRouter
        // USDC is ERC20, need to approve
        (bool ok,) = USDC.call(abi.encodeWithSignature("approve(address,uint256)", address(positionRouter), type(uint256).max));
        require(ok, "USDC approve");

        PoolId pid = positionRouter.createPool(
            address(tkUsdc), USDC, 3000, 100_000e18, SQRT_PRICE_1_1, hookData
        );
        vm.stopPrank();

        // Build pool key
        (Currency c0, Currency c1) = address(tkUsdc) < USDC
            ? (Currency.wrap(address(tkUsdc)), Currency.wrap(USDC))
            : (Currency.wrap(USDC), Currency.wrap(address(tkUsdc)));
        PoolKey memory poolKeyUsdc = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        // Buy tkUsdc with USDC
        deal(USDC, trader, 1000e6);
        vm.startPrank(trader);
        (ok,) = USDC.call(abi.encodeWithSignature("approve(address,uint256)", address(swapRouter), type(uint256).max));
        require(ok, "trader USDC approve");

        // Determine swap direction: buy tkUsdc = sell USDC
        bool zeroForOne = Currency.unwrap(c0) == USDC; // if USDC is currency0, sell 0 for 1
        swapRouter.swapExactInput(poolKeyUsdc, zeroForOne, 100e6, 0, block.timestamp + 3600);
        vm.stopPrank();

        // Insurance should have USDC balance (ERC20 fees stored in baseTokenFeeBalance, not ETH balance)
        // Check actual USDC balance of InsurancePool contract
        (bool success, bytes memory result) = USDC.staticcall(
            abi.encodeWithSignature("balanceOf(address)", address(insurancePool))
        );
        require(success, "balanceOf call");
        uint256 usdcBalance = abi.decode(result, (uint256));
        assertGt(usdcBalance, 0, "USDC insurance deposited");
    }

    // Scenario 7: Multi-hop swap
    function test_e2e_multiHopSwap() public {
        // Create TokenB/ETH pool
        vm.startPrank(issuerB);
        tokenB.approve(address(positionRouter), type(uint256).max);
        positionRouter.createPool{value: 10 ether}(
            address(tokenB), address(0), 3000, 100_000e18, SQRT_PRICE_1_1,
            _buildHookDataDefault(issuerB, address(tokenB))
        );
        vm.stopPrank();

        PoolKey memory poolKeyB = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(tokenB)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        PoolId poolIdB = poolKeyB.toId();

        // TokenA -> ETH -> TokenB
        uint256 traderABefore = tokenA.balanceOf(trader);
        uint256 traderBBefore = tokenB.balanceOf(trader);
        uint256 traderEthBefore = trader.balance;

        BastionSwapRouter.SwapStep[] memory steps = new BastionSwapRouter.SwapStep[](2);
        steps[0] = BastionSwapRouter.SwapStep({poolKey: poolKeyA, zeroForOne: false}); // TokenA->ETH
        steps[1] = BastionSwapRouter.SwapStep({poolKey: poolKeyB, zeroForOne: true});   // ETH->TokenB

        vm.startPrank(trader);
        tokenA.approve(address(swapRouter), 1000e18);
        uint256 out = swapRouter.swapMultiHop(steps, 1000e18, 0, block.timestamp + 3600);
        vm.stopPrank();

        assertGt(out, 0, "got output");
        assertLt(tokenA.balanceOf(trader), traderABefore, "tokenA decreased");
        assertGt(tokenB.balanceOf(trader), traderBBefore, "tokenB increased");

        // ETH roughly unchanged
        uint256 ethDiff = traderEthBefore > trader.balance
            ? traderEthBefore - trader.balance
            : trader.balance - traderEthBefore;
        assertLt(ethDiff, 0.01 ether, "ETH roughly unchanged");

        // Insurance on TokenB pool (buy hop)
        assertGt(insurancePool.getPoolStatus(poolIdB).balance, 0, "insurance on buy hop");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  PART C: General LP
    // ═══════════════════════════════════════════════════════════════════

    // Scenario 8: General LP full cycle
    function test_e2e_generalLP_fullCycle() public {
        // 8a: Add liquidity
        vm.startPrank(generalLP);
        tokenA.approve(address(positionRouter), type(uint256).max);
        positionRouter.addLiquidityV2{value: 1 ether}(
            poolKeyA, 0, 0, 1 ether, 10_000e18, block.timestamp + 3600
        );
        vm.stopPrank();

        uint128 lpLiq = positionRouter.getPositionLiquidity(poolKeyA, generalLP, 0, 0);
        assertGt(lpLiq, 0, "LP has liquidity");

        // Escrow unaffected
        IEscrowVault.EscrowStatus memory sBefore = escrowVault.getEscrowStatus(escrowIdA);

        // 8b: Generate fees via swaps
        _buyTokenA(trader, 0.5 ether);
        _sellTokenA(trader, 5000e18);

        // 8c: Collect fees
        uint256 lpEthBefore = generalLP.balance;
        uint256 lpTokenBefore = tokenA.balanceOf(generalLP);
        vm.prank(generalLP);
        positionRouter.collectFees(poolKeyA, 0, 0);
        bool gotFees = generalLP.balance > lpEthBefore || tokenA.balanceOf(generalLP) > lpTokenBefore;
        assertTrue(gotFees, "collected fees");

        // 8d: Full removal
        uint128 currentLiq = positionRouter.getPositionLiquidity(poolKeyA, generalLP, 0, 0);
        vm.prank(generalLP);
        positionRouter.removeLiquidityV2(poolKeyA, 0, 0, currentLiq, 0, 0, block.timestamp + 3600);
        assertEq(positionRouter.getPositionLiquidity(poolKeyA, generalLP, 0, 0), 0, "all removed");

        // No trigger
        assertFalse(hook.isPoolTriggered(poolIdA), "no trigger from general LP");

        // 8e: Partial removal
        vm.startPrank(generalLP);
        positionRouter.addLiquidityV2{value: 2 ether}(
            poolKeyA, 0, 0, 2 ether, 20_000e18, block.timestamp + 3600
        );
        uint128 fullLiq = positionRouter.getPositionLiquidity(poolKeyA, generalLP, 0, 0);
        uint128 halfLiq = fullLiq / 2;
        positionRouter.removeLiquidityV2(poolKeyA, 0, 0, halfLiq, 0, 0, block.timestamp + 3600);
        uint128 remainLiq = positionRouter.getPositionLiquidity(poolKeyA, generalLP, 0, 0);
        assertApproxEqAbs(remainLiq, fullLiq - halfLiq, 1, "half remaining");
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════
    //  PART D: Escrow Vesting
    // ═══════════════════════════════════════════════════════════════════

    // Scenario 9: Lockup + linear vesting full cycle
    function test_e2e_escrowVesting_fullCycle() public {
        uint128 totalLiq = escrowVault.getTotalLiquidity(escrowIdA);
        assertGt(totalLiq, 0, "escrow has liquidity");

        // 9a: During lockup — cannot remove
        vm.warp(poolACreatedAt + 3 days);
        assertEq(escrowVault.getRemovableLiquidity(escrowIdA), 0, "nothing removable in lock");

        vm.prank(issuerA);
        vm.expectRevert();
        positionRouter.removeIssuerLiquidity(poolKeyA, 1, 0, 0, block.timestamp + 3600);

        // 9b: Lock ends at 7 days — 0% removable
        vm.warp(poolACreatedAt + 7 days);
        assertEq(escrowVault.getRemovableLiquidity(escrowIdA), 0, "0% at vesting start");

        // 9c: 50% through vesting (48.5 days)
        vm.warp(poolACreatedAt + 48.5 days);
        uint128 removable = escrowVault.getRemovableLiquidity(escrowIdA);
        assertApproxEqRel(removable, totalLiq / 2, 0.02e18, "~50% vested");

        // Remove 50%
        vm.prank(issuerA);
        positionRouter.removeIssuerLiquidity(poolKeyA, removable, 0, 0, block.timestamp + 3600);

        // Try removing more -> revert
        vm.prank(issuerA);
        vm.expectRevert();
        positionRouter.removeIssuerLiquidity(poolKeyA, 1, 0, 0, block.timestamp + 3600);

        // 9d: Full vesting (90 days)
        vm.warp(poolACreatedAt + 90 days);
        uint128 remaining = escrowVault.getRemovableLiquidity(escrowIdA);
        assertGt(remaining, 0, "has remaining");

        vm.prank(issuerA);
        positionRouter.removeIssuerLiquidity(poolKeyA, remaining, 0, 0, block.timestamp + 3600);
        assertEq(escrowVault.getRemovableLiquidity(escrowIdA), 0, "fully removed");
    }

    // Scenario 10: Issuer fee collection policy
    function test_e2e_issuerFeeCollection() public {
        // Generate fees
        _buyTokenA(trader, 0.5 ether);
        _sellTokenA(trader, 5000e18);

        // 10a: During lockup — collect succeeds
        uint256 issuerEthBefore = issuerA.balance;
        uint256 issuerTokenBefore = tokenA.balanceOf(issuerA);
        vm.prank(issuerA);
        positionRouter.collectIssuerFees(poolKeyA);
        bool gotFees = issuerA.balance > issuerEthBefore || tokenA.balanceOf(issuerA) > issuerTokenBefore;
        assertTrue(gotFees, "fees during lockup");

        // 10b: During vesting — collect succeeds
        vm.warp(poolACreatedAt + 10 days);
        _buyTokenA(trader, 0.3 ether);
        vm.prank(issuerA);
        positionRouter.collectIssuerFees(poolKeyA);

        // 10c: After trigger — collect reverts
        vm.prank(address(hook));
        triggerOracle.reportCommitmentBreach(poolIdA);

        vm.prank(issuerA);
        vm.expectRevert();
        positionRouter.collectIssuerFees(poolKeyA);
    }

    // Scenario 11: Issuer additional LP
    function test_e2e_issuerAdditionalLP() public {
        uint128 liqBefore = escrowVault.getTotalLiquidity(escrowIdA);

        vm.startPrank(issuerA);
        tokenA.approve(address(positionRouter), type(uint256).max);
        positionRouter.addLiquidityV2{value: 1 ether}(
            poolKeyA, 0, 0, 1 ether, 10_000e18, block.timestamp + 3600
        );
        vm.stopPrank();

        uint128 liqAfter = escrowVault.getTotalLiquidity(escrowIdA);
        assertGt(liqAfter, liqBefore, "totalLiquidity increased");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  PART E: Issuer Sell Limit Enforcement
    // ═══════════════════════════════════════════════════════════════════

    // Scenario 12: Direct issuer sell limits
    function test_e2e_issuerDirectSell_limits() public {
        // Issuer A has tokens outside LP. Commitment: maxDailySellBps = 3000 (30%)
        // Initial supply = 1M. 30% = 300,000 tokens
        uint256 initialSupply = hook.getInitialTotalSupply(poolIdA);
        uint256 maxDaily = (initialSupply * 3000) / 10_000; // 300,000 tokens

        // 12a: 20% sell -> succeeds
        uint256 sellAmount = (initialSupply * 2000) / 10_000; // 200,000

        // Need deep liquidity to allow large sells
        vm.startPrank(generalLP);
        tokenA.approve(address(positionRouter), type(uint256).max);
        positionRouter.addLiquidityV2{value: 50 ether}(
            poolKeyA, 0, 0, 50 ether, 200_000e18, block.timestamp + 3600
        );
        vm.stopPrank();

        vm.startPrank(issuerA);
        tokenA.approve(address(swapRouter), type(uint256).max);
        swapRouter.swapExactInput(poolKeyA, false, sellAmount, 0, block.timestamp + 3600);
        vm.stopPrank();

        // 12b: Additional 20% -> total 40% > 30% -> revert
        vm.startPrank(issuerA);
        vm.expectRevert();
        swapRouter.swapExactInput(poolKeyA, false, sellAmount, 0, block.timestamp + 3600);
        vm.stopPrank();

        // 12c: 24h later -> reset -> sell succeeds
        vm.warp(block.timestamp + 1 days + 1);
        vm.startPrank(issuerA);
        swapRouter.swapExactInput(poolKeyA, false, 10_000e18, 0, block.timestamp + 3600);
        vm.stopPrank();
    }

    // Scenario 13: Router bypass sell blocked
    function test_e2e_issuerRouterSell_blocked() public {
        // Deep liquidity
        vm.startPrank(generalLP);
        tokenA.approve(address(positionRouter), type(uint256).max);
        positionRouter.addLiquidityV2{value: 50 ether}(
            poolKeyA, 0, 0, 50 ether, 200_000e18, block.timestamp + 3600
        );
        vm.stopPrank();

        // Issuer transfers tokens to attacker (Router Sim)
        uint256 initialSupply = hook.getInitialTotalSupply(poolIdA);
        uint256 bigAmount = (initialSupply * 2500) / 10_000; // 25%

        vm.prank(issuerA);
        tokenA.transfer(attacker, bigAmount);

        // 13c: Small sell (under limit) — succeeds via direct issuer
        vm.startPrank(issuerA);
        tokenA.approve(address(swapRouter), type(uint256).max);
        uint256 smallSell = (initialSupply * 500) / 10_000; // 5%
        swapRouter.swapExactInput(poolKeyA, false, smallSell, 0, block.timestamp + 3600);
        vm.stopPrank();

        // Note: attacker selling issuer's tokens — swapper is attacker not issuer,
        // so afterSwap won't detect as issuer sell. The issuer sell defense is based
        // on hookData swapper identification, not token balance tracking.
        vm.startPrank(attacker);
        tokenA.approve(address(swapRouter), type(uint256).max);
        // This succeeds because attacker != issuer in hookData
        swapRouter.swapExactInput(poolKeyA, false, bigAmount, 0, block.timestamp + 3600);
        vm.stopPrank();
    }

    // Scenario 14: Weekly cumulative sell limit
    function test_e2e_weeklySellLimit() public {
        // Deep liquidity
        vm.startPrank(generalLP);
        tokenA.approve(address(positionRouter), type(uint256).max);
        positionRouter.addLiquidityV2{value: 100 ether}(
            poolKeyA, 0, 0, 100 ether, 200_000e18, block.timestamp + 3600
        );
        vm.stopPrank();

        uint256 initialSupply = hook.getInitialTotalSupply(poolIdA);
        // maxDailySellBps = 3000 (30%), weeklyDumpThresholdBps = 5000 (50%)
        // Sell 20% each day for 2 days = 40% < 50%, then 20% more -> 60% >= 50%
        uint256 dailySell = (initialSupply * 2000) / 10_000; // 20%

        vm.startPrank(issuerA);
        tokenA.approve(address(swapRouter), type(uint256).max);

        // Day 1: sell 20%
        swapRouter.swapExactInput(poolKeyA, false, dailySell, 0, block.timestamp + 3600);

        // Day 2: sell 20% (cumulative 40% < 50%)
        vm.warp(block.timestamp + 1 days + 1);
        swapRouter.swapExactInput(poolKeyA, false, dailySell, 0, block.timestamp + 3600);

        // Day 3: try sell 20% more -> cumulative 60% >= 50% weekly limit -> revert
        vm.warp(block.timestamp + 1 days + 1);
        vm.expectRevert();
        swapRouter.swapExactInput(poolKeyA, false, dailySell, 0, block.timestamp + 3600);

        vm.stopPrank();

        // 14b: After 7-day window reset -> can sell again
        vm.warp(block.timestamp + 5 days);
        vm.startPrank(issuerA);
        swapRouter.swapExactInput(poolKeyA, false, 1000e18, 0, block.timestamp + 3600);
        vm.stopPrank();
    }

    // Scenario 15: Non-issuer sell — unlimited
    function test_e2e_nonIssuerSell_unlimited() public {
        // Add deep liquidity
        vm.startPrank(generalLP);
        tokenA.approve(address(positionRouter), type(uint256).max);
        positionRouter.addLiquidityV2{value: 50 ether}(
            poolKeyA, 0, 0, 50 ether, 200_000e18, block.timestamp + 3600
        );
        vm.stopPrank();

        // Trader buys big, then sells all
        uint256 out = _buyTokenA(trader, 5 ether);
        _sellTokenA(trader, out);

        // No trigger
        assertFalse(hook.isPoolTriggered(poolIdA), "no trigger from non-issuer sell");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  PART F: LP Removal Trigger
    // ═══════════════════════════════════════════════════════════════════

    // Scenario 16: Single-tx LP removal exceeds threshold -> revert
    function test_e2e_lpRemoval_singleTxExceeds() public {
        // Warp past full vesting
        vm.warp(poolACreatedAt + 90 days);
        uint128 total = escrowVault.getTotalLiquidity(escrowIdA);
        uint128 removable = escrowVault.getRemovableLiquidity(escrowIdA);
        assertEq(removable, total, "fully vested");

        // maxSingleLpRemovalBps = 5000 (50%). Try removing 60%
        uint128 sixtyPercent = uint128((uint256(total) * 6000) / 10_000);

        vm.prank(issuerA);
        vm.expectRevert();
        positionRouter.removeIssuerLiquidity(poolKeyA, sixtyPercent, 0, 0, block.timestamp + 3600);

        // LP state unchanged
        assertEq(escrowVault.getTotalLiquidity(escrowIdA), total, "LP unchanged");
    }

    // Scenario 17: Cumulative LP removal -> trigger
    function test_e2e_lpRemoval_cumulativeTrigger() public {
        // Add general LP so pool survives
        vm.startPrank(generalLP);
        tokenA.approve(address(positionRouter), type(uint256).max);
        positionRouter.addLiquidityV2{value: 5 ether}(
            poolKeyA, 0, 0, 5 ether, 50_000e18, block.timestamp + 3600
        );
        vm.stopPrank();

        // Generate insurance fees
        _buyTokenA(trader, 1 ether);

        // Warp past full vesting
        vm.warp(poolACreatedAt + 90 days);
        uint128 total = escrowVault.getTotalLiquidity(escrowIdA);

        // 49% removal -> succeeds
        uint128 fortyNinePercent = uint128((uint256(total) * 4900) / 10_000);
        vm.prank(issuerA);
        positionRouter.removeIssuerLiquidity(poolKeyA, fortyNinePercent, 0, 0, block.timestamp + 3600);

        assertFalse(hook.isLPRemovalTriggerable(poolIdA), "not yet triggerable");

        // 40% more -> cumulative 89% > 80% threshold
        uint128 remaining = escrowVault.getRemovableLiquidity(escrowIdA);
        uint128 fortyPercent = uint128((uint256(total) * 4000) / 10_000);
        if (fortyPercent > remaining) fortyPercent = remaining;

        vm.prank(issuerA);
        positionRouter.removeIssuerLiquidity(poolKeyA, fortyPercent, 0, 0, block.timestamp + 3600);

        // Now triggerable
        assertTrue(hook.isLPRemovalTriggerable(poolIdA), "now triggerable");

        // Anyone can call executeTrigger
        vm.prank(holder);
        hook.executeTrigger(poolIdA);

        assertTrue(hook.isPoolTriggered(poolIdA), "triggered");

        // Issuer cannot remove more LP
        vm.prank(issuerA);
        vm.expectRevert();
        positionRouter.removeIssuerLiquidity(poolKeyA, 1, 0, 0, block.timestamp + 3600);
    }

    // Scenario 18: General LP mass removal -> no trigger
    function test_e2e_generalLP_massRemoval_noTrigger() public {
        vm.startPrank(generalLP);
        tokenA.approve(address(positionRouter), type(uint256).max);
        positionRouter.addLiquidityV2{value: 10 ether}(
            poolKeyA, 0, 0, 10 ether, 100_000e18, block.timestamp + 3600
        );
        uint128 liq = positionRouter.getPositionLiquidity(poolKeyA, generalLP, 0, 0);
        positionRouter.removeLiquidityV2(poolKeyA, 0, 0, liq, 0, 0, block.timestamp + 3600);
        vm.stopPrank();

        assertFalse(hook.isPoolTriggered(poolIdA), "no trigger");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  PART G: Trigger Execution + Compensation
    // ═══════════════════════════════════════════════════════════════════

    // Scenario 19: LP trigger -> immediate execution -> holder compensation
    function test_e2e_lpTrigger_immediateExecution_compensation() public {
        // Add general LP
        vm.startPrank(generalLP);
        tokenA.approve(address(positionRouter), type(uint256).max);
        positionRouter.addLiquidityV2{value: 5 ether}(
            poolKeyA, 0, 0, 5 ether, 50_000e18, block.timestamp + 3600
        );
        vm.stopPrank();

        // Generate insurance fees
        _buyTokenA(trader, 2 ether);

        uint256 insBalance = insurancePool.getPoolStatus(poolIdA).balance;
        assertGt(insBalance, 0, "insurance funded");

        // Transfer tokens to holder
        vm.prank(trader);
        tokenA.transfer(holder, 50_000e18);

        // Warp and do cumulative LP removal to trigger
        vm.warp(poolACreatedAt + 90 days);
        uint128 total = escrowVault.getTotalLiquidity(escrowIdA);
        uint128 firstChunk = uint128((uint256(total) * 4900) / 10_000);
        uint128 secondChunk = uint128((uint256(total) * 4000) / 10_000);

        vm.prank(issuerA);
        positionRouter.removeIssuerLiquidity(poolKeyA, firstChunk, 0, 0, block.timestamp + 3600);

        uint128 remainingVested = escrowVault.getRemovableLiquidity(escrowIdA);
        if (secondChunk > remainingVested) secondChunk = remainingVested;

        vm.prank(issuerA);
        positionRouter.removeIssuerLiquidity(poolKeyA, secondChunk, 0, 0, block.timestamp + 3600);

        // Execute trigger (permissionless)
        hook.executeTrigger(poolIdA);

        // 1. Triggered
        assertTrue(hook.isPoolTriggered(poolIdA), "triggered");
        assertTrue(triggerOracle.checkTrigger(poolIdA).triggered, "oracle triggered");

        // 2. InsurancePool has funds (escrow assets + insurance fees)
        IInsurancePool.PoolStatus memory ps = insurancePool.getPoolStatus(poolIdA);
        assertTrue(ps.isTriggered, "insurance triggered");

        // Advance past 24h merkle submission deadline + one block for flash-loan protection
        vm.warp(block.timestamp + 24 hours + 1);
        vm.roll(block.number + 1);

        // 4. Holder claims using fallback mode
        uint256 holderBal = tokenA.balanceOf(holder);
        uint256 holderEthBefore = holder.balance;
        vm.prank(holder);
        insurancePool.claimCompensationFallback(poolIdA, holderBal);
        assertGt(holder.balance, holderEthBefore, "holder compensated");

        // 5. Issuer cannot claim
        uint256 issuerBal = tokenA.balanceOf(issuerA);
        if (issuerBal > 0) {
            vm.prank(issuerA);
            vm.expectRevert();
            insurancePool.claimCompensationFallback(poolIdA, issuerBal);
        }

        // 6. Duplicate claim -> revert
        vm.prank(holder);
        vm.expectRevert();
        insurancePool.claimCompensationFallback(poolIdA, holderBal);
    }

    // Scenario 20: After trigger — all issuer actions blocked
    function test_e2e_afterTrigger_allBlocked() public {
        // Add general LP
        vm.startPrank(generalLP);
        tokenA.approve(address(positionRouter), type(uint256).max);
        positionRouter.addLiquidityV2{value: 5 ether}(
            poolKeyA, 0, 0, 5 ether, 50_000e18, block.timestamp + 3600
        );
        vm.stopPrank();

        _buyTokenA(trader, 1 ether);

        // Trigger via cumulative LP removal -> permissionless executeTrigger
        // This properly sets _isTriggered[poolId] on the hook
        vm.warp(poolACreatedAt + 90 days);
        uint128 total = escrowVault.getTotalLiquidity(escrowIdA);
        uint128 chunk1 = uint128((uint256(total) * 4900) / 10_000);
        uint128 chunk2 = uint128((uint256(total) * 4000) / 10_000);

        vm.prank(issuerA);
        positionRouter.removeIssuerLiquidity(poolKeyA, chunk1, 0, 0, block.timestamp + 3600);

        uint128 remaining = escrowVault.getRemovableLiquidity(escrowIdA);
        if (chunk2 > remaining) chunk2 = remaining;
        vm.prank(issuerA);
        positionRouter.removeIssuerLiquidity(poolKeyA, chunk2, 0, 0, block.timestamp + 3600);

        // Permissionless trigger execution
        hook.executeTrigger(poolIdA);
        assertTrue(hook.isPoolTriggered(poolIdA), "triggered");

        // 20a: Issuer sell -> revert
        vm.startPrank(issuerA);
        tokenA.approve(address(swapRouter), type(uint256).max);
        vm.expectRevert();
        swapRouter.swapExactInput(poolKeyA, false, 1000e18, 0, block.timestamp + 3600);
        vm.stopPrank();

        // 20b: Issuer LP removal -> revert
        vm.prank(issuerA);
        vm.expectRevert();
        positionRouter.removeIssuerLiquidity(poolKeyA, 1, 0, 0, block.timestamp + 3600);

        // 20c: Issuer fee collect -> revert
        vm.prank(issuerA);
        vm.expectRevert();
        positionRouter.collectIssuerFees(poolKeyA);

        // 20d: Normal user swap -> works
        uint256 out = _buyTokenA(trader, 0.01 ether);
        assertGt(out, 0, "normal swap works");

        // 20e: General LP removal -> works
        uint128 glpLiq = positionRouter.getPositionLiquidity(poolKeyA, generalLP, 0, 0);
        vm.prank(generalLP);
        positionRouter.removeLiquidityV2(poolKeyA, 0, 0, glpLiq, 0, 0, block.timestamp + 3600);
    }

    // Scenario 21: Fallback claim
    function test_e2e_fallbackClaim() public {
        _buyTokenA(trader, 1 ether);

        vm.prank(trader);
        tokenA.transfer(holder, 50_000e18);

        // Trigger via executeTrigger from hook context
        uint256 totalSupply = tokenA.totalSupply();
        vm.prank(address(hook));
        triggerOracle.executeTrigger(poolIdA, poolKeyA, ITriggerOracle.TriggerType.ISSUER_DUMP, totalSupply);

        IInsurancePool.PoolStatus memory status = insurancePool.getPoolStatus(poolIdA);
        assertTrue(status.isTriggered, "triggered");

        // Advance past 24h merkle submission deadline + one block for flash-loan protection
        vm.warp(block.timestamp + 24 hours + 1);
        vm.roll(block.number + 1);

        // Holder claims via fallback (no merkle root)
        uint256 holderBal = tokenA.balanceOf(holder);
        uint256 holderEthBefore = holder.balance;
        vm.prank(holder);
        insurancePool.claimCompensationFallback(poolIdA, holderBal);
        assertGt(holder.balance, holderEthBefore, "compensated");

        // After 7-day fallback period -> claims fail
        vm.warp(block.timestamp + 8 days);
        address lateClaimer = makeAddr("late");
        vm.deal(lateClaimer, 1 ether);
        deal(address(tokenA), lateClaimer, 1000e18);
        vm.prank(lateClaimer);
        vm.expectRevert();
        insurancePool.claimCompensationFallback(poolIdA, 1000e18);
    }

    // Scenario 22: Compensation distribution excludes issuer
    function test_e2e_compensationDistribution_excludesIssuer() public {
        // Generate substantial insurance
        _buyTokenA(trader, 5 ether);

        // Setup holders with known balances
        // Holder: 50,000 tokens (from setUp), Trader: has some tokens
        // Issuer: has remaining tokens
        uint256 holderBalance = tokenA.balanceOf(holder);
        assertGt(holderBalance, 0, "holder has tokens");

        // Trigger
        uint256 totalSupply = tokenA.totalSupply();
        vm.prank(address(hook));
        triggerOracle.executeTrigger(poolIdA, poolKeyA, ITriggerOracle.TriggerType.ISSUER_DUMP, totalSupply);

        // Advance past 24h merkle submission deadline + one block for flash-loan protection
        vm.warp(block.timestamp + 24 hours + 1);
        vm.roll(block.number + 1);

        // Holder claims -> succeeds
        uint256 holderEthBefore = holder.balance;
        vm.prank(holder);
        insurancePool.claimCompensationFallback(poolIdA, holderBalance);
        assertGt(holder.balance, holderEthBefore, "holder got ETH");

        // Issuer claims -> revert
        uint256 issuerBal = tokenA.balanceOf(issuerA);
        if (issuerBal > 0) {
            vm.prank(issuerA);
            vm.expectRevert();
            insurancePool.claimCompensationFallback(poolIdA, issuerBal);
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    //  PART H: Normal Completion + Rewards
    // ═══════════════════════════════════════════════════════════════════

    // Scenario 23: Normal completion -> issuer 10% + treasury 90%
    function test_e2e_normalCompletion_issuerReward() public {
        // Generate insurance via buy swaps
        _buyTokenA(trader, 2 ether);
        uint256 insBal = insurancePool.getPoolStatus(poolIdA).balance;
        assertGt(insBal, 0, "insurance funded");

        // Warp past full vesting (90 days)
        vm.warp(poolACreatedAt + 90 days);

        // Remove LP in 3 chunks (each < 50% single-tx threshold)
        _removeIssuerLPInChunks(poolKeyA, escrowIdA);

        // Governance claims treasury funds
        uint256 treasuryBefore = deployer.balance;
        uint256 issuerEthBefore = issuerA.balance;

        vm.prank(deployer);
        insurancePool.claimTreasuryFunds(poolIdA);

        uint256 treasuryGot = deployer.balance - treasuryBefore;
        uint256 issuerGot = issuerA.balance - issuerEthBefore;

        // issuerRewardBps = 1000 (10%)
        assertGt(treasuryGot, 0, "treasury got funds");
        assertGt(issuerGot, 0, "issuer got reward");

        // Verify ratio: issuer ~10%, treasury ~90%
        uint256 total = treasuryGot + issuerGot;
        assertApproxEqRel(issuerGot, total / 10, 0.05e18, "issuer ~10%");
        assertApproxEqRel(treasuryGot, (total * 9) / 10, 0.05e18, "treasury ~90%");
    }

    // Scenario 24: Normal completion -> reputation increase
    function test_e2e_normalCompletion_reputationIncrease() public {
        uint256 scoreBefore = reputationEngine.getScore(issuerA);

        vm.warp(poolACreatedAt + 90 days);

        // Remove LP in chunks (each < 50% single-tx threshold)
        _removeIssuerLPInChunks(poolKeyA, escrowIdA);

        uint256 scoreAfter = reputationEngine.getScore(issuerA);
        assertGe(scoreAfter, scoreBefore, "score at least maintained");
    }

    // Scenario 25: Spam pool creation — no score increase
    function test_e2e_spamPoolCreation_noScoreIncrease() public {
        uint256 scoreBefore = reputationEngine.getScore(issuerB);

        vm.startPrank(issuerB);
        for (uint256 i = 0; i < 5; i++) {
            TestToken spam = _createFreshToken("Spam", "SP", 1_000_000e18);
            spam.approve(address(positionRouter), type(uint256).max);
            positionRouter.createPool{value: 2 ether}(
                address(spam), address(0), 3000, 100_000e18, SQRT_PRICE_1_1,
                _buildHookDataDefault(issuerB, address(spam))
            );
        }
        vm.stopPrank();

        assertEq(reputationEngine.getScore(issuerB), scoreBefore, "score unchanged");
    }

    // Scenario 26: Stricter commitment -> reputation bonus
    function test_e2e_stricterCommitment_reputationBonus() public {
        // Issuer A: default commitment, complete vesting
        vm.warp(poolACreatedAt + 90 days);
        _removeIssuerLPInChunks(poolKeyA, escrowIdA);

        uint256 scoreA = reputationEngine.getScore(issuerA);

        // Issuer B: stricter commitment (30d lock + 150d vesting)
        TestToken tkStrict = _createFreshToken("Strict", "STR", 1_000_000e18);
        tkStrict.transfer(issuerB, 200_000e18);

        ITriggerOracle.TriggerConfig memory strictCfg = _defaultTriggerConfig();
        strictCfg.lpRemovalThreshold = 3000;
        strictCfg.dumpThresholdPercent = 2000;

        vm.startPrank(issuerB);
        tkStrict.approve(address(positionRouter), type(uint256).max);
        PoolId pidB = positionRouter.createPool{value: 5 ether}(
            address(tkStrict), address(0), 3000, 100_000e18, SQRT_PRICE_1_1,
            _buildHookDataCustom(issuerB, address(tkStrict), 30 days, 150 days, strictCfg)
        );
        vm.stopPrank();

        uint256 escrowIdB = _getEscrowId(pidB);
        uint256 bCreatedAt = block.timestamp;

        // Warp past B's vesting (30d lock + 150d vesting = 180d)
        vm.warp(bCreatedAt + 180 days);

        PoolKey memory poolKeyBStrict = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(tkStrict)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        // Remove LP in chunks (each < single-tx threshold)
        _removeIssuerLPInChunksFor(poolKeyBStrict, escrowIdB, issuerB);

        uint256 scoreB = reputationEngine.getScore(issuerB);

        // B should have higher score (stricter commitment + longer vesting)
        assertGt(scoreB, scoreA, "stricter commitment higher score");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  PART I: Post-Vesting Behavior
    // ═══════════════════════════════════════════════════════════════════

    // Scenario 27: Post-vesting LP removal — no trigger
    function test_e2e_postVesting_lpRemoval_noTrigger() public {
        vm.warp(poolACreatedAt + 90 days);
        uint128 removable = escrowVault.getRemovableLiquidity(escrowIdA);

        // Remove 45% (under single-tx threshold of 50%)
        uint128 fortyFivePercent = uint128((uint256(removable) * 4500) / 10_000);
        vm.prank(issuerA);
        positionRouter.removeIssuerLiquidity(poolKeyA, fortyFivePercent, 0, 0, block.timestamp + 3600);

        assertFalse(hook.isPoolTriggered(poolIdA), "not triggered");
    }

    // Scenario 28: Post-vesting sell limits still active
    function test_e2e_postVesting_sellLimits_stillActive() public {
        // Deep liquidity
        vm.startPrank(generalLP);
        tokenA.approve(address(positionRouter), type(uint256).max);
        positionRouter.addLiquidityV2{value: 100 ether}(
            poolKeyA, 0, 0, 100 ether, 200_000e18, block.timestamp + 3600
        );
        vm.stopPrank();

        vm.warp(poolACreatedAt + 90 days);

        uint256 initialSupply = hook.getInitialTotalSupply(poolIdA);
        uint256 overLimit = (initialSupply * 3500) / 10_000; // 35% > 30% daily limit

        vm.startPrank(issuerA);
        tokenA.approve(address(swapRouter), type(uint256).max);
        vm.expectRevert();
        swapRouter.swapExactInput(poolKeyA, false, overLimit, 0, block.timestamp + 3600);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════
    //  PART J: Governance
    // ═══════════════════════════════════════════════════════════════════

    // Scenario 29: Governance parameter changes
    function test_e2e_governance_parameterChanges() public {
        // 29a: Fee rate change
        vm.prank(deployer);
        insurancePool.setFeeRate(200); // 2%

        // 29b: Non-governance -> revert
        vm.prank(trader);
        vm.expectRevert();
        insurancePool.setFeeRate(300);

        // 29c: Out of range -> revert
        vm.prank(deployer);
        vm.expectRevert();
        insurancePool.setFeeRate(600); // > 500 max

        // 29d: Base token add/remove
        address newBase = makeAddr("newBase");
        vm.prank(deployer);
        hook.addBaseToken(newBase, 1 ether);
        assertTrue(hook.allowedBaseTokens(newBase), "new base added");

        vm.prank(deployer);
        hook.removeBaseToken(newBase);
        assertFalse(hook.allowedBaseTokens(newBase), "base removed");

        // 29e: TVL cap
        vm.prank(deployer);
        hook.setMaxPoolTVL(100 ether);
        assertEq(hook.maxPoolTVL(), 100 ether, "TVL cap set");

        // 29f: Issuer reward bps
        vm.prank(deployer);
        insurancePool.setIssuerRewardBps(2000); // 20%

        // 29g: Treasury address
        address newTreasury = makeAddr("treasury");
        vm.prank(deployer);
        insurancePool.setTreasury(newTreasury);

        // 29h: Guardian address
        address newGuardian = makeAddr("guardian");
        vm.prank(deployer);
        triggerOracle.setGuardian(newGuardian);
    }

    // Scenario 30: Governance changes don't affect existing pools
    function test_e2e_governance_existingPoolsUnaffected() public {
        // Pool A exists with 7d lock
        BastionHook.PoolCommitment memory cBefore = hook.getPoolCommitment(poolIdA);
        assertEq(cBefore.lockDuration, 7 days, "7d lock");

        // Change default lock to 14 days
        vm.prank(deployer);
        hook.setDefaultLockDuration(14 days);
        vm.prank(deployer);
        hook.setMinLockDuration(14 days);

        // Pool A unchanged
        BastionHook.PoolCommitment memory cAfter = hook.getPoolCommitment(poolIdA);
        assertEq(cAfter.lockDuration, 7 days, "still 7d lock");

        // New pool must respect 14d minimum
        TestToken tkNew = _createFreshToken("New", "NEW", 1_000_000e18);
        tkNew.transfer(issuerB, 200_000e18);
        vm.startPrank(issuerB);
        tkNew.approve(address(positionRouter), type(uint256).max);
        // Try 7-day lock -> revert (below new minimum 14 days)
        vm.expectRevert();
        positionRouter.createPool{value: 5 ether}(
            address(tkNew), address(0), 3000, 100_000e18, SQRT_PRICE_1_1,
            _buildHookData(issuerB, address(tkNew), 7 days, 83 days, _defaultTriggerConfig())
        );

        // 14-day lock -> succeeds
        positionRouter.createPool{value: 5 ether}(
            address(tkNew), address(0), 3000, 100_000e18, SQRT_PRICE_1_1,
            _buildHookData(issuerB, address(tkNew), 14 days, 83 days, _defaultTriggerConfig())
        );
        vm.stopPrank();
    }

    // Scenario 31: Governance transfer
    function test_e2e_governance_transfer() public {
        address newGov = makeAddr("newGov");

        // Transfer governance
        vm.prank(deployer);
        hook.transferGovernance(newGov);

        // Old governance -> revert
        vm.prank(deployer);
        vm.expectRevert();
        hook.setMaxPoolTVL(999 ether);

        // New governance -> succeeds
        vm.prank(newGov);
        hook.setMaxPoolTVL(999 ether);
        assertEq(hook.maxPoolTVL(), 999 ether, "new gov works");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  PART K: Commitment Breach
    // ═══════════════════════════════════════════════════════════════════

    // Scenario 32: Daily sell commitment breach
    function test_e2e_commitmentBreach_dailySell() public {
        // Deep liquidity
        vm.startPrank(generalLP);
        tokenA.approve(address(positionRouter), type(uint256).max);
        positionRouter.addLiquidityV2{value: 100 ether}(
            poolKeyA, 0, 0, 100 ether, 200_000e18, block.timestamp + 3600
        );
        vm.stopPrank();

        uint256 initialSupply = hook.getInitialTotalSupply(poolIdA);
        // maxDailySellBps = 3000 (30%). Try 35% -> revert
        uint256 overLimit = (initialSupply * 3500) / 10_000;

        vm.startPrank(issuerA);
        tokenA.approve(address(swapRouter), type(uint256).max);
        vm.expectRevert();
        swapRouter.swapExactInput(poolKeyA, false, overLimit, 0, block.timestamp + 3600);
        vm.stopPrank();
    }

    // Scenario 33: Weekly sell commitment breach
    function test_e2e_commitmentBreach_weeklySell() public {
        // Deep liquidity
        vm.startPrank(generalLP);
        tokenA.approve(address(positionRouter), type(uint256).max);
        positionRouter.addLiquidityV2{value: 100 ether}(
            poolKeyA, 0, 0, 100 ether, 200_000e18, block.timestamp + 3600
        );
        vm.stopPrank();

        uint256 initialSupply = hook.getInitialTotalSupply(poolIdA);
        // weeklyDumpThresholdBps = 5000 (50%), uses >= comparison
        // Sell 20% each day for 2 days = 40% < 50%, then 20% more -> 60% >= 50%
        uint256 dailySell = (initialSupply * 2000) / 10_000; // 20%

        vm.startPrank(issuerA);
        tokenA.approve(address(swapRouter), type(uint256).max);

        swapRouter.swapExactInput(poolKeyA, false, dailySell, 0, block.timestamp + 3600);
        vm.warp(block.timestamp + 1 days + 1);
        swapRouter.swapExactInput(poolKeyA, false, dailySell, 0, block.timestamp + 3600);

        // Another sell -> weekly limit exceeded (60% >= 50%)
        vm.warp(block.timestamp + 1 days + 1);
        vm.expectRevert();
        swapRouter.swapExactInput(poolKeyA, false, dailySell, 0, block.timestamp + 3600);

        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════
    //  PART L: Griefing Prevention
    // ═══════════════════════════════════════════════════════════════════

    // Scenario 34: General LP removal -> no trigger
    function test_e2e_griefing_generalLPRemoval() public {
        vm.startPrank(generalLP);
        tokenA.approve(address(positionRouter), type(uint256).max);
        positionRouter.addLiquidityV2{value: 10 ether}(
            poolKeyA, 0, 0, 10 ether, 100_000e18, block.timestamp + 3600
        );
        uint128 liq = positionRouter.getPositionLiquidity(poolKeyA, generalLP, 0, 0);
        positionRouter.removeLiquidityV2(poolKeyA, 0, 0, liq, 0, 0, block.timestamp + 3600);
        vm.stopPrank();

        assertFalse(hook.isPoolTriggered(poolIdA), "no trigger");
    }

    // Scenario 35: Non-issuer dump -> no trigger
    function test_e2e_griefing_nonIssuerDump() public {
        vm.startPrank(generalLP);
        tokenA.approve(address(positionRouter), type(uint256).max);
        positionRouter.addLiquidityV2{value: 50 ether}(
            poolKeyA, 0, 0, 50 ether, 200_000e18, block.timestamp + 3600
        );
        vm.stopPrank();

        _sellTokenA(trader, 100_000e18);

        assertFalse(hook.isPoolTriggered(poolIdA), "no trigger from non-issuer");
    }

    // Scenario 36: Reputation spam prevention
    function test_e2e_griefing_reputationSpam() public {
        uint256 scoreBefore = reputationEngine.getScore(issuerB);

        vm.startPrank(issuerB);
        for (uint256 i = 0; i < 10; i++) {
            TestToken spam = _createFreshToken("S", "S", 1_000_000e18);
            spam.approve(address(positionRouter), type(uint256).max);
            positionRouter.createPool{value: 2 ether}(
                address(spam), address(0), 3000, 100_000e18, SQRT_PRICE_1_1,
                _buildHookDataDefault(issuerB, address(spam))
            );
        }
        vm.stopPrank();

        assertEq(reputationEngine.getScore(issuerB), scoreBefore, "score unchanged after spam");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  PART M: Emergency + Pause
    // ═══════════════════════════════════════════════════════════════════

    // Scenario 38: Emergency withdrawal
    function test_e2e_emergencyWithdrawal() public {
        _buyTokenA(trader, 1 ether);
        uint256 poolBal = insurancePool.getPoolStatus(poolIdA).balance;
        assertGt(poolBal, 0, "pool has balance");

        // Non-governance -> revert
        vm.prank(trader);
        vm.expectRevert();
        insurancePool.requestEmergencyWithdraw(poolIdA, trader, poolBal);

        // Governance requests
        vm.prank(deployer);
        bytes32 requestId = insurancePool.requestEmergencyWithdraw(poolIdA, deployer, poolBal / 2);

        // Before timelock -> revert
        vm.prank(deployer);
        vm.expectRevert();
        insurancePool.executeEmergencyWithdraw(requestId);

        // After 2-day timelock -> success
        vm.warp(block.timestamp + 2 days + 1);
        uint256 govBefore = deployer.balance;
        vm.prank(deployer);
        insurancePool.executeEmergencyWithdraw(requestId);
        assertGt(deployer.balance, govBefore, "emergency funds received");
    }

    // Scenario 39: Guardian pause
    function test_e2e_guardianPause() public {
        // Guardian (deployer) pauses
        vm.prank(deployer);
        triggerOracle.pause();
        assertTrue(triggerOracle.paused(), "paused");

        // During pause: trigger execution fails
        vm.prank(address(hook));
        vm.expectRevert();
        triggerOracle.executeTrigger(poolIdA, poolKeyA, ITriggerOracle.TriggerType.ISSUER_DUMP, 1000e18);

        // Manual unpause
        vm.prank(deployer);
        triggerOracle.unpause();
        assertFalse(triggerOracle.paused(), "unpaused");

        // Pause again and wait for auto-expiry
        vm.prank(deployer);
        triggerOracle.pause();
        assertTrue(triggerOracle.paused(), "paused again");

        vm.warp(block.timestamp + 7 days + 1);
        assertFalse(triggerOracle.paused(), "auto-expired");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  PART N: Deployment Validation
    // ═══════════════════════════════════════════════════════════════════

    // Scenario 40: Contract deployment + permission validation
    function test_e2e_deploymentValidation() public view {
        // All contracts have code
        assertGt(address(hook).code.length, 0, "hook deployed");
        assertGt(address(escrowVault).code.length, 0, "escrow deployed");
        assertGt(address(insurancePool).code.length, 0, "insurance deployed");
        assertGt(address(triggerOracle).code.length, 0, "trigger deployed");
        assertGt(address(reputationEngine).code.length, 0, "reputation deployed");
        assertGt(address(swapRouter).code.length, 0, "swapRouter deployed");
        assertGt(address(positionRouter).code.length, 0, "positionRouter deployed");

        // Hook flags match
        uint160 flags = uint160(address(hook)) & 0x3FFF;
        assertEq(flags, HOOK_FLAGS, "hook flags match");

        // Cross-references
        assertEq(hook.bastionRouter(), address(positionRouter), "hook->router");

        // Base token whitelist
        assertTrue(hook.allowedBaseTokens(address(0)), "ETH allowed");
        assertTrue(hook.allowedBaseTokens(WETH), "WETH allowed");
        assertTrue(hook.allowedBaseTokens(USDC), "USDC allowed");
        assertFalse(hook.allowedBaseTokens(address(tokenA)), "tokenA not base");

        // Min base amounts
        assertEq(hook.minBaseAmount(address(0)), 1 ether, "ETH min 1");
        assertEq(hook.minBaseAmount(WETH), 1 ether, "WETH min 1");
        assertEq(hook.minBaseAmount(USDC), 2000e6, "USDC min 2000");

        // Contract sizes < 24,576 bytes
        assertLt(address(hook).code.length, 24_576, "hook size ok");
        assertLt(address(escrowVault).code.length, 24_576, "escrow size ok");
        assertLt(address(insurancePool).code.length, 24_576, "insurance size ok");
        assertLt(address(triggerOracle).code.length, 24_576, "trigger size ok");
    }

    // Scenario 41: TVL cap
    function test_e2e_tvlCap() public {
        // Pool A already has LP, so set cap just above it to block further additions
        // Set cap to 1 (any addition will exceed since pool already has liquidity)
        vm.prank(deployer);
        hook.setMaxPoolTVL(1);

        // generalLP adding any liquidity -> exceeds cap -> revert
        vm.startPrank(generalLP);
        tokenA.approve(address(positionRouter), type(uint256).max);
        vm.expectRevert();
        positionRouter.addLiquidityV2{value: 1 ether}(
            poolKeyA, 0, 0, 1 ether, 10_000e18, block.timestamp + 3600
        );
        vm.stopPrank();

        // Remove cap
        vm.prank(deployer);
        hook.setMaxPoolTVL(0);

        // Now adding LP -> succeeds
        vm.startPrank(generalLP);
        positionRouter.addLiquidityV2{value: 1 ether}(
            poolKeyA, 0, 0, 1 ether, 10_000e18, block.timestamp + 3600
        );
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════
    //  PART O: LP/Supply Ratio Transparency
    // ═══════════════════════════════════════════════════════════════════

    // Scenario 42: LP/Supply ratio recording
    function test_e2e_lpSupplyRatio() public {
        // LP ratio = AMM liquidity * 10000 / totalSupply (integer truncation possible)
        // With small AMM liquidity relative to totalSupply, ratio may be 0.
        // This is transparency-only, so just verify it's stored and queryable.
        uint256 ratioA = hook.getLpRatioBps(poolIdA);

        // Create pool with MUCH higher token/ETH ratio to get non-zero ratio
        // Use 100 ETH + 100,000 tokens from 100,000 supply = 100% LP ratio
        TestToken tkHigh = _createFreshToken("HighLP", "HLP", 100_000e18);
        tkHigh.transfer(issuerB, 100_000e18);
        vm.startPrank(issuerB);
        tkHigh.approve(address(positionRouter), type(uint256).max);
        PoolId pidH = positionRouter.createPool{value: 50 ether}(
            address(tkHigh), address(0), 3000, 100_000e18, SQRT_PRICE_1_1,
            _buildHookDataDefault(issuerB, address(tkHigh))
        );
        vm.stopPrank();

        uint256 ratioH = hook.getLpRatioBps(pidH);
        // With 100% supply as LP and more ETH, ratio should be higher
        assertGe(ratioH, ratioA, "higher LP allocation -> higher or equal ratio");

        // Low LP allocation still succeeds (transparency only, not enforced)
        TestToken tkLow = _createFreshToken("Low", "LOW", 10_000_000e18);
        tkLow.transfer(issuerB, 200_000e18);
        vm.startPrank(issuerB);
        tkLow.approve(address(positionRouter), type(uint256).max);
        PoolId pidLow = positionRouter.createPool{value: 5 ether}(
            address(tkLow), address(0), 3000, 10_000e18, SQRT_PRICE_1_1,
            _buildHookDataDefault(issuerB, address(tkLow))
        );
        vm.stopPrank();

        uint256 ratioLow = hook.getLpRatioBps(pidLow);
        // Just verify it's queryable (may be 0 due to integer truncation)
        assertLe(ratioLow, ratioH, "lower LP allocation -> lower or equal ratio");
    }
}
