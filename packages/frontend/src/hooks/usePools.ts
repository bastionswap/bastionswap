import { useQuery } from "@tanstack/react-query";
import { gql } from "graphql-request";
import { graphClient } from "@/config/subgraph";

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

export function useBastionPools() {
  return useQuery({
    queryKey: ["bastionPools"],
    queryFn: () =>
      graphClient.request<{ pools: SubgraphPool[] }>(BASTION_POOLS_QUERY),
    select: (data) => data.pools,
  });
}

export function useAllPools() {
  return useQuery({
    queryKey: ["allPools"],
    queryFn: () =>
      graphClient.request<{ pools: SubgraphPool[] }>(ALL_POOLS_QUERY),
    select: (data) => data.pools,
  });
}

export function usePool(id: string) {
  return useQuery({
    queryKey: ["pool", id],
    queryFn: () =>
      graphClient.request<{ pool: SubgraphPool | null }>(POOL_DETAIL_QUERY, {
        id,
      }),
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
  const [token0, token1] =
    tokenA && tokenB && tokenA.toLowerCase() < tokenB.toLowerCase()
      ? [tokenA.toLowerCase(), tokenB.toLowerCase()]
      : [tokenB?.toLowerCase(), tokenA?.toLowerCase()];

  return useQuery({
    queryKey: ["poolReserves", token0, token1],
    queryFn: () =>
      graphClient.request<{ pools: { id: string; reserve0: string | null; reserve1: string | null }[] }>(
        POOL_BY_TOKENS_QUERY,
        { token0, token1 }
      ),
    select: (data) => data.pools[0] ?? null,
    enabled: !!token0 && !!token1,
    staleTime: 15_000,
  });
}
