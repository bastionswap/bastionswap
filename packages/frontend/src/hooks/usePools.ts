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
