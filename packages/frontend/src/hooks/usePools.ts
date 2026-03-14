import { useQuery } from "@tanstack/react-query";
import { useChainId } from "wagmi";
import { formatUnits, keccak256, encodeAbiParameters, createPublicClient, http, defineChain } from "viem";
import { gql } from "graphql-request";
import { graphClient } from "@/config/subgraph";
import { getContracts } from "@/config/contracts";

const anvilChain = defineChain({
  id: 31337,
  name: "Anvil",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["http://127.0.0.1:8545"] } },
  contracts: {
    multicall3: { address: "0xcA11bde05977b3631167028862bE2a173976CA11" },
  },
});
import {
  BastionHookABI,
  EscrowVaultABI,
  InsurancePoolABI,
  ReputationEngineABI,
  PoolManagerABI,
} from "@/config/abis";

const BASTION_POOLS_QUERY = gql`
  query BastionPools {
    pools(
      where: { isBastion: true }
      orderBy: createdAt
      orderDirection: desc
      first: 100
    ) {
      id
      token0
      token1
      hook
      isBastion
      issuedToken
      reserve0
      reserve1
      issuer {
        id
        reputationScore
      }
      escrow {
        id
        totalLiquidity
        removedLiquidity
        remainingLiquidity
        isTriggered
      }
      insurancePool {
        id
        balance
        feeRate
        isTriggered
      }
      createdAt
      createdTx
    }
  }
`;

const ALL_POOLS_QUERY = gql`
  query AllPools {
    pools(orderBy: createdAt, orderDirection: desc, first: 100) {
      id
      token0
      token1
      hook
      isBastion
      issuedToken
      reserve0
      reserve1
      issuer {
        id
        reputationScore
      }
      escrow {
        id
        totalLiquidity
        removedLiquidity
        remainingLiquidity
        isTriggered
      }
      insurancePool {
        id
        balance
        feeRate
        isTriggered
      }
      createdAt
      createdTx
    }
  }
`;

const POOL_DETAIL_QUERY = gql`
  query PoolDetail($id: ID!) {
    pool(id: $id) {
      id
      token0
      token1
      hook
      isBastion
      issuedToken
      reserve0
      reserve1
      issuer {
        id
        reputationScore
        totalEscrowsCreated
        totalEscrowsCompleted
        totalTriggersActivated
      }
      escrow {
        id
        totalLiquidity
        removedLiquidity
        remainingLiquidity
        isTriggered
        createdAt
        lockDuration
        vestingDuration
        commitment {
          maxSellPercent
        }
      }
      insurancePool {
        id
        balance
        isTriggered
        triggerType
        merkleRoot
        useMerkleProof
        totalClaimed
        feeRate
        holderCount
      }
      triggerEvents(orderBy: timestamp, orderDirection: desc) {
        id
        triggerType
        triggerTypeName
        timestamp
        transactionHash
        withMerkleRoot
      }
      claims {
        id
        holder
        amount
        claimedAt
        transactionHash
      }
      createdAt
      createdTx
    }
  }
`;

export interface SubgraphPool {
  id: string;
  token0: string;
  token1: string;
  hook: string;
  isBastion: boolean;
  issuedToken: string | null;
  reserve0: string | null;
  reserve1: string | null;
  issuer: {
    id: string;
    reputationScore: string;
    totalEscrowsCreated?: number;
    totalEscrowsCompleted?: number;
    totalTriggersActivated?: number;
  } | null;
  escrow: {
    id: string;
    totalLiquidity: string;
    removedLiquidity: string;
    remainingLiquidity: string;
    isTriggered: boolean;
    createdAt?: string;
    lockDuration?: string;
    vestingDuration?: string;
    commitment?: {
      maxSellPercent: string;
    } | null;
  } | null;
  insurancePool: {
    id: string;
    balance: string;
    feeRate: number;
    isTriggered: boolean;
    triggerType?: number | null;
    merkleRoot?: string | null;
    useMerkleProof?: boolean;
    totalClaimed?: string;
    holderCount?: number;
  } | null;
  triggerEvents?: {
    id: string;
    triggerType: number;
    triggerTypeName: string;
    timestamp: string;
    transactionHash: string;
    withMerkleRoot: boolean;
  }[];
  claims?: {
    id: string;
    holder: string;
    amount: string;
    claimedAt: string;
    transactionHash: string;
  }[];
  createdAt: string;
  createdTx: string;
}

