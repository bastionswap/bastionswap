"use client";

import { useQuery } from "@tanstack/react-query";
import { gql } from "graphql-request";
import { graphClient } from "@/config/subgraph";

const RECENT_SWAPS_QUERY = gql`
  query RecentSwaps($poolId: String!) {
    swaps(
      where: { pool: $poolId }
      orderBy: timestamp
      orderDirection: desc
      first: 20
    ) {
      id
      sender
      amount0
      amount1
      sqrtPriceX96
      tick
      timestamp
      transaction
    }
  }
`;

export interface SubgraphSwap {
  id: string;
  sender: string;
  amount0: string;
  amount1: string;
  sqrtPriceX96: string;
  tick: number;
  timestamp: string;
  transaction: string;
}

interface RecentSwapsResponse {
  swaps: SubgraphSwap[];
}

export function useRecentTrades(poolId: string | undefined) {
  return useQuery({
    queryKey: ["recentTrades", poolId],
    queryFn: () =>
      graphClient.request<RecentSwapsResponse>(RECENT_SWAPS_QUERY, {
        poolId,
      }),
    enabled: !!poolId,
    refetchInterval: 30_000,
    select: (data) => data.swaps,
  });
}
