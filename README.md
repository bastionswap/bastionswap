# BastionSwap: Escrow-Native DEX Protocol

[![License: BUSL-1.1](https://img.shields.io/badge/License-BUSL--1.1-blue.svg)](LICENSE)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.26-363636.svg)](https://soliditylang.org/)
[![Foundry](https://img.shields.io/badge/Built%20with-Foundry-FFDB1C.svg)](https://book.getfoundry.sh/)
[![Base Sepolia](https://img.shields.io/badge/Testnet-Base%20Sepolia-0052FF.svg)](https://sepolia.basescan.org)

BastionSwap is a **Uniswap V4 Hook-based** decentralized exchange protocol that protects traders from rug-pulls and token exploits through **mandatory escrow vesting**, **on-chain trigger detection**, and **per-token insurance pools**.

When a token issuer creates a liquidity pool, their LP is automatically locked with a vesting schedule (lock-up + linear vesting). Issuer sell limits are enforced on-chain — exceeding daily or weekly limits reverts the entire swap transaction, blocking sales via any path including routers and aggregators. If LP removal thresholds are breached, remaining issuer LP is immediately seized and combined with the insurance pool for pro-rata compensation to non-issuer token holders.

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
| BastionHook | [`0x61590C0544B562571AAad49e255496a0a0350AC8`](https://sepolia.basescan.org/address/0x61590C0544B562571AAad49e255496a0a0350AC8) |
| BastionSwapRouter | [`0xF21Ae872b7C544b83b25b1D639190Dd98C7a8062`](https://sepolia.basescan.org/address/0xF21Ae872b7C544b83b25b1D639190Dd98C7a8062) |
| BastionPositionRouter | [`0x7Bcf5618c55AadDD2451b93102285267622Bb67A`](https://sepolia.basescan.org/address/0x7Bcf5618c55AadDD2451b93102285267622Bb67A) |
| EscrowVault | [`0xBE3D91851aAf9F6A2ca8B47567180305996E16Dd`](https://sepolia.basescan.org/address/0xBE3D91851aAf9F6A2ca8B47567180305996E16Dd) |
| InsurancePool | [`0xf908a6c13C80290993A7c2d57023c8531Ecf3406`](https://sepolia.basescan.org/address/0xf908a6c13C80290993A7c2d57023c8531Ecf3406) |
| TriggerOracle | [`0x782b6e95072f88fcc7729F46c5FF19a1Fdad2D3b`](https://sepolia.basescan.org/address/0x782b6e95072f88fcc7729F46c5FF19a1Fdad2D3b) |
| ReputationEngine | [`0x3eC8DeFc934fbD99fC64EFBae4B7e72f24DAF034`](https://sepolia.basescan.org/address/0x3eC8DeFc934fbD99fC64EFBae4B7e72f24DAF034) |

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
    BH -->|reportLPRemoval| TO
    BH -->|enforce sell limits (revert)| BH
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
| **BastionHook** | V4 Hook entry point. Intercepts `beforeAddLiquidity`, `beforeRemoveLiquidity`, `beforeSwap`, and `afterSwap` to orchestrate escrow locking, insurance fee collection, and rug-pull monitoring. Enforces issuer daily and weekly sell limits by reverting swap transactions in afterSwap when limits are exceeded — blocks sales via any path including routers and aggregators. Validates token compatibility (rejects fee-on-transfer and rebase tokens from Bastion Protected pools). Records LP/supply ratio at pool creation for dashboard transparency. |
| **BastionSwapRouter** | Swap-only router handling exact-input, exact-output, and multi-hop swaps via PoolManager unlock callbacks. Emits `SwapExecuted` with actual user address. |
| **BastionPositionRouter** | LP management router for pool creation, liquidity add/remove, and fee collection. Emits `LiquidityChanged` for subgraph indexing. |
| **EscrowVault** | Manages issuer LP removal rights with lock-up + linear vesting. Does not custody assets — controls removal permissions only. Per-pool commitment parameters (immutable) set by issuer at creation. Coordinates forced LP removal on trigger events. |
| **InsurancePool** | Collects 1% fee from buy-side swaps as per-token insurance premiums. On trigger: distributes insurance pool + seized issuer LP to non-issuer holders (Merkle proof, 30-day window). On normal completion: 10% to issuer as vesting reward, 90% to protocol treasury. Issuer address excluded from all claims. |
| **TriggerOracle** | Monitors LP removal patterns and enforces cumulative thresholds. LP removal triggers use permissionless executeTrigger with immediate execution (no grace period). Issuer sell limits are enforced separately via BastionHook afterSwap revert. |
| **ReputationEngine** | Computes informational reputation scores (0-1000) for token issuers based on on-chain history. Non-blocking. |

### Protection Mechanisms

BastionSwap uses two defense mechanisms:
**Hard Enforcement (revert)** — Invalidates the transaction on violation.
**Trigger-based (LP seizure)** — Seizes issuer LP when cumulative thresholds are breached.

#### Hard Enforcement (Transaction Revert)

These mechanisms block violations before or after execution. The transaction reverts, so the issuer cannot extract assets. Does not fire a trigger (no LP seizure).

| Protection | How | When | Default Limit |
|-----------|-----|------|---------------|
| Single-tx LP removal | `beforeRemoveLiquidity` revert | Issuer attempts to remove LP exceeding single-tx limit | >50% of total LP |
| Daily sell limit | `afterSwap` revert (rollback) | Issuer's token balance decreases beyond daily cumulative limit. Detects sales via any path (direct, router, aggregator) by comparing issuer balance before/after swap | >3% of initial supply per 24h |
| Weekly sell limit | `afterSwap` revert (rollback) | Same mechanism, 7-day rolling window | >15% of initial supply per 7d |
| Vesting enforcement | `beforeRemoveLiquidity` revert | Issuer tries to remove more LP than currently vested | Based on lock-up + linear vesting schedule |
| Token compatibility | `createPool` revert (in router) | Fee-on-transfer or rebase token detected via transfer test | Exact amount must be received |

#### Trigger-based (LP Seizure + Compensation)

When cumulative violations reach the threshold, issuer LP is forcibly seized and redistributed to holders. `executeTrigger()` is permissionless — anyone can call it. Immediate execution with no grace period.

| Trigger | Detection | Default Threshold | Response |
|---------|-----------|-------------------|----------|
| Cumulative LP removal | On-chain: cumulative LP removals within 24h window | >80% of total LP | Immediate LP seizure. Seized assets + insurance pool → non-issuer holders via Merkle proof (30d) or fallback balanceOf (7d) |

#### Planned (v0.2 — Requires Decentralized Watcher Network)

| Trigger | Detection | Response |
|---------|-----------|----------|
| Honeypot | Watcher network: transfer() revert detection | LP seizure + compensation |
| Hidden Tax | Watcher network: swap output deviation >5% | LP seizure + compensation |

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
| Merkle | Guardian submits Merkle root within 24h | Holder submits Merkle proof for trigger-time balance | 30 days |
| Fallback | Guardian does not respond within 24h | Holder claims via balanceOf (must have held tokens at trigger block) | 7 days |

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
forge test -vvv                          # 395 tests passing
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