// ─── V4 pool reserve helpers ──────────────────────────────────

// PoolManager Pools mapping is at storage slot 6
const POOLS_SLOT = 6n;
const TICK_LOWER = -887220;
const TICK_UPPER = 887220;

function computePoolSlots(poolId: `0x${string}`) {
  // base = keccak256(abi.encode(poolId, POOLS_SLOT))
  const base = BigInt(
    keccak256(encodeAbiParameters(
      [{ type: "bytes32" }, { type: "uint256" }],
      [poolId, POOLS_SLOT],
    ))
  );
  // slot0 (sqrtPriceX96 packed) is at base, liquidity at base+3
  return {
    slot0: ("0x" + base.toString(16).padStart(64, "0")) as `0x${string}`,
    liquidity: ("0x" + (base + 3n).toString(16).padStart(64, "0")) as `0x${string}`,
  };
}

function computeReservesFromState(
  sqrtPriceX96Raw: bigint,
  liquidityRaw: bigint,
): { reserve0: string; reserve1: string } {
  const Q96 = 2 ** 96;
  const sqrtP = Number(sqrtPriceX96Raw) / Q96;
  const L = Number(liquidityRaw);

  if (sqrtP <= 0 || L <= 0) return { reserve0: "0", reserve1: "0" };

  const sqrtPLower = 1.0001 ** (TICK_LOWER / 2);
  const sqrtPUpper = 1.0001 ** (TICK_UPPER / 2);

  // token0 reserve = L * (sqrtP_upper - sqrtP) / (sqrtP * sqrtP_upper)
  const r0 = L * (sqrtPUpper - sqrtP) / (sqrtP * sqrtPUpper);
  // token1 reserve = L * (sqrtP - sqrtP_lower)
  const r1 = L * (sqrtP - sqrtPLower);

  return {
    reserve0: BigInt(Math.floor(Math.max(r0, 0))).toString(),
    reserve1: BigInt(Math.floor(Math.max(r1, 0))).toString(),
  };
}

// ─── Event ABIs for pool discovery ──────────────────────────────────

const IssuerRegisteredEvent = {
  type: "event" as const,
  name: "IssuerRegistered" as const,
  inputs: [
    { name: "poolId", type: "bytes32" as const, indexed: true, internalType: "PoolId" as const },
    { name: "issuer", type: "address" as const, indexed: true, internalType: "address" as const },
    { name: "issuedToken", type: "address" as const, indexed: false, internalType: "address" as const },
  ],
} as const;

const InitializeEvent = {
  type: "event" as const,
  name: "Initialize" as const,
  inputs: [
    { name: "id", type: "bytes32" as const, indexed: true, internalType: "PoolId" as const },
    { name: "currency0", type: "address" as const, indexed: true, internalType: "Currency" as const },
    { name: "currency1", type: "address" as const, indexed: true, internalType: "Currency" as const },
    { name: "fee", type: "uint24" as const, indexed: false, internalType: "uint24" as const },
    { name: "tickSpacing", type: "int24" as const, indexed: false, internalType: "int24" as const },
    { name: "hooks", type: "address" as const, indexed: false, internalType: "address" as const },
    { name: "sqrtPriceX96", type: "uint160" as const, indexed: false, internalType: "uint160" as const },
    { name: "tick", type: "int24" as const, indexed: false, internalType: "int24" as const },
  ],
} as const;

