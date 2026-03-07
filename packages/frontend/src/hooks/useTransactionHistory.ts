"use client";

import { useInfiniteQuery } from "@tanstack/react-query";
import { gql } from "graphql-request";
import { graphClient } from "@/config/subgraph";

const PAGE_SIZE = 50;

// ── User Swaps ──
const USER_SWAPS_QUERY = gql`
  query UserSwaps($sender: Bytes!, $skip: Int!) {
    swaps(
      where: { sender: $sender }
      orderBy: timestamp
      orderDirection: desc
      first: ${PAGE_SIZE}
      skip: $skip
    ) {
      id
      pool {
        id
        token0
        token1
      }
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

export interface UserSwap {
  id: string;
  pool: { id: string; token0: string; token1: string };
  sender: string;
  amount0: string;
  amount1: string;
  sqrtPriceX96: string;
  tick: number;
  timestamp: string;
  transaction: string;
}

interface UserSwapsResponse {
  swaps: UserSwap[];
}

export function useUserSwaps(address: string | undefined) {
  return useInfiniteQuery({
    queryKey: ["userSwaps", address],
    queryFn: ({ pageParam = 0 }) =>
      graphClient.request<UserSwapsResponse>(USER_SWAPS_QUERY, {
        sender: address,
        skip: pageParam,
      }),
    initialPageParam: 0,
    getNextPageParam: (lastPage, allPages) =>
      lastPage.swaps.length === PAGE_SIZE
        ? allPages.length * PAGE_SIZE
        : undefined,
    enabled: !!address,
  });
}

// ── User Liquidity Events ──
const USER_LIQUIDITY_EVENTS_QUERY = gql`
  query UserLiquidityEvents($sender: Bytes!, $skip: Int!) {
    liquidityEvents(
      where: { sender: $sender }
      orderBy: timestamp
      orderDirection: desc
      first: ${PAGE_SIZE}
      skip: $skip
    ) {
      id
      pool {
        id
        token0
        token1
      }
      sender
      type
      amount0
      amount1
      liquidity
      tickLower
      tickUpper
      timestamp
      transaction
    }
  }
`;

export interface UserLiquidityEvent {
  id: string;
  pool: { id: string; token0: string; token1: string };
  sender: string;
  type: string;
  amount0: string;
  amount1: string;
  liquidity: string;
  tickLower: number;
  tickUpper: number;
  timestamp: string;
  transaction: string;
}

interface UserLiquidityEventsResponse {
  liquidityEvents: UserLiquidityEvent[];
}

export function useUserLiquidityEvents(address: string | undefined) {
  return useInfiniteQuery({
    queryKey: ["userLiquidityEvents", address],
    queryFn: ({ pageParam = 0 }) =>
      graphClient.request<UserLiquidityEventsResponse>(
        USER_LIQUIDITY_EVENTS_QUERY,
        { sender: address, skip: pageParam }
      ),
    initialPageParam: 0,
    getNextPageParam: (lastPage, allPages) =>
      lastPage.liquidityEvents.length === PAGE_SIZE
        ? allPages.length * PAGE_SIZE
        : undefined,
    enabled: !!address,
  });
}

// ── User Claims ──
const USER_CLAIMS_QUERY = gql`
  query UserClaims($holder: Bytes!, $skip: Int!) {
    claims(
      where: { holder: $holder }
      orderBy: claimedAt
      orderDirection: desc
      first: ${PAGE_SIZE}
      skip: $skip
    ) {
      id
      pool {
        id
        token0
        token1
      }
      holder
      amount
      tokenAmount
      claimedAt
      transactionHash
    }
  }
`;

export interface UserClaim {
  id: string;
  pool: { id: string; token0: string; token1: string };
  holder: string;
  amount: string;
  tokenAmount: string | null;
  claimedAt: string;
  transactionHash: string;
}

interface UserClaimsResponse {
  claims: UserClaim[];
}

export function useUserClaims(address: string | undefined) {
  return useInfiniteQuery({
    queryKey: ["userClaims", address],
    queryFn: ({ pageParam = 0 }) =>
      graphClient.request<UserClaimsResponse>(USER_CLAIMS_QUERY, {
        holder: address,
        skip: pageParam,
      }),
    initialPageParam: 0,
    getNextPageParam: (lastPage, allPages) =>
      lastPage.claims.length === PAGE_SIZE
        ? allPages.length * PAGE_SIZE
        : undefined,
    enabled: !!address,
  });
}
