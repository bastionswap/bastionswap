# Local Development Guide

BastionSwap local dev uses a Base mainnet fork on Anvil. This gives you real Uniswap V4 PoolManager, USDC, WETH, and existing pools — no testnet faucets needed.

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (anvil, forge, cast)
- [pnpm](https://pnpm.io/installation)
- Node.js 18+

## Quick Start

```bash
# 1. Set RPC (public endpoint works, but a paid one is faster)
export BASE_MAINNET_RPC=https://mainnet.base.org

# 2. Start everything (Anvil + deploy + frontend)
pnpm dev
```

This will:
1. Start Anvil forking Base mainnet on `http://127.0.0.1:8545`
2. Build and deploy all BastionSwap contracts
3. Copy ABIs and generate frontend contract addresses
4. Start the Next.js frontend on `http://localhost:3000`

## Test Accounts

Anvil provides 10 pre-funded accounts (10,000 ETH each):

| Account | Address | Usage |
|---------|---------|-------|
| #0 | `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266` | Deployer / Issuer |
| #1 | `0x70997970C51812dc3A010C7d01b50e0d17dc79C8` | Trader |

Import Account #0 into MetaMask using private key:
```
0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```

## MetaMask Setup

Add the local network to MetaMask:
- **Network Name:** Base Fork (Local)
- **RPC URL:** http://127.0.0.1:8545
- **Chain ID:** 31337
- **Currency Symbol:** ETH

## Contract Changes (Hot Reload)

After modifying Solidity code:

```bash
pnpm redeploy
```

This resets the fork, redeploys all contracts, and updates frontend config. Refresh the browser to see changes.

## Scripts

| Command | Description |
|---------|-------------|
| `pnpm dev` | Start Anvil + deploy + frontend |
| `pnpm redeploy` | Reset fork + redeploy contracts + update frontend |

## Architecture

```
Anvil (port 8545)
  └─ Base mainnet fork (chainId 31337)
      ├─ Uniswap V4 PoolManager (from mainnet)
      ├─ BastionHook (deployed via CREATE2)
      ├─ EscrowVault, InsurancePool, TriggerOracle, ReputationEngine
      ├─ BastionSwapRouter, BastionPositionRouter
      └─ TestToken (BTT) with faucet
```

## Troubleshooting

**Anvil fails to start:**
- Check if another Anvil is already running: `pkill -f anvil`
- Verify your RPC: `curl -s $BASE_MAINNET_RPC -X POST -H "Content-Type: application/json" -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'`

**MetaMask nonce issues:**
- After redeployment, reset MetaMask account: Settings > Advanced > Clear activity tab data

**Frontend shows wrong addresses:**
- Run `pnpm redeploy` to regenerate `contracts.generated.ts`