// ─── Local on-chain multi-pool discovery hook ──────────────────────────────────

// Dedicated public client for the local Anvil fork — independent of the
// wallet's connected chain so discovery works even when the wallet is on
// Base Sepolia or another network.
const anvilClient = createPublicClient({
  chain: anvilChain,
  transport: http("http://127.0.0.1:8545"),
});

function useLocalPoolsOnChain() {
  const contracts = getContracts(31337);

  const { data: pools, isLoading } = useQuery({
    queryKey: ["localPoolsDiscovery"],
    queryFn: async (): Promise<SubgraphPool[]> => {
      if (!contracts) return [];

      const hookAddr = contracts.BastionHook as `0x${string}`;
      const pmAddr = contracts.PoolManager as `0x${string}`;

      // Determine the fork block so we only scan local (post-fork) blocks.
      // Querying pre-fork blocks proxies to the upstream RPC which hangs.
      let fromBlock = 0n;
      try {
        const nodeInfo = await anvilClient.request({ method: "anvil_nodeInfo" as any }) as any;
        const forkBlock = nodeInfo?.forkConfig?.forkBlockNumber;
        if (forkBlock != null) fromBlock = BigInt(forkBlock);
      } catch {
        // Not an Anvil fork — fall back to recent blocks
        const currentBlock = await anvilClient.getBlockNumber();
        fromBlock = currentBlock > 500n ? currentBlock - 500n : 0n;
      }

      // 1. Discover pools from on-chain events
      const [issuerLogs, initLogs] = await Promise.all([
        anvilClient.getLogs({
          address: hookAddr,
          event: IssuerRegisteredEvent,
          fromBlock,
          toBlock: "latest",
        }),
        anvilClient.getLogs({
          address: pmAddr,
          event: InitializeEvent,
          fromBlock,
          toBlock: "latest",
        }),
      ]);

      // Build map of Initialize events filtered by hook address
      const initMap = new Map<string, { currency0: string; currency1: string }>();
      for (const log of initLogs) {
        if (log.args.hooks?.toLowerCase() === hookAddr.toLowerCase()) {
          initMap.set(log.args.id!.toLowerCase(), {
            currency0: log.args.currency0!,
            currency1: log.args.currency1!,
          });
        }
      }

      if (issuerLogs.length === 0) return [];

      // Build pool entries with token addresses
      const poolEntries = issuerLogs.map((log) => {
        const poolId = log.args.poolId! as `0x${string}`;
        const init = initMap.get(poolId.toLowerCase());
        return {
          poolId,
          issuer: log.args.issuer!,
          issuedToken: log.args.issuedToken!,
          token0: init?.currency0 ?? "0x0000000000000000000000000000000000000000",
          token1: init?.currency1 ?? log.args.issuedToken!,
        };
      });

      // 2. Batch read on-chain state for all pools (batch 1: pool info, insurance, reserves)
      const batch1Calls = poolEntries.flatMap((p) => {
        const slots = computePoolSlots(p.poolId);
        return [
          { address: hookAddr, abi: BastionHookABI, functionName: "getPoolInfo" as const, args: [p.poolId] },
          { address: contracts.InsurancePool as `0x${string}`, abi: InsurancePoolABI, functionName: "getPoolStatus" as const, args: [p.poolId] },
          { address: contracts.InsurancePool as `0x${string}`, abi: InsurancePoolABI, functionName: "feeRate" as const },
          { address: pmAddr, abi: PoolManagerABI, functionName: "extsload" as const, args: [slots.slot0] },
          { address: pmAddr, abi: PoolManagerABI, functionName: "extsload" as const, args: [slots.liquidity] },
        ];
      });

      const batch1Results = await anvilClient.multicall({
        contracts: batch1Calls as any,
        allowFailure: true,
      });

      // Parse batch1 and prepare batch2 calls (escrow + reputation)
      const batch2Calls: any[] = [];
      const poolInfos: Array<{ issuer: string; escrowId: bigint; issuedToken: string; totalLiquidity: bigint } | null> = [];

      for (let i = 0; i < poolEntries.length; i++) {
        const base = i * 5;
        const poolInfoResult = batch1Results[base];
        if (poolInfoResult.status === "success") {
          const [issuer, escrowId, issuedToken, totalLiquidity] = poolInfoResult.result as [string, bigint, string, bigint];
          poolInfos.push({ issuer, escrowId, issuedToken, totalLiquidity });
          batch2Calls.push(
            { address: contracts.EscrowVault as `0x${string}`, abi: EscrowVaultABI, functionName: "getEscrowStatus", args: [escrowId] },
            { address: contracts.ReputationEngine as `0x${string}`, abi: ReputationEngineABI, functionName: "getScore", args: [issuer] },
            { address: contracts.ReputationEngine as `0x${string}`, abi: ReputationEngineABI, functionName: "encodeScoreData", args: [issuer] },
            { address: contracts.EscrowVault as `0x${string}`, abi: EscrowVaultABI, functionName: "getEscrowInfo", args: [escrowId] },
          );
        } else {
          poolInfos.push(null);
        }
      }

      const batch2Results = batch2Calls.length > 0
        ? await anvilClient.multicall({ contracts: batch2Calls, allowFailure: true })
        : [];

      // 3. Assemble SubgraphPool objects
      const results: SubgraphPool[] = [];
      let batch2Idx = 0;

      for (let i = 0; i < poolEntries.length; i++) {
        const entry = poolEntries[i];
        const base = i * 5;
        const info = poolInfos[i];

        // Parse reserves from slot0 and liquidity
        const slot0Raw = batch1Results[base + 3]?.status === "success" ? (batch1Results[base + 3].result as `0x${string}`) : null;
        const liqRaw = batch1Results[base + 4]?.status === "success" ? (batch1Results[base + 4].result as `0x${string}`) : null;
        const sqrtPriceX96 = slot0Raw ? BigInt(slot0Raw) & ((1n << 160n) - 1n) : 0n;
        const liquidity = liqRaw ? BigInt(liqRaw) : 0n;
        const reserves = sqrtPriceX96 > 0n && liquidity > 0n
          ? computeReservesFromState(sqrtPriceX96, liquidity)
          : { reserve0: null, reserve1: null };

        // Insurance
        const insuranceStatus = batch1Results[base + 1]?.status === "success"
          ? (batch1Results[base + 1].result as { balance: bigint; isTriggered: boolean; triggerTimestamp: number; totalEligibleSupply: bigint })
          : null;
        const feeRate = batch1Results[base + 2]?.status === "success" ? Number(batch1Results[base + 2].result) : 100;

        // Escrow + reputation (from batch2)
        type EscrowStatus = { totalLiquidity: bigint; removedLiquidity: bigint; remainingLiquidity: bigint; nextUnlockTime: bigint };
        let escrowStatus: EscrowStatus | null = null;
        let repScore = 0;
        let poolsCreated = 0, escrowsCompleted = 0, triggerCount = 0;
        let escrowCreatedAt = 0, escrowLockDuration = 0, escrowVestingDuration = 0;
        let escrowCommitment: { maxSellPercent: number } | null = null;

        if (info) {
          escrowStatus = batch2Results[batch2Idx]?.status === "success"
            ? (batch2Results[batch2Idx].result as EscrowStatus)
            : null;
          repScore = batch2Results[batch2Idx + 1]?.status === "success" ? Number(batch2Results[batch2Idx + 1].result) : 0;

          const scoreData = batch2Results[batch2Idx + 2]?.status === "success" ? (batch2Results[batch2Idx + 2].result as `0x${string}`) : null;
          if (scoreData && scoreData.length >= 66) {
            try {
              const hex = scoreData.slice(2);
              poolsCreated = parseInt(hex.slice(64, 128), 16) || 0;
              escrowsCompleted = parseInt(hex.slice(128, 192), 16) || 0;
              triggerCount = parseInt(hex.slice(192, 256), 16) || 0;
            } catch { /* ignore */ }
          }

          const escrowInfo = batch2Results[batch2Idx + 3]?.status === "success"
            ? (batch2Results[batch2Idx + 3].result as [bigint, bigint, bigint, { maxSellPercent: number }])
            : null;
          if (escrowInfo) {
            escrowCreatedAt = Number(escrowInfo[0]);
            escrowLockDuration = Number(escrowInfo[1]);
            escrowVestingDuration = Number(escrowInfo[2]);
            escrowCommitment = escrowInfo[3];
          }

          batch2Idx += 4;
        }

        results.push({
          id: entry.poolId,
          token0: entry.token0,
          token1: entry.token1,
          hook: contracts.BastionHook,
          isBastion: true,
          issuedToken: entry.issuedToken,
          reserve0: reserves.reserve0,
          reserve1: reserves.reserve1,
          issuer: info
            ? {
                id: info.issuer,
                reputationScore: repScore.toString(),
                totalEscrowsCreated: poolsCreated,
                totalEscrowsCompleted: escrowsCompleted,
                totalTriggersActivated: triggerCount,
              }
            : null,
          escrow: escrowStatus
            ? {
                id: info!.escrowId.toString(),
                totalLiquidity: formatUnits(escrowStatus.totalLiquidity, 18),
                removedLiquidity: formatUnits(escrowStatus.removedLiquidity, 18),
                remainingLiquidity: formatUnits(escrowStatus.remainingLiquidity, 18),
                isTriggered: false,
                createdAt: escrowCreatedAt > 0 ? escrowCreatedAt.toString() : undefined,
                lockDuration: escrowLockDuration > 0 ? escrowLockDuration.toString() : undefined,
                vestingDuration: escrowVestingDuration > 0 ? escrowVestingDuration.toString() : undefined,
                commitment: escrowCommitment
                  ? {
                      maxSellPercent: escrowCommitment.maxSellPercent.toString(),
                    }
                  : undefined,
              }
            : null,
          insurancePool: insuranceStatus
            ? {
                id: entry.poolId,
                balance: formatUnits(insuranceStatus.balance, 18),
                feeRate: feeRate,
                isTriggered: insuranceStatus.isTriggered,
                triggerType: null,
                merkleRoot: null,
                useMerkleProof: false,
                totalClaimed: "0",
              }
            : null,
          createdAt: Math.floor(Date.now() / 1000).toString(),
          createdTx: "0x",
        });
      }

      return results;
    },
    enabled: !!contracts,
    refetchInterval: 10_000,
  });

  return { pools: pools ?? [], isLoading };
}

