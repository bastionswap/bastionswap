"use client";

import { useQuery } from "@tanstack/react-query";
import { gql } from "graphql-request";
import { graphClient } from "@/config/subgraph";

// ── All Positions for a User ──

const USER_ALL_POSITIONS_QUERY = gql`
  query UserAllPositions($owner: Bytes!) {
    positions(
      where: { owner: $owner, liquidity_gt: "0" }
      orderBy: lastUpdatedAt
      orderDirection: desc
      first: 100
    ) {
      id
      owner
      tickLower
      tickUpper
      liquidity
      isFullRange
      createdAt
      lastUpdatedAt
      pool {
        id
        token0
        token1
        fee
        tickSpacing
        hook
        isBastion
        issuedToken
        sqrtPriceX96
        reserve0
        reserve1
        issuer {
          id
        }
        escrow {
          isTriggered
        }
      }
    }
  }
`;

export interface PortfolioPosition {
  id: string;
  owner: string;
  tickLower: number;
  tickUpper: number;
  liquidity: string;
  isFullRange: boolean;
  createdAt: string;
  lastUpdatedAt: string;
  pool: {
    id: string;
    token0: string;
    token1: string;
    fee: number | null;
    tickSpacing: number | null;
    hook: string | null;
    isBastion: boolean;
    issuedToken: string | null;
    sqrtPriceX96: string | null;
    reserve0: string | null;
    reserve1: string | null;
    issuer: { id: string } | null;
    escrow: { isTriggered: boolean } | null;
  };
}

export function useUserAllPositions(address: string | undefined) {
  return useQuery({
    queryKey: ["userAllPositions", address],
    queryFn: () =>
      graphClient.request<{ positions: PortfolioPosition[] }>(
        USER_ALL_POSITIONS_QUERY,
        { owner: address!.toLowerCase() }
      ),
    select: (data) => data.positions,
    enabled: !!address,
    refetchInterval: 30_000,
  });
}

// ── Fee Collection History ──

const USER_COLLECTED_FEES_QUERY = gql`
  query UserCollectedFees($sender: Bytes!) {
    liquidityEvents(
      where: { sender: $sender, type: "COLLECT" }
      orderBy: timestamp
      orderDirection: desc
      first: 50
    ) {
      id
      pool {
        id
        token0
        token1
      }
      amount0
      amount1
      timestamp
      transaction
    }
  }
`;

export interface CollectedFee {
  id: string;
  pool: { id: string; token0: string; token1: string };
  amount0: string;
  amount1: string;
  timestamp: string;
  transaction: string;
}

export function useUserCollectedFees(address: string | undefined) {
  return useQuery({
    queryKey: ["userCollectedFees", address],
    queryFn: () =>
      graphClient.request<{ liquidityEvents: CollectedFee[] }>(
        USER_COLLECTED_FEES_QUERY,
        { sender: address!.toLowerCase() }
      ),
    select: (data) => data.liquidityEvents,
    enabled: !!address,
  });
}
