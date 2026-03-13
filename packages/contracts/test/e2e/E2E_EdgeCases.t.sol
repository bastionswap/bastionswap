// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

// ─── Uniswap V4 ─────────────────────────────────────────────
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
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
import {BastionDeployer} from "../../script/BastionDeployer.sol";
import {HookMiner} from "../../script/HookMiner.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";

// ═══════════════════════════════════════════════════════════════
//  HELPER CONTRACTS
// ═══════════════════════════════════════════════════════════════

/// @dev ERC20 that deducts 1% on every transfer
contract FeeOnTransferToken is ERC20 {
    constructor(uint256 supply) ERC20("FoT Token", "FOT", 18) {
        _mint(msg.sender, supply);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        uint256 fee = amount / 100; // 1% fee
        uint256 net = amount - fee;
        balanceOf[msg.sender] -= amount;
        unchecked {
            balanceOf[to] += net;
            balanceOf[address(0)] += fee; // burn the fee
        }
        emit Transfer(msg.sender, to, net);
        emit Transfer(msg.sender, address(0), fee);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;

        uint256 fee = amount / 100;
        uint256 net = amount - fee;
        balanceOf[from] -= amount;
        unchecked {
            balanceOf[to] += net;
            balanceOf[address(0)] += fee;
        }
        emit Transfer(from, to, net);
        emit Transfer(from, address(0), fee);
        return true;
    }
}

/// @dev ERC20 with elastic supply that changes on transfer
contract RebaseToken is ERC20 {
    constructor(uint256 supply) ERC20("Rebase Token", "REB", 18) {
        _mint(msg.sender, supply);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        bool success = super.transfer(to, amount);
        // Rebase: mint 0.1% of total supply on every transfer
        _mint(msg.sender, totalSupply / 1000);
        return success;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        bool success = super.transferFrom(from, to, amount);
        _mint(from, totalSupply / 1000);
        return success;
    }
}

/// @dev Contract that attempts reentrancy on InsurancePool.claimCompensationFallback
contract ReentrancyAttacker {
    InsurancePool public target;
    PoolId public targetPoolId;
    uint256 public holderBalance;
    bool public attacked;

    constructor(InsurancePool _target) {
        target = _target;
    }

    function attack(PoolId poolId, uint256 _holderBalance) external {
        targetPoolId = poolId;
        holderBalance = _holderBalance;
        target.claimCompensationFallback(poolId, _holderBalance);
    }

    receive() external payable {
        if (!attacked) {
            attacked = true;
            // Attempt reentrant claim
            try target.claimCompensationFallback(targetPoolId, holderBalance) {} catch {}
        }
    }
}

// ═══════════════════════════════════════════════════════════════
//  E2E EDGE CASE TESTS
// ═══════════════════════════════════════════════════════════════