export function useBastionPools() {
  const chainId = useChainId();
  const local = useLocalPoolsOnChain();
  const isLocal = chainId === 31337;
  return useQuery({
    queryKey: ["bastionPools", chainId, local.pools.length, local.pools.map(p => p.escrow?.totalLiquidity).join()],
    queryFn: () =>
      isLocal && local.pools.length > 0
        ? Promise.resolve({ pools: local.pools })
        : graphClient.request<{ pools: SubgraphPool[] }>(BASTION_POOLS_QUERY),
    select: (data) => data.pools,
    enabled: isLocal ? !local.isLoading : true,
  });
}

export function useAllPools() {
  const chainId = useChainId();
  const local = useLocalPoolsOnChain();
  const isLocal = chainId === 31337;
  return useQuery({
    queryKey: ["allPools", chainId, local.pools.length, local.pools.map(p => p.escrow?.totalLiquidity).join()],
    queryFn: () =>
      isLocal && local.pools.length > 0
        ? Promise.resolve({ pools: local.pools })
        : graphClient.request<{ pools: SubgraphPool[] }>(ALL_POOLS_QUERY),
    select: (data) => data.pools,
    enabled: isLocal ? !local.isLoading : true,
  });
}

export function usePool(id: string) {
  const chainId = useChainId();
  const local = useLocalPoolsOnChain();
  const isLocal = chainId === 31337;
  const localPool = isLocal ? (local.pools.find(p => p.id.toLowerCase() === id.toLowerCase()) ?? null) : null;
  return useQuery({
    queryKey: ["pool", id, chainId, localPool?.escrow?.totalLiquidity],
    queryFn: () =>
      localPool
        ? Promise.resolve({ pool: localPool })
        : graphClient.request<{ pool: SubgraphPool | null }>(POOL_DETAIL_QUERY, { id }),
    select: (data) => data.pool,
    enabled: !!id && (isLocal ? !local.isLoading : true),
    refetchInterval: 15_000,
  });
}

