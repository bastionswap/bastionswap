import { useQuery } from "@tanstack/react-query";
import { useChainId, useReadContracts } from "wagmi";
import { formatUnits, keccak256, encodeAbiParameters } from "viem";
import { gql } from "graphql-request";
import { graphClient } from "@/config/subgraph";
import { LOCAL_POOL, LOCAL_CONTRACTS } from "@/config/contracts.generated";
import { getContracts } from "@/config/contracts";
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
        totalLocked
        released
        remaining
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
        totalLocked
        released
        remaining
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
        totalLocked
        released
        remaining
        isTriggered
        createdAt
        commitment {
          dailyWithdrawLimit
          lockDuration
          maxSellPercent
        }
        vestingSchedule {
          id
          timestamp
          basisPoints
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
    totalLocked: string;
    released: string;
    remaining: string;
    isTriggered: boolean;
    createdAt?: string;
    commitment?: {
      dailyWithdrawLimit: string;
      lockDuration: string;
      maxSellPercent: string;
    } | null;
    vestingSchedule?: {
      id: string;
      timestamp: string;
      basisPoints: number;
    }[];
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

// ─── Local on-chain pool data hook ──────────────────────────────────

function useLocalPoolOnChain() {
  const contracts = getContracts(31337);
  const poolId = LOCAL_POOL.id as `0x${string}`;
  const poolSlots = computePoolSlots(poolId);

  const { data, isLoading } = useReadContracts({
    contracts: contracts
      ? [
          // 0: BastionHook.getPoolInfo(poolId)
          {
            address: contracts.BastionHook as `0x${string}`,
            abi: BastionHookABI,
            functionName: "getPoolInfo",
            args: [poolId],
          },
          // 1: InsurancePool.getPoolStatus(poolId)
          {
            address: contracts.InsurancePool as `0x${string}`,
            abi: InsurancePoolABI,
            functionName: "getPoolStatus",
            args: [poolId],
          },
          // 2: InsurancePool.feeRate()
          {
            address: contracts.InsurancePool as `0x${string}`,
            abi: InsurancePoolABI,
            functionName: "feeRate",
          },
          // 3: PoolManager.extsload(slot0) — sqrtPriceX96
          {
            address: contracts.PoolManager as `0x${string}`,
            abi: PoolManagerABI,
            functionName: "extsload",
            args: [poolSlots.slot0],
          },
          // 4: PoolManager.extsload(liquidity slot)
          {
            address: contracts.PoolManager as `0x${string}`,
            abi: PoolManagerABI,
            functionName: "extsload",
            args: [poolSlots.liquidity],
          },
        ]
      : undefined,
    query: { enabled: !!contracts },
  });

  // Extract escrowId from getPoolInfo result, then read escrow + reputation
  const poolInfo = data?.[0]?.status === "success" ? (data[0].result as [string, bigint, string, bigint]) : null;
  const escrowId = poolInfo?.[1];
  const issuerAddr = poolInfo?.[0];

  const { data: data2 } = useReadContracts({
    contracts:
      contracts && escrowId !== undefined && issuerAddr
        ? [
            // 0: EscrowVault.getEscrowStatus(escrowId)
            {
              address: contracts.EscrowVault as `0x${string}`,
              abi: EscrowVaultABI,
              functionName: "getEscrowStatus",
              args: [escrowId],
            },
            // 1: ReputationEngine.getScore(issuer)
            {
              address: contracts.ReputationEngine as `0x${string}`,
              abi: ReputationEngineABI,
              functionName: "getScore",
              args: [issuerAddr],
            },
            // 2: ReputationEngine.encodeScoreData(issuer)
            {
              address: contracts.ReputationEngine as `0x${string}`,
              abi: ReputationEngineABI,
              functionName: "encodeScoreData",
              args: [issuerAddr],
            },
          ]
        : undefined,
    query: { enabled: !!contracts && escrowId !== undefined && !!issuerAddr },
  });

  const insuranceStatus = data?.[1]?.status === "success"
    ? (data[1].result as { balance: bigint; isTriggered: boolean; triggerTimestamp: number; totalEligibleSupply: bigint })
    : null;

  const feeRate = data?.[2]?.status === "success" ? Number(data[2].result) : 100;

  // Decode sqrtPriceX96 from slot0 (lower 160 bits) and liquidity
  const slot0Raw = data?.[3]?.status === "success" ? (data[3].result as `0x${string}`) : null;
  const liqRaw = data?.[4]?.status === "success" ? (data[4].result as `0x${string}`) : null;

  const sqrtPriceX96 = slot0Raw ? BigInt(slot0Raw) & ((1n << 160n) - 1n) : 0n;
  const liquidity = liqRaw ? BigInt(liqRaw) : 0n;
  const reserves = sqrtPriceX96 > 0n && liquidity > 0n
    ? computeReservesFromState(sqrtPriceX96, liquidity)
    : { reserve0: null, reserve1: null };

  const escrowStatus = data2?.[0]?.status === "success"
    ? (data2[0].result as { totalLocked: bigint; released: bigint; remaining: bigint; nextUnlockTime: bigint })
    : null;

  const repScore = data2?.[1]?.status === "success" ? Number(data2[1].result) : 0;

  // Decode score data for profile stats
  const scoreData = data2?.[2]?.status === "success" ? (data2[2].result as `0x${string}`) : null;
  let poolsCreated = 0, escrowsCompleted = 0, triggerCount = 0, uniqueTokens = 0;
  if (scoreData && scoreData.length >= 66) {
    // encodeScoreData returns abi.encode(score, poolsCreated, escrowsCompleted, triggerCount, uniqueTokens)
    try {
      // Manual decode: each uint256 is 32 bytes. Skip first 32 bytes (score), then read uint16s packed as uint256
      const hex = scoreData.slice(2); // remove 0x
      poolsCreated = parseInt(hex.slice(64, 128), 16) || 0;
      escrowsCompleted = parseInt(hex.slice(128, 192), 16) || 0;
      triggerCount = parseInt(hex.slice(192, 256), 16) || 0;
      uniqueTokens = parseInt(hex.slice(256, 320), 16) || 0;
    } catch { /* ignore */ }
  }

  const pool: SubgraphPool | null =
    isLoading || !contracts
      ? null
      : {
          id: LOCAL_POOL.id,
          token0: LOCAL_POOL.token0,
          token1: LOCAL_POOL.token1,
          hook: LOCAL_POOL.hook,
          isBastion: true,
          issuedToken: LOCAL_POOL.issuedToken,
          reserve0: reserves.reserve0,
          reserve1: reserves.reserve1,
          issuer: issuerAddr
            ? {
                id: issuerAddr,
                reputationScore: repScore.toString(),
                totalEscrowsCreated: poolsCreated,
                totalEscrowsCompleted: escrowsCompleted,
                totalTriggersActivated: triggerCount,
              }
            : null,
          escrow: escrowStatus
            ? {
                id: escrowId!.toString(),
                totalLocked: formatUnits(escrowStatus.totalLocked, 18),
                released: formatUnits(escrowStatus.released, 18),
                remaining: formatUnits(escrowStatus.remaining, 18),
                isTriggered: false,
              }
            : null,
          insurancePool: insuranceStatus
            ? {
                id: LOCAL_POOL.id,
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
        };

  return { pool, isLoading };
}

export function useBastionPools() {
  const chainId = useChainId();
  const local = useLocalPoolOnChain();
  return useQuery({
    queryKey: ["bastionPools", chainId, local.pool?.escrow?.totalLocked],
    queryFn: () =>
      chainId === 31337
        ? Promise.resolve({ pools: local.pool ? [local.pool] : [] })
        : graphClient.request<{ pools: SubgraphPool[] }>(BASTION_POOLS_QUERY),
    select: (data) => data.pools,
  });
}

export function useAllPools() {
  const chainId = useChainId();
  const local = useLocalPoolOnChain();
  return useQuery({
    queryKey: ["allPools", chainId, local.pool?.escrow?.totalLocked],
    queryFn: () =>
      chainId === 31337
        ? Promise.resolve({ pools: local.pool ? [local.pool] : [] })
        : graphClient.request<{ pools: SubgraphPool[] }>(ALL_POOLS_QUERY),
    select: (data) => data.pools,
  });
}

export function usePool(id: string) {
  const chainId = useChainId();
  const local = useLocalPoolOnChain();
  return useQuery({
    queryKey: ["pool", id, chainId, local.pool?.escrow?.totalLocked],
    queryFn: () =>
      chainId === 31337
        ? Promise.resolve({ pool: id === LOCAL_POOL.id ? local.pool : null })
        : graphClient.request<{ pool: SubgraphPool | null }>(POOL_DETAIL_QUERY, { id }),
    select: (data) => data.pool,
    enabled: !!id,
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
  const local = useLocalPoolOnChain();
  const [token0, token1] =
    tokenA && tokenB && tokenA.toLowerCase() < tokenB.toLowerCase()
      ? [tokenA.toLowerCase(), tokenB.toLowerCase()]
      : [tokenB?.toLowerCase(), tokenA?.toLowerCase()];

  return useQuery({
    queryKey: ["poolReserves", token0, token1, chainId, local.pool?.reserve0, local.pool?.reserve1],
    queryFn: () =>
      chainId === 31337
        ? Promise.resolve({
            pools:
              token0 === LOCAL_POOL.token0.toLowerCase() &&
              token1 === LOCAL_POOL.token1.toLowerCase() &&
              local.pool
                ? [{ id: LOCAL_POOL.id, reserve0: local.pool.reserve0, reserve1: local.pool.reserve1 }]
                : [],
          })
        : graphClient.request<{ pools: { id: string; reserve0: string | null; reserve1: string | null }[] }>(
            POOL_BY_TOKENS_QUERY,
            { token0, token1 }
          ),
    select: (data) => data.pools[0] ?? null,
    enabled: !!token0 && !!token1,
    staleTime: 15_000,
  });
}
