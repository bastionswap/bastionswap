# BastionSwap: Escrow-Native DEX Protocol

[![License: BUSL-1.1](https://img.shields.io/badge/License-BUSL--1.1-blue.svg)](LICENSE)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.26-363636.svg)](https://soliditylang.org/)
[![Foundry](https://img.shields.io/badge/Built%20with-Foundry-FFDB1C.svg)](https://book.getfoundry.sh/)
[![Base Sepolia](https://img.shields.io/badge/Testnet-Base%20Sepolia-0052FF.svg)](https://sepolia.basescan.org)

BastionSwap is a **Uniswap V4 Hook-based** decentralized exchange protocol that protects traders from rug-pulls and token exploits through **mandatory escrow vesting**, **on-chain trigger detection**, and **per-token insurance pools**.

When a token issuer creates a liquidity pool, their LP is automatically locked with a vesting schedule (lock-up + linear vesting). All issuer violations are enforced on-chain via **transaction revert** — exceeding sell limits, single-tx LP removal limits, or cumulative LP removal limits reverts the entire transaction, blocking the action via any path including routers and aggregators. Trigger-based LP seizure infrastructure is preserved for v2 watcher network integration.

## Live Demo (Base Sepolia)

> **[bastionswap.xyz](https://bastionswap.xyz/)** — Try it now on Base Sepolia testnet

| Resource | Link |
|----------|------|
| Frontend | [bastionswap.xyz](https://bastionswap.xyz/) |
| Subgraph Studio | [thegraph.com/studio/subgraph/bastionswap-base-sepolia](https://thegraph.com/studio/subgraph/bastionswap-base-sepolia/) |
| Subgraph API | [GraphQL Playground](https://api.studio.thegraph.com/query/1724500/bastionswap-base-sepolia/version/latest) |
| Block Explorer | [BaseScan (Sepolia)](https://sepolia.basescan.org) |

## Contract Addresses (Base Sepolia)

All contracts are deployed on Base Sepolia (v4 — split routers for EIP-170 compliance).

| Contract | Address |
|----------|---------|
| BastionHook | [`0x88214539803B55a86f7e924BCE0eECB6B610cac8`](https://sepolia.basescan.org/address/0x88214539803B55a86f7e924BCE0eECB6B610cac8) |
| BastionSwapRouter | [`0x8997d846A8bF5E8Ef662aFC620f35aB692dc166C`](https://sepolia.basescan.org/address/0x8997d846A8bF5E8Ef662aFC620f35aB692dc166C) |
| BastionPositionRouter | [`0x3Ae0B68e0e36A57d8e416CD4e57d89058d0d1A11`](https://sepolia.basescan.org/address/0x3Ae0B68e0e36A57d8e416CD4e57d89058d0d1A11) |
| EscrowVault | [`0x0e7A077Bbc902f179Ae136D3a9810b97eB1aEB3b`](https://sepolia.basescan.org/address/0x0e7A077Bbc902f179Ae136D3a9810b97eB1aEB3b) |
| InsurancePool | [`0x9646d06B5d7F914481214e8870C883a4D2B5f858`](https://sepolia.basescan.org/address/0x9646d06B5d7F914481214e8870C883a4D2B5f858) |
| TriggerOracle | [`0x3909f264a3f92622c05420Fb0af6F219600825B8`](https://sepolia.basescan.org/address/0x3909f264a3f92622c05420Fb0af6F219600825B8) |
| ReputationEngine | [`0x093D568eCc2620Af3E11Eb2906a5DdC08Defa0d8`](https://sepolia.basescan.org/address/0x093D568eCc2620Af3E11Eb2906a5DdC08Defa0d8) |

**External Dependencies:**

| Contract | Address |
|----------|---------|
| Uniswap V4 PoolManager | `0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408` |
| WETH (Base) | `0x4200000000000000000000000000000000000006` |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |

## Architecture

```mermaid
graph TB
    subgraph "Uniswap V4"
        PM[PoolManager]
    end

    subgraph "BastionSwap Protocol"
        BH[BastionHook]
        EV[EscrowVault]
        IP[InsurancePool]
        TO[TriggerOracle]
        RE[ReputationEngine]
    end

    subgraph "Frontend & Indexing"
        FE[Next.js Frontend]
        SG[The Graph Subgraph]
    end

    subgraph "Actors"
        IS[Token Issuer]
        TR[Trader]
        CL[Token Holder]
    end

    subgraph "Routers"
        SR[BastionSwapRouter]
        PR[BastionPositionRouter]
    end

    IS -->|createPool / addLiquidity| PR
    TR -->|swap| SR
    SR -->|unlock + swap| PM
    PR -->|unlock + modifyLiquidity| PM
    PM -->|hook callbacks| BH

    BH -->|createEscrow| EV
    BH -->|depositFee| IP
    BH -->|enforce all violations (revert)| BH
    BH -->|recordEvent| RE

    TO -->|executeTrigger (permissionless, no grace period)| EV
    TO -->|executePayout| IP

    EV -.->|remaining funds on trigger| IP
    CL -->|claimCompensation| IP
    IS -->|releaseVested| EV

    SG -->|indexes events| BH
    SG -->|indexes events| EV
    SG -->|indexes events| IP
    SG -->|indexes events| TO
    SG -->|indexes events| RE
    SG -->|indexes events| SR
    SG -->|indexes events| PR
    FE -->|queries| SG
    FE -->|contract calls| SR
    FE -->|contract calls| PR

    style BH fill:#4f46e5,color:#fff
    style EV fill:#0891b2,color:#fff
    style IP fill:#059669,color:#fff
    style TO fill:#dc2626,color:#fff
    style RE fill:#7c3aed,color:#fff
    style PM fill:#f59e0b,color:#fff
    style SR fill:#ea580c,color:#fff
    style PR fill:#ea580c,color:#fff
    style FE fill:#171717,color:#fff
    style SG fill:#6747ed,color:#fff
```

### Contract Roles

| Contract | Role |
|----------|------|
| **BastionHook** | V4 Hook entry point. Intercepts `beforeAddLiquidity`, `beforeRemoveLiquidity`, `beforeSwap`, and `afterSwap` to orchestrate escrow locking, insurance fee collection, and issuer violation enforcement. All violations (sell limits, single-tx LP removal, cumulative LP removal) are enforced via transaction revert — blocks actions via any path including routers and aggregators. Validates token compatibility (rejects fee-on-transfer and rebase tokens from Bastion Protected pools). Records LP/supply ratio at pool creation for dashboard transparency. |
| **BastionSwapRouter** | Swap-only router handling exact-input, exact-output, and multi-hop swaps via PoolManager unlock callbacks. Emits `SwapExecuted` with actual user address. |
| **BastionPositionRouter** | LP management router for pool creation, liquidity add/remove, and fee collection. Emits `LiquidityChanged` for subgraph indexing. |
| **EscrowVault** | Manages issuer LP removal rights with lock-up + linear vesting. Does not custody assets — controls removal permissions only. Per-pool commitment parameters (immutable) set by issuer at creation. Coordinates forced LP removal on trigger events. |
| **InsurancePool** | Collects 1% fee from buy-side swaps as per-token insurance premiums. On trigger: distributes insurance pool + seized issuer LP to non-issuer holders (Merkle proof, 30-day window). On normal completion: 10% to issuer as vesting reward, 90% to protocol treasury. Issuer address excluded from all claims. |
| **TriggerOracle** | Trigger infrastructure for LP seizure and compensation. In v1, all violations are enforced via revert in BastionHook. `executeTrigger()` interface is preserved for v2 watcher network integration (honeypot/hidden-tax detection). |
| **ReputationEngine** | Computes informational reputation scores (0-1000) for token issuers based on on-chain history. Non-blocking. |

### Protection Mechanisms (v1)

BastionSwap v1 uses **revert-only enforcement** — all issuer violations are blocked by reverting the transaction. The issuer cannot extract assets. Trigger-based LP seizure infrastructure is preserved for v2.

#### Hard Enforcement (Transaction Revert)

| Protection | How | When | Default Limit |
|-----------|-----|------|---------------|
| Single-tx LP removal | `beforeRemoveLiquidity` revert | Issuer attempts to remove LP exceeding single-tx limit | >50% of total LP |
| Cumulative LP removal | `beforeRemoveLiquidity` revert | Cumulative LP removals within 24h window exceed threshold | >80% of total LP |
| Daily sell limit | `afterSwap` revert (rollback) | Issuer's token balance decreases beyond daily cumulative limit. Detects sales via any path (direct, router, aggregator) by comparing issuer balance before/after swap | >3% of initial supply per 24h |
| Weekly sell limit | `afterSwap` revert (rollback) | Same mechanism, 7-day rolling window | >15% of initial supply per 7d |
| Vesting enforcement | `beforeRemoveLiquidity` revert | Issuer tries to remove more LP than currently vested | Based on lock-up + linear vesting schedule |
| Token compatibility | `createPool` revert (in router) | Fee-on-transfer or rebase token detected via transfer test | Exact amount must be received |

#### Planned (v2 — Trigger-based LP Seizure + Watcher Network)

`executeTrigger()` interface and TriggerOracle/InsurancePool compensation infrastructure are preserved for v2.

| Trigger | Detection | Response |
|---------|-----------|----------|
| Honeypot | Watcher network: transfer() revert detection | LP seizure + compensation |
| Hidden Tax | Watcher network: swap output deviation >5% | LP seizure + compensation |
| Cumulative LP removal (upgrade) | Watcher network: on-chain cumulative tracking confirmation | LP seizure + compensation (replaces revert-only) |

### Two-Layer Parameter System

**Governance Layer** (protocol-wide defaults):
Controlled by governance (initially deployer EOA, later DAO). Changes only affect newly created pools.
- Insurance fee rate (default: 1%, range: 0.1%–5%)
- Base token whitelist (ETH, WETH, USDC)
- Minimum initial liquidity per token
- Default/minimum lock-up and vesting durations
- LP removal and sell limit default thresholds
- TVL cap, treasury/guardian addresses, claim periods
- Issuer vesting reward percentage (default: 10%)
- Merkle submission deadline (default: 24h, range: 6h–72h)
- TriggerOracle config validation (BPS fields 1–10000, time windows bounded)

**Issuer Layer** (per-pool commitments):
Set by issuer at pool creation. Immutable once set. Must be equal to or stricter than governance minimums.
- Lock-up duration (≥ governance minimum)
- Vesting duration (≥ governance minimum)
- Max single-tx LP removal (≤ governance default)
- Max 24h cumulative LP removal (≤ governance default)
- Max daily sell (≤ governance default)
- Max weekly sell (≤ governance default)

Governance changes never affect existing pool commitments.

### Compensation Claims

Two mutually exclusive claim modes. Once a mode is determined, it cannot be switched.

| Mode | Condition | Claim Method | Period |
|------|-----------|--------------|--------|
| Merkle | Guardian submits Merkle root within deadline (default: 24h, configurable 6h–72h) | Holder submits Merkle proof for trigger-time balance | 30 days |
| Fallback | Guardian does not respond within deadline | Holder claims via balanceOf (must have held tokens at trigger block) | 7 days |

- Issuer address excluded from all compensation claims
- Fallback mode is irreversible — Merkle root submission blocked after activation
- Flash-loan claim prevention: requires token holding at or before trigger block

## Quick Start

### Prerequisites

- [Node.js](https://nodejs.org/) >= 18
- [pnpm](https://pnpm.io/) >= 8
- [Foundry](https://book.getfoundry.sh/getting-started/installation) (forge, cast, anvil)

### Install

```bash
git clone https://github.com/your-username/bastionswap.git
cd bastionswap
pnpm install
```

### Build & Test (Contracts)

```bash
cd packages/contracts
forge build
forge test -vvv                          # 484 tests passing
FOUNDRY_PROFILE=deploy forge build --sizes  # All contracts < 24KB
```

### Run Frontend Locally

```bash
cd packages/frontend
cp .env.local.example .env.local  # or create manually
pnpm dev                          # http://localhost:3000
```

### Build Subgraph

```bash
cd packages/subgraph
pnpm codegen
pnpm build
```

### Deploy Contracts

```bash
cd packages/contracts
cp .env.example .env  # Fill in DEPLOYER_PRIVATE_KEY, BASE_SEPOLIA_RPC, ETHERSCAN_API_KEY
make deploy-testnet-dry   # Simulation
make deploy-testnet       # Broadcast + verify
```

Deployment output: `deployments/{chainId}.json`

## Project Structure

```
bastionswap/
├── packages/
│   ├── contracts/              # Foundry smart contracts
│   │   ├── src/
│   │   │   ├── hooks/BastionHook.sol
│   │   │   ├── router/         # BastionSwapRouter, BastionPositionRouter
│   │   │   ├── core/           # EscrowVault, InsurancePool, TriggerOracle, ReputationEngine
│   │   │   └── interfaces/     # Contract interfaces
│   │   ├── test/
│   │   │   ├── unit/           # Unit tests per contract
│   │   │   ├── integration/    # Integration & E2E scenario tests
│   │   │   └── invariant/      # Invariant/fuzz tests (10k runs, depth 50)
│   │   ├── script/             # Deploy.s.sol, E2ESimulation.s.sol
│   │   └── deployments/        # Chain-specific deployment records
│   │
│   ├── subgraph/               # The Graph protocol indexer
│   │   ├── schema.graphql      # Entity definitions
│   │   ├── subgraph.yaml       # Data source config
│   │   └── src/mappings/       # Event handlers (8 data sources)
│   │
│   └── frontend/               # Next.js 14 web application
│       ├── src/app/            # Pages: home, swap, create, pools, pool detail, history
│       ├── src/hooks/          # wagmi + subgraph custom hooks
│       ├── src/components/     # UI components (escrow, insurance, issuer, triggers)
│       └── src/config/         # Contracts, ABIs, wagmi, subgraph config
│
├── docs/
│   ├── ARCHITECTURE.md         # Protocol design & contract interactions
│   └── SECURITY.md             # Threat model & audit checklist
│
├── pnpm-workspace.yaml
└── turbo.json
```

## Tech Stack

| Layer | Technology |
|-------|------------|
| Smart Contracts | Solidity 0.8.26, Foundry, Uniswap V4 |
| Indexing | The Graph (Subgraph Studio) |
| Frontend | Next.js 14, React 18, TypeScript |
| Wallet | wagmi v2, RainbowKit, viem |
| Styling | Tailwind CSS (custom dark theme) |
| Data Fetching | graphql-request, @tanstack/react-query |
| Target Chain | Base (EVM Cancun) |

## Vercel Deployment

1. Import the GitHub repo on [vercel.com](https://vercel.com)
2. Configure:
   - **Root Directory**: `packages/frontend`
   - **Framework Preset**: Next.js
   - **Build Command**: `pnpm build`
3. Set environment variables:
   ```
   NEXT_PUBLIC_SUBGRAPH_URL=https://api.studio.thegraph.com/query/1724500/bastionswap-base-sepolia/version/latest
   NEXT_PUBLIC_CHAIN_ID=84532
   NEXT_PUBLIC_WC_PROJECT_ID=<your-walletconnect-project-id>
   ```
4. Deploy

## Known Limitations

- **Multi-wallet evasion**: Issuer can transfer tokens to secondary wallets before selling. afterSwap tracks issuer wallet balance changes, but pre-transferred tokens are not detected. Mitigated by sell limits + LP/supply ratio transparency on dashboard.

- **Slow drain within limits**: Issuer selling at exactly below daily/weekly limits over months can drain significant value. Mitigated by insurance pool accumulation + dashboard showing cumulative sell history.

- **Fee-on-transfer / rebase tokens**: Incompatible with Bastion Protection. Can create Standard V4 pools only.

- **Fallback mode accuracy**: balanceOf-based claims in fallback mode reflect claim-time balances, not trigger-time balances. 7-day window + trigger-block holding requirement minimize manipulation but do not eliminate it.

## Documentation

- **[Architecture](docs/ARCHITECTURE.md)** — Protocol design, contract interactions, trigger mechanisms, deployment strategy
- **[Local Development](docs/LOCAL_DEV.md)** — Local environment setup with Anvil fork
- **[Security](docs/SECURITY.md)** — Threat model, 12 known attack vectors, mitigations, audit checklist

## License

Licensed under the [Business Source License 1.1](LICENSE) (BUSL-1.1).

- **Licensed Work**: BastionSwap Protocol
- **Change Date**: March 4, 2030
- **Change License**: GPL-2.0-or-later