const POOL_BY_TOKEN_QUERY = gql`
  query PoolByToken($token: String!) {
    pools(
      where: { token1: $token, isBastion: true }
      first: 1
    ) {
      id
    }
  }
`;

/**
 * Find an existing Bastion pool by issued token address.
 * Returns the pool ID if one exists.
 */
export function usePoolByToken(tokenAddress: string | undefined) {
  const chainId = useChainId();
  const local = useLocalPoolsOnChain();
  const isLocal = chainId === 31337;
  const token = tokenAddress?.toLowerCase();

  return useQuery({
    queryKey: ["poolByToken", token, chainId, local.pools.length],
    queryFn: () => {
      if (isLocal) {
        const match = local.pools.find(
          (p) => p.issuedToken?.toLowerCase() === token
        );
        return Promise.resolve({
          pools: match ? [{ id: match.id }] : [],
        });
      }
      return graphClient.request<{ pools: { id: string }[] }>(POOL_BY_TOKEN_QUERY, {
        token,
      });
    },
    select: (data) => data.pools[0]?.id ?? null,
    enabled: !!token && (isLocal ? !local.isLoading : true),
  });
}

const POOL_BY_TOKENS_QUERY = gql`
  query PoolByTokens($token0: String!, $token1: String!) {
    pools(
      where: { token0: $token0, token1: $token1 }
      first: 1
    ) {
      id
      reserve0
      reserve1
    }
  }
`;