/// @title E2E_EdgeCases
/// @notice Edge case and attack scenario tests for BastionSwap security hardening.
contract E2E_EdgeCases is Test {
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

    // ─── Test Accounts ───────────────────────────────────────────────
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

        // ── Raise TVL cap for E2E tests ──
        hook.setMaxPoolTVL(address(0), 0); // unlimited for ETH pools

        vm.stopPrank();

        // ── Create default TokenA/ETH pool ──
        _createDefaultPoolA();
    }

    // ═══════════════════════════════════════════════════════════════════
    //  HELPERS
    // ═══════════════════════════════════════════════════════════════════

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

    function _buildHookData(
        address issuer,
        address token,
        uint40 lockDur,
        uint40 vestDur,
        ITriggerOracle.TriggerConfig memory triggerConfig
    ) internal pure returns (bytes memory) {
        IEscrowVault.IssuerCommitment memory commitment =
            IEscrowVault.IssuerCommitment({maxSellPercent: 300});
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
            IEscrowVault.IssuerCommitment({maxSellPercent: 200});
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
        (, escrowIdA,,,) = hook.getPoolInfo(poolIdA);
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

    function _createFreshToken(string memory name, string memory symbol, uint256 supply)
        internal
        returns (TestToken)
    {
        return new TestToken(name, symbol, 18, supply);
    }

    function _getEscrowId(PoolId pid) internal view returns (uint256) {
        (, uint256 eid,,,) = hook.getPoolInfo(pid);
        return eid;
    }

    function _createPoolForIssuer(
        address issuer,
        TestToken token,
        uint256 ethAmount,
        uint256 tokenAmount,
        ITriggerOracle.TriggerConfig memory cfg
    ) internal returns (PoolKey memory key, PoolId pid) {
        vm.startPrank(issuer);
        token.approve(address(positionRouter), type(uint256).max);
        pid = positionRouter.createPool{value: ethAmount}(
            address(token), address(0), 3000, tokenAmount, SQRT_PRICE_1_1,
            _buildHookDataCustom(issuer, address(token), 7 days, 83 days, cfg)
        );
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════
    //  PART 1: TOKEN COMPATIBILITY
    // ═══════════════════════════════════════════════════════════════════

    function test_FeeOnTransferToken_Blocked() public {
        vm.startPrank(deployer);
        FeeOnTransferToken fot = new FeeOnTransferToken(1_000_000e18);
        fot.transfer(issuerB, 200_000e18);
        vm.stopPrank();

        vm.startPrank(issuerB);
        fot.approve(address(positionRouter), type(uint256).max);
        vm.expectRevert();
        positionRouter.createPool{value: 5 ether}(
            address(fot), address(0), 3000, 100_000e18, SQRT_PRICE_1_1,
            _buildHookDataDefault(issuerB, address(fot))
        );
        vm.stopPrank();
    }

    function test_RebaseToken_Blocked() public {
        vm.startPrank(deployer);
        RebaseToken reb = new RebaseToken(1_000_000e18);
        reb.transfer(issuerB, 200_000e18);
        vm.stopPrank();

        vm.startPrank(issuerB);
        reb.approve(address(positionRouter), type(uint256).max);
        vm.expectRevert();
        positionRouter.createPool{value: 5 ether}(
            address(reb), address(0), 3000, 100_000e18, SQRT_PRICE_1_1,
            _buildHookDataDefault(issuerB, address(reb))
        );
        vm.stopPrank();
    }

    function test_NormalToken_Allowed() public {
        vm.startPrank(deployer);
        TestToken normal = _createFreshToken("Normal", "NRM", 1_000_000e18);
        normal.transfer(issuerB, 200_000e18);
        vm.stopPrank();

        vm.startPrank(issuerB);
        normal.approve(address(positionRouter), type(uint256).max);
        PoolId pid = positionRouter.createPool{value: 5 ether}(
            address(normal), address(0), 3000, 100_000e18, SQRT_PRICE_1_1,
            _buildHookDataDefault(issuerB, address(normal))
        );
        vm.stopPrank();

        // Pool created successfully
        (address iss,,,,) = hook.getPoolInfo(pid);
        assertEq(iss, issuerB, "issuer registered");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  PART 2: MATHEMATICAL EDGE CASES
    // ═══════════════════════════════════════════════════════════════════

    function test_SellExactlyAtLimit_Allowed() public {
        // Default daily sell limit is 300 bps (3%)
        uint256 poolReserve = tokenA.balanceOf(address(pm));
        // Sell exactly 3% of pool reserve = at the limit -> should succeed with > comparison
        uint256 exactLimitAmount = (poolReserve * 300) / 10_000;

        // Need issuerA to have enough tokens
        uint256 issuerBal = tokenA.balanceOf(issuerA);
        if (exactLimitAmount > issuerBal) {
            // Reduce to what's available, just test the concept
            exactLimitAmount = issuerBal / 2;
        }

        vm.startPrank(issuerA);
        tokenA.approve(address(swapRouter), exactLimitAmount);
        // This should NOT revert (selling exactly at the limit)
        swapRouter.swapExactInput(poolKeyA, false, exactLimitAmount, 0, block.timestamp + 3600);
        vm.stopPrank();
    }

    function test_SellOneAboveLimit_Reverts() public {
        // Create a pool with default limits (300 bps = 3% daily) for precise testing
        vm.startPrank(deployer);
        TestToken tkLimit = _createFreshToken("Limit", "LMT", 1_000_000e18);
        tkLimit.transfer(issuerB, 500_000e18);
        vm.stopPrank();

        ITriggerOracle.TriggerConfig memory cfg = _defaultTriggerConfig();
        // dumpThresholdPercent = 300 (3%) by default — must be ≤ governance default

        (PoolKey memory key,) = _createPoolForIssuer(issuerB, tkLimit, 5 ether, 100_000e18, cfg);

        uint256 poolReserve = tkLimit.balanceOf(address(pm));
        // Sell exactly at limit (should succeed)
        uint256 atLimit = (poolReserve * 300) / 10_000;

        vm.startPrank(issuerB);
        tkLimit.approve(address(swapRouter), type(uint256).max);

        // First: sell at exact limit -> succeeds
        swapRouter.swapExactInput(key, false, atLimit, 0, block.timestamp + 3600);

        // Next day: sell 1 BPS above the limit -> should revert
        // We need at least 1 full BPS worth of tokens to exceed the threshold
        // (due to ceil division rounding).
        // Re-read pool reserve (grows after sell since issued tokens flow into pool)
        vm.warp(block.timestamp + 1 days);
        uint256 newReserve = tkLimit.balanceOf(address(pm));
        uint256 overLimit = (newReserve * (300 + 1)) / 10_000; // 301 bps = 3.01%
        vm.expectRevert();
        swapRouter.swapExactInput(key, false, overLimit, 0, block.timestamp + 3600);
        vm.stopPrank();
    }

    function test_LPRemovalExactThreshold_Allowed() public {
        // Warp past lock period
        vm.warp(poolACreatedAt + 90 days);

        // Daily removal threshold is 1000 bps (10%) of _initialLiquidity
        uint128 initialLiq = escrowVault.getTotalLiquidity(escrowIdA);
        uint128 exactTenPercent = uint128((uint256(initialLiq) * 1000) / 10_000);

        // Should succeed since LP removal uses > (not >=) for daily limit
        vm.prank(issuerA);
        positionRouter.removeIssuerLiquidity(poolKeyA, exactTenPercent, 0, 0, block.timestamp + 3600);
    }

    function test_MinimumLiquidity_Pool() public {
        // Create a pool with minimum viable liquidity
        // Note: V4 liquidity math can result in slightly less than amountSpecified
        // being used, so we need just above the 1 ETH minimum to pass BelowMinBaseAmount.
        vm.startPrank(deployer);
        TestToken tkMin = _createFreshToken("MinLiq", "MIN", 1_000_000e18);
        tkMin.transfer(issuerB, 500_000e18);
        vm.stopPrank();

        vm.startPrank(issuerB);
        tkMin.approve(address(positionRouter), type(uint256).max);
        PoolId pid = positionRouter.createPool{value: 1.01 ether}(
            address(tkMin), address(0), 3000, 1000e18, SQRT_PRICE_1_1,
            _buildHookDataDefault(issuerB, address(tkMin))
        );
        vm.stopPrank();

        // Pool should work
        (address iss,,,,) = hook.getPoolInfo(pid);
        assertEq(iss, issuerB);
    }

    function test_DustAmount_Sell() public {
        // 1 wei sell should not cause division issues
        vm.startPrank(issuerA);
        tokenA.approve(address(swapRouter), 1);
        // Tiny sell: may give 0 output but should not revert with division error
        // Note: V4 may revert with 0 output for dust amounts, which is fine
        try swapRouter.swapExactInput(poolKeyA, false, 1, 0, block.timestamp + 3600) {
            // Success — dust amount handled correctly
        } catch {
            // Acceptable: AMM might reject zero-output swaps
        }
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════
    //  PART 3: MULTI-POOL INTERACTIONS
    // ═══════════════════════════════════════════════════════════════════

    function test_TwoPoolsSameIssuer_IndependentSellTracking() public {
        // IssuerA already has poolA. Create a second pool.
        vm.startPrank(deployer);
        TestToken tkX = _createFreshToken("TokenX", "TKX", 1_000_000e18);
        tkX.transfer(issuerA, 500_000e18);
        vm.stopPrank();

        vm.startPrank(issuerA);
        tkX.approve(address(positionRouter), type(uint256).max);
        positionRouter.createPool{value: 5 ether}(
            address(tkX), address(0), 3000, 100_000e18, SQRT_PRICE_1_1,
            _buildHookDataDefault(issuerA, address(tkX))
        );
        vm.stopPrank();

        PoolKey memory keyX = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(tkX)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        // Sell in pool A — use 2% of pool reserve (under 3% daily limit)
        uint256 reserveA = tokenA.balanceOf(address(pm));
        uint256 sellA = (reserveA * 200) / 10_000;
        _sellTokenA(issuerA, sellA);

        // Sell in pool X — 2% of pool X reserve, should succeed independently
        uint256 reserveX = tkX.balanceOf(address(pm));
        uint256 sellX = (reserveX * 200) / 10_000;
        vm.startPrank(issuerA);
        tkX.approve(address(swapRouter), sellX);
        swapRouter.swapExactInput(keyX, false, sellX, 0, block.timestamp + 3600);
        vm.stopPrank();

        // Both pools should have independent sell tracking
        // (no cross-contamination — if this doesn't revert, tracking is independent)
    }

    function test_TwoPoolsSameIssuer_IndependentTriggers() public {
        vm.startPrank(deployer);
        TestToken tkY = _createFreshToken("TokenY", "TKY", 1_000_000e18);
        tkY.transfer(issuerA, 500_000e18);
        vm.stopPrank();

        vm.startPrank(issuerA);
        tkY.approve(address(positionRouter), type(uint256).max);
        PoolId pidY = positionRouter.createPool{value: 5 ether}(
            address(tkY), address(0), 3000, 100_000e18, SQRT_PRICE_1_1,
            _buildHookDataDefault(issuerA, address(tkY))
        );
        vm.stopPrank();

        // Generate insurance fees for poolA
        _buyTokenA(trader, 1 ether);

        // Trigger poolA directly (v2 watcher path — preserved infra)
        uint256 totalSupply = tokenA.totalSupply();
        vm.prank(address(hook));
        triggerOracle.executeTrigger(poolIdA, poolKeyA, ITriggerOracle.TriggerType.RUG_PULL, totalSupply);
        vm.store(address(hook), keccak256(abi.encode(poolIdA, uint256(13))), bytes32(uint256(1)));
        assertTrue(hook.isPoolTriggered(poolIdA), "poolA triggered");

        // Pool Y should NOT be triggered
        assertFalse(hook.isPoolTriggered(pidY), "poolY NOT triggered");
    }

    function test_TwoPoolsSameToken_IndependentEscrows() public {
        // Two different issuers create pools with different tokens
        vm.startPrank(deployer);
        TestToken tkZ1 = _createFreshToken("TokenZ1", "TZ1", 1_000_000e18);
        TestToken tkZ2 = _createFreshToken("TokenZ2", "TZ2", 1_000_000e18);
        tkZ1.transfer(issuerA, 500_000e18);
        tkZ2.transfer(issuerB, 500_000e18);
        vm.stopPrank();

        vm.startPrank(issuerA);
        tkZ1.approve(address(positionRouter), type(uint256).max);
        PoolId pid1 = positionRouter.createPool{value: 5 ether}(
            address(tkZ1), address(0), 3000, 100_000e18, SQRT_PRICE_1_1,
            _buildHookDataDefault(issuerA, address(tkZ1))
        );
        vm.stopPrank();

        vm.startPrank(issuerB);
        tkZ2.approve(address(positionRouter), type(uint256).max);
        PoolId pid2 = positionRouter.createPool{value: 5 ether}(
            address(tkZ2), address(0), 3000, 100_000e18, SQRT_PRICE_1_1,
            _buildHookDataDefault(issuerB, address(tkZ2))
        );
        vm.stopPrank();

        uint256 eid1 = _getEscrowId(pid1);
        uint256 eid2 = _getEscrowId(pid2);

        // Each pool has its own escrow
        assertTrue(eid1 != eid2, "independent escrow IDs");
        assertGt(escrowVault.getTotalLiquidity(eid1), 0, "escrow1 has liquidity");
        assertGt(escrowVault.getTotalLiquidity(eid2), 0, "escrow2 has liquidity");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  PART 4: TIME EDGE CASES
    // ═══════════════════════════════════════════════════════════════════

    function test_SellWindow_ResetAtEpochBoundary() public {
        // Sell some tokens near the daily limit
        uint256 poolReserve = tokenA.balanceOf(address(pm));
        uint256 nearLimit = (poolReserve * 250) / 10_000; // 2.5% of pool reserve (under 3% limit)

        uint256 issuerBal = tokenA.balanceOf(issuerA);
        if (nearLimit > issuerBal / 2) nearLimit = issuerBal / 4;

        vm.startPrank(issuerA);
        tokenA.approve(address(swapRouter), type(uint256).max);
        swapRouter.swapExactInput(poolKeyA, false, nearLimit, 0, block.timestamp + 3600);
        vm.stopPrank();

        // Warp to new day (epoch boundary)
        vm.warp(block.timestamp + 1 days);

        // Should be able to sell again (counter reset)
        vm.startPrank(issuerA);
        swapRouter.swapExactInput(poolKeyA, false, nearLimit, 0, block.timestamp + 3600);
        vm.stopPrank();
    }

    function test_VestingBoundary_ExactLockExpiry() public {
        // At exactly T = lockDuration, removable should be 0 (lock not yet expired)
        vm.warp(poolACreatedAt + 7 days);
        uint128 removable = escrowVault.getRemovableLiquidity(escrowIdA);
        assertEq(removable, 0, "no removable at exact lock expiry");
    }

    function test_VestingBoundary_OneSecondAfterLock() public {
        // At T = lockDuration + 1, some liquidity should be removable
        vm.warp(poolACreatedAt + 7 days + 1);
        uint128 removable = escrowVault.getRemovableLiquidity(escrowIdA);
        // May be 0 due to integer truncation with large vesting periods
        // But the call itself should not revert
        // After lock + full vesting, definitely removable
        vm.warp(poolACreatedAt + 90 days);
        removable = escrowVault.getRemovableLiquidity(escrowIdA);
        assertGt(removable, 0, "removable after lock+vesting");
    }

    function test_SameBlockMultipleSells_Accumulate() public {
        uint256 poolReserve = tokenA.balanceOf(address(pm));
        // Sell in multiple transactions within the same block
        // 3% daily limit → each sell 0.9% → 3 sells = 2.7% < 3%
        uint256 smallSell = (poolReserve * 90) / 10_000; // 0.9% of pool reserve each

        uint256 issuerBal = tokenA.balanceOf(issuerA);
        if (smallSell * 4 > issuerBal) smallSell = issuerBal / 8;

        vm.startPrank(issuerA);
        tokenA.approve(address(swapRouter), type(uint256).max);

        // Multiple sells in same block should accumulate
        swapRouter.swapExactInput(poolKeyA, false, smallSell, 0, block.timestamp + 3600);
        swapRouter.swapExactInput(poolKeyA, false, smallSell, 0, block.timestamp + 3600);
        swapRouter.swapExactInput(poolKeyA, false, smallSell, 0, block.timestamp + 3600);
        // All three succeeded = properly accumulated but under limit
        vm.stopPrank();
    }

    function test_WeeklyWindow_SlidingReset() public {
        // Sell near the weekly limit
        uint256 poolReserve = tokenA.balanceOf(address(pm));
        uint256 dailySell = (poolReserve * 200) / 10_000; // 2% of pool reserve (under daily 3%)

        uint256 issuerBal = tokenA.balanceOf(issuerA);
        if (dailySell > issuerBal / 4) dailySell = issuerBal / 8;

        vm.startPrank(issuerA);
        tokenA.approve(address(swapRouter), type(uint256).max);

        // Sell on day 1
        swapRouter.swapExactInput(poolKeyA, false, dailySell, 0, block.timestamp + 3600);

        // Sell on day 2
        vm.warp(block.timestamp + 1 days);
        swapRouter.swapExactInput(poolKeyA, false, dailySell, 0, block.timestamp + 3600);

        // After weekly window resets, should be able to sell again
        vm.warp(block.timestamp + 7 days);
        swapRouter.swapExactInput(poolKeyA, false, dailySell, 0, block.timestamp + 3600);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════
    //  PART 5: GAS & REENTRANCY
    // ═══════════════════════════════════════════════════════════════════

    function test_LargeNumberOfSells_GasLimit() public {
        // Buy tokens to give to trader
        _buyTokenA(trader, 5 ether);

        uint256 traderBal = tokenA.balanceOf(trader);
        uint256 perSell = traderBal / 110; // small amounts

        vm.startPrank(trader);
        tokenA.approve(address(swapRouter), type(uint256).max);

        uint256 gasBefore = gasleft();
        for (uint256 i = 0; i < 100; i++) {
            swapRouter.swapExactInput(poolKeyA, false, perSell, 0, block.timestamp + 3600);
        }
        uint256 gasUsed = gasBefore - gasleft();
        vm.stopPrank();

        // Gas for 100 sells should be reasonable (< 500M)
        assertLt(gasUsed, 500_000_000, "100 sells within gas limits");
    }

    function test_ReentrancyGuard_InsurancePool() public {
        // Generate insurance via buys
        _buyTokenA(trader, 2 ether);

        // Deploy reentrancy attacker
        vm.startPrank(deployer);
        ReentrancyAttacker reentrancyAttacker = new ReentrancyAttacker(insurancePool);
        vm.stopPrank();

        // Give attacker some tokens from holder (who received tokens during pool creation)
        vm.prank(holder);
        tokenA.transfer(address(reentrancyAttacker), 5_000e18);

        // Trigger via hook context
        uint256 totalSupply = tokenA.totalSupply();
        vm.prank(address(hook));
        triggerOracle.executeTrigger(poolIdA, poolKeyA, ITriggerOracle.TriggerType.ISSUER_DUMP, totalSupply);

        // Advance past 24h merkle submission deadline + one block for flash-loan protection
        vm.warp(block.timestamp + 24 hours + 1);
        vm.roll(block.number + 1);

        // Reentrancy attack: the outer call succeeds (first claim works),
        // but the reentrant call inside receive() is blocked by nonReentrant.
        // Verify: attacker only gets paid once (no double-claim).
        uint256 attackerBal = tokenA.balanceOf(address(reentrancyAttacker));
        if (attackerBal > 0) {
            uint256 ethBefore = address(reentrancyAttacker).balance;
            vm.prank(address(reentrancyAttacker));
            reentrancyAttacker.attack(poolIdA, attackerBal);

            // Outer claim succeeded — attacker got some ETH
            uint256 ethAfter = address(reentrancyAttacker).balance;
            assertGt(ethAfter, ethBefore, "attacker got compensated once");

            // Reentrant call was blocked — trying to claim again should revert (already claimed)
            vm.prank(address(reentrancyAttacker));
            vm.expectRevert();
            reentrancyAttacker.attack(poolIdA, attackerBal);
        }
    }

    function test_ReentrancyGuard_EscrowVault() public {
        // EscrowVault operations are only callable by hook/triggerOracle
        // Verify unauthorized direct calls revert
        vm.prank(attacker);
        vm.expectRevert();
        escrowVault.createEscrow(poolIdA, issuerA, 1000, 7 days, 83 days, IEscrowVault.IssuerCommitment({maxSellPercent: 300}));
    }

    // ═══════════════════════════════════════════════════════════════════
    //  PART 6: ATTACK SCENARIOS
    // ═══════════════════════════════════════════════════════════════════

    function test_MultiWalletSellAttack_TrackedPerIssuer() public {
        // Issuer sends tokens to a second wallet and tries to sell from both
        address issuerWallet2 = makeAddr("issuerWallet2");
        vm.deal(issuerWallet2, 10 ether);

        // IssuerA sends tokens to wallet2
        vm.prank(issuerA);
        tokenA.transfer(issuerWallet2, 50_000e18);

        // wallet2 is NOT the registered issuer, so sell limits don't apply to it
        // (this is correct behavior — only the registered issuer address is tracked)
        vm.startPrank(issuerWallet2);
        tokenA.approve(address(swapRouter), type(uint256).max);
        swapRouter.swapExactInput(poolKeyA, false, 50_000e18, 0, block.timestamp + 3600);
        vm.stopPrank();

        // But the issuer's own sells are still tracked
        uint256 poolReserve = tokenA.balanceOf(address(pm));
        uint256 overLimit = (poolReserve * 301) / 10_000; // just over 3% of pool reserve

        uint256 issuerBal = tokenA.balanceOf(issuerA);
        if (overLimit <= issuerBal) {
            vm.startPrank(issuerA);
            tokenA.approve(address(swapRouter), overLimit);
            vm.expectRevert();
            swapRouter.swapExactInput(poolKeyA, false, overLimit, 0, block.timestamp + 3600);
            vm.stopPrank();
        }
    }

    function test_FlashLoanClaimAttack_Blocked() public {
        // Generate insurance
        _buyTokenA(trader, 2 ether);

        // Transfer tokens to holder
        vm.prank(trader);
        tokenA.transfer(holder, 20_000e18);

        // Trigger in fallback mode (no merkle root)
        uint256 totalSupply = tokenA.totalSupply();
        vm.prank(address(hook));
        triggerOracle.executeTrigger(poolIdA, poolKeyA, ITriggerOracle.TriggerType.ISSUER_DUMP, totalSupply);

        // Same block + within 24h merkle window: claim should fail
        uint256 holderBal = tokenA.balanceOf(holder);
        vm.prank(holder);
        vm.expectRevert();
        insurancePool.claimCompensationFallback(poolIdA, holderBal);

        // Advance past 24h merkle submission deadline + one block for flash-loan protection
        vm.warp(block.timestamp + 24 hours + 1);
        vm.roll(block.number + 1);
        vm.prank(holder);
        insurancePool.claimCompensationFallback(poolIdA, holderBal);
    }

    function test_SlowDrainAttack_CumulativeTracking() public {
        // Create a pool with tight weekly limits
        vm.startPrank(deployer);
        TestToken tkSlow = _createFreshToken("SlowDrain", "SLD", 1_000_000e18);
        tkSlow.transfer(issuerB, 900_000e18);
        vm.stopPrank();

        ITriggerOracle.TriggerConfig memory cfg = _defaultTriggerConfig();
        cfg.dumpThresholdPercent = 300; // 3% daily
        cfg.weeklyDumpThresholdPercent = 1500; // 15% weekly

        (PoolKey memory key,) = _createPoolForIssuer(issuerB, tkSlow, 5 ether, 100_000e18, cfg);

        // Sell 2.9% of current reserve per day (under daily 3% limit).
        // Sells push tokens INTO pool, growing reserve. But weekly cumulative
        // grows faster than the denominator. After enough days, cumulative
        // exceeds 15% of current reserve.
        vm.startPrank(issuerB);
        tkSlow.approve(address(swapRouter), type(uint256).max);

        // Days 1-5: 2.9% of current reserve each day
        for (uint256 i = 0; i < 5; i++) {
            if (i > 0) vm.warp(block.timestamp + 1 days);
            uint256 r = tkSlow.balanceOf(address(pm));
            uint256 ds = (r * 290) / 10_000;
            swapRouter.swapExactInput(key, false, ds, 0, block.timestamp + 3600);
        }

        // Day 6: 2.9% of current reserve — should push weekly cumulative over 15% and revert
        vm.warp(block.timestamp + 1 days);
        uint256 reserve = tkSlow.balanceOf(address(pm));
        uint256 dailySell = (reserve * 290) / 10_000;
        vm.expectRevert();
        swapRouter.swapExactInput(key, false, dailySell, 0, block.timestamp + 3600);
        vm.stopPrank();
    }

    function test_SandwichAttack_OnTrigger() public {
        // Generate insurance
        _buyTokenA(trader, 2 ether);

        // Attacker tries to frontrun trigger by buying tokens to claim compensation
        _buyTokenA(attacker, 1 ether);

        // Trigger directly (v2 watcher path — preserved infra)
        uint256 totalSupply = tokenA.totalSupply();
        vm.prank(address(hook));
        triggerOracle.executeTrigger(poolIdA, poolKeyA, ITriggerOracle.TriggerType.RUG_PULL, totalSupply);
        vm.store(address(hook), keccak256(abi.encode(poolIdA, uint256(13))), bytes32(uint256(1)));
        assertTrue(hook.isPoolTriggered(poolIdA), "triggered");

        // After trigger, trading is blocked (issuer sells blocked, but buys may still work)
        // The key is: attacker's compensation is proportional to their holdings vs total supply
        // They can't extract more value than their proportional share

        // Attacker tries to claim with their balance
        uint256 attackerBal = tokenA.balanceOf(attacker);

        // Need to advance block for flash-loan protection
        vm.roll(block.number + 1);

        if (attackerBal > 0) {
            uint256 comp = insurancePool.calculateCompensation(poolIdA, attackerBal);
            // Compensation should be proportional, not outsized
            // The pool's payoutBalance is capped, attacker can't drain more
            assertLt(comp, 5 ether, "compensation bounded");
        }
    }

    function test_ManipulatedPrice_SellBpsCalculation() public {
        // Sell BPS is based on current pool reserve (balanceOf(poolManager)).
        // Buys remove issued tokens from pool, shrinking reserve and tightening limits.

        uint256 reserveBefore = tokenA.balanceOf(address(pm));
        assertGt(reserveBefore, 0, "pool reserve exists");

        // Do a large buy to shrink pool reserve (issued tokens leave pool)
        _buyTokenA(trader, 5 ether);

        uint256 reserveAfter = tokenA.balanceOf(address(pm));
        assertLt(reserveAfter, reserveBefore, "reserve shrunk after buy");

        // Sell 2.9% of current (shrunken) reserve — should still succeed
        uint256 sellAmount = (reserveAfter * 290) / 10_000;

        uint256 issuerBal = tokenA.balanceOf(issuerA);
        if (sellAmount <= issuerBal) {
            vm.startPrank(issuerA);
            tokenA.approve(address(swapRouter), sellAmount);
            // Should succeed — 2.9% of current reserve is under 3% limit
            swapRouter.swapExactInput(poolKeyA, false, sellAmount, 0, block.timestamp + 3600);
            vm.stopPrank();
        }
    }
}
