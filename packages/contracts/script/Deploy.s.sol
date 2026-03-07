// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {BastionHook} from "../src/hooks/BastionHook.sol";
import {BastionSwapRouter} from "../src/router/BastionSwapRouter.sol";
import {BastionPositionRouter} from "../src/router/BastionPositionRouter.sol";
import {EscrowVault} from "../src/core/EscrowVault.sol";
import {InsurancePool} from "../src/core/InsurancePool.sol";
import {TriggerOracle} from "../src/core/TriggerOracle.sol";
import {ReputationEngine} from "../src/core/ReputationEngine.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";

import {BastionDeployer} from "./BastionDeployer.sol";
import {HookMiner} from "./HookMiner.sol";

/// @title Deploy
/// @notice Deployment script for BastionSwap protocol contracts.
///         Resolves circular immutable dependencies via nonce-based address pre-computation
///         and deploys BastionHook to a CREATE2-mined address matching V4 hook flag pattern.
contract Deploy is Script {
    // Hook permission flags: beforeAddLiquidity | beforeRemoveLiquidity | beforeSwap | afterSwap
    uint160 constant HOOK_FLAGS =
        uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);

    struct Addresses {
        address factory;
        address escrow;
        address insurance;
        address trigger;
        address reputation;
        address hook;
        bytes32 salt;
        bytes hookCreationCode;
    }

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        (address poolManager, address governance, address guardian, address weth, address usdc) = _loadConfig(deployer);

        console2.log("=== BastionSwap Deployment ===");
        console2.log("Chain ID:", block.chainid);
        console2.log("Deployer:", deployer);
        console2.log("PoolManager:", poolManager);

        // ─── Phase 1: Pre-compute addresses (off-chain) ─────────────────

        Addresses memory a = _precompute(deployer, poolManager, governance, weth, usdc);

        console2.log("Hook address:", a.hook);
        console2.log("Salt:", vm.toString(a.salt));

        // ─── Phase 2: Deploy contracts (on-chain) ───────────────────────

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy CREATE2 factory (nonce N)
        BastionDeployer factory = new BastionDeployer();
        require(address(factory) == a.factory, "Factory address mismatch");

        // 2. Deploy EscrowVault (nonce N+1)
        EscrowVault escrowVault = new EscrowVault(a.hook, a.trigger, a.reputation);
        require(address(escrowVault) == a.escrow, "EscrowVault address mismatch");

        // 3. Deploy InsurancePool (nonce N+2)
        InsurancePool insurancePool = new InsurancePool(a.hook, a.trigger, governance, a.escrow, deployer);
        require(address(insurancePool) == a.insurance, "InsurancePool address mismatch");

        // 4. Deploy TriggerOracle (nonce N+3)
        TriggerOracle triggerOracle = new TriggerOracle(a.hook, a.escrow, a.insurance, guardian, a.reputation);
        require(address(triggerOracle) == a.trigger, "TriggerOracle address mismatch");

        // 5. Deploy ReputationEngine (nonce N+4)
        ReputationEngine reputationEngine = new ReputationEngine(a.hook, a.escrow, a.trigger);
        require(address(reputationEngine) == a.reputation, "ReputationEngine address mismatch");

        // 6. Deploy BastionHook via CREATE2
        address deployedHook = factory.deploy(a.salt, a.hookCreationCode);
        require(deployedHook == a.hook, "Hook address mismatch");

        // 7. Deploy routers and wire up cross-references
        ISignatureTransfer permit2 = ISignatureTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);
        BastionSwapRouter swapRouter = new BastionSwapRouter(IPoolManager(poolManager), permit2);
        BastionPositionRouter positionRouter = new BastionPositionRouter(IPoolManager(poolManager), permit2);

        BastionHook(payable(deployedHook)).setBastionRouter(address(positionRouter));
        swapRouter.setBastionHook(deployedHook);
        positionRouter.setBastionHook(deployedHook);

        vm.stopBroadcast();

        // ─── Phase 3: Log and write output ──────────────────────────────

        console2.log("");
        console2.log("=== Deployment Complete ===");
        console2.log("BastionDeployer:      ", a.factory);
        console2.log("BastionHook:          ", a.hook);
        console2.log("EscrowVault:          ", a.escrow);
        console2.log("InsurancePool:        ", a.insurance);
        console2.log("TriggerOracle:        ", a.trigger);
        console2.log("ReputationEngine:     ", a.reputation);
        console2.log("BastionSwapRouter:    ", address(swapRouter));
        console2.log("BastionPositionRouter:", address(positionRouter));

        _writeDeploymentJson(a, address(swapRouter), address(positionRouter));
    }

    // ─── Internal Helpers ───────────────────────────────────────────────

    function _precompute(address deployer, address poolManager, address governance, address weth, address usdc)
        internal
        view
        returns (Addresses memory a)
    {
        uint64 nonce = vm.getNonce(deployer);
        console2.log("Deployer nonce:", nonce);

        // Deployment order: Factory(N), EscrowVault(N+1), InsurancePool(N+2), TriggerOracle(N+3), ReputationEngine(N+4)
        a.factory = vm.computeCreateAddress(deployer, nonce);
        a.escrow = vm.computeCreateAddress(deployer, nonce + 1);
        a.insurance = vm.computeCreateAddress(deployer, nonce + 2);
        a.trigger = vm.computeCreateAddress(deployer, nonce + 3);
        a.reputation = vm.computeCreateAddress(deployer, nonce + 4);

        // Build BastionHook creation bytecode with constructor args
        a.hookCreationCode = abi.encodePacked(
            type(BastionHook).creationCode,
            abi.encode(poolManager, a.escrow, a.insurance, a.trigger, a.reputation, governance, weth, usdc)
        );

        // Mine CREATE2 salt for hook flag matching
        console2.log("Mining CREATE2 salt for hook flags 0x0AC0...");
        (a.hook, a.salt) = HookMiner.find(a.factory, HOOK_FLAGS, a.hookCreationCode, 0);

        require(uint160(a.hook) & 0x3FFF == HOOK_FLAGS, "Hook flag mismatch");
    }

    function _loadConfig(address deployer)
        internal
        view
        returns (address poolManager, address governance, address guardian, address weth, address usdc)
    {
        if (block.chainid == 84532) {
            poolManager = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
            usdc = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
        } else if (block.chainid == 8453) {
            poolManager = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
            usdc = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
        } else {
            revert("Unsupported chain");
        }

        weth = 0x4200000000000000000000000000000000000006; // Same on all Base chains
        governance = vm.envOr("GOVERNANCE", deployer);
        guardian = vm.envOr("GUARDIAN", deployer);
    }

    function _writeDeploymentJson(Addresses memory a, address swapRouter, address positionRouter) internal {
        string memory obj = "deployment";
        vm.serializeUint(obj, "chainId", block.chainid);
        vm.serializeAddress(obj, "bastionDeployer", a.factory);
        vm.serializeAddress(obj, "bastionHook", a.hook);
        vm.serializeAddress(obj, "escrowVault", a.escrow);
        vm.serializeAddress(obj, "insurancePool", a.insurance);
        vm.serializeAddress(obj, "triggerOracle", a.trigger);
        vm.serializeAddress(obj, "reputationEngine", a.reputation);
        vm.serializeAddress(obj, "bastionSwapRouter", swapRouter);
        string memory json = vm.serializeAddress(obj, "bastionPositionRouter", positionRouter);

        string memory dir = "deployments/";
        vm.createDir(dir, true);
        string memory path = string.concat(dir, vm.toString(block.chainid), ".json");
        vm.writeJson(json, path);
        console2.log("Deployment JSON written to:", path);
    }
}