/**
 * Fetch pool reserves for a token pair (sorted by address).
 * Returns reserve0 and reserve1 as raw strings from the subgraph.
 */
export function usePoolReserves(
  tokenA: string | undefined,
  tokenB: string | undefined
) {
  const chainId = useChainId();
  const local = useLocalPoolsOnChain();
  const isLocal = chainId === 31337;
  const [token0, token1] =
    tokenA && tokenB && tokenA.toLowerCase() < tokenB.toLowerCase()
      ? [tokenA.toLowerCase(), tokenB.toLowerCase()]
      : [tokenB?.toLowerCase(), tokenA?.toLowerCase()];

  return useQuery({
    queryKey: ["poolReserves", token0, token1, chainId, isLocal ? local.pools.length : 0, isLocal ? local.pools.map(p => `${p.reserve0}:${p.reserve1}`).join() : ""],
    queryFn: () => {
      if (isLocal && local.pools.length > 0) {
        const match = local.pools.find(
          (p) =>
            p.token0.toLowerCase() === token0 &&
            p.token1.toLowerCase() === token1
        );
        return Promise.resolve({
          pools: match
            ? [{ id: match.id, reserve0: match.reserve0, reserve1: match.reserve1 }]
            : [],
        });
      }
      return graphClient.request<{ pools: { id: string; reserve0: string | null; reserve1: string | null }[] }>(
        POOL_BY_TOKENS_QUERY,
        { token0, token1 }
      );
    },
    select: (data) => data.pools[0] ?? null,
    enabled: !!token0 && !!token1 && (isLocal ? !local.isLoading : true),
    staleTime: 15_000,
  });
}
