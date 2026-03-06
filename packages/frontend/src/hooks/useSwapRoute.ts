"use client";

import { useMemo } from "react";
import { useAllPools, SubgraphPool } from "@/hooks/usePools";
import { useChainId } from "wagmi";
import { getContracts } from "@/config/contracts";

export interface SwapStep {
  poolKey: {
    currency0: `0x${string}`;
    currency1: `0x${string}`;
    fee: number;
    tickSpacing: number;
    hooks: `0x${string}`;
  };
  zeroForOne: boolean;
}

export interface SwapRoute {
  type: "direct" | "multi-hop";
  steps: SwapStep[];
  path: string[];       // token addresses in order
  pathSymbols: string[];// token symbols for display
  numHops: number;
}

const ZERO_ADDR = "0x0000000000000000000000000000000000000000";

// Known base tokens that can serve as intermediaries
const BASE_TOKEN_SYMBOLS: Record<string, string> = {};

function normalizeAddr(addr: string): string {
  return addr.toLowerCase();
}

function buildAdjacencyGraph(
  pools: SubgraphPool[],
  hookAddr: string
): Map<string, Map<string, { pool: SubgraphPool; currency0: string; currency1: string }>> {
  const graph = new Map<string, Map<string, { pool: SubgraphPool; currency0: string; currency1: string }>>();

  for (const pool of pools) {
    const t0 = normalizeAddr(pool.token0);
    const t1 = normalizeAddr(pool.token1);

    if (!graph.has(t0)) graph.set(t0, new Map());
    if (!graph.has(t1)) graph.set(t1, new Map());

    const entry = { pool, currency0: pool.token0, currency1: pool.token1 };
    graph.get(t0)!.set(t1, entry);
    graph.get(t1)!.set(t0, entry);
  }

  return graph;
}

function buildStep(
  entry: { pool: SubgraphPool; currency0: string; currency1: string },
  tokenIn: string,
  hookAddr: string
): SwapStep {
  const inIsC0 = normalizeAddr(tokenIn) === normalizeAddr(entry.currency0);
  return {
    poolKey: {
      currency0: entry.currency0 as `0x${string}`,
      currency1: entry.currency1 as `0x${string}`,
      fee: 3000,
      tickSpacing: 60,
      hooks: hookAddr as `0x${string}`,
    },
    zeroForOne: inIsC0,
  };
}

function getSymbol(addr: string, pools: SubgraphPool[]): string {
  const normalized = normalizeAddr(addr);
  if (normalized === normalizeAddr(ZERO_ADDR)) return "ETH";

  // Try to find the symbol from pool issuedToken matches
  for (const pool of pools) {
    if (normalizeAddr(pool.token0) === normalized || normalizeAddr(pool.token1) === normalized) {
      if (pool.issuedToken && normalizeAddr(pool.issuedToken) === normalized) {
        // This is the issued token — derive name from pool
        // Since we don't store symbol in SubgraphPool, use address prefix
      }
    }
  }

  // Fallback: use shortened address
  return addr.slice(0, 6) + "..." + addr.slice(-4);
}

export function useSwapRoute(
  tokenIn: string | undefined,
  tokenOut: string | undefined,
  tokenInSymbol?: string,
  tokenOutSymbol?: string
): SwapRoute | null {
  const chainId = useChainId();
  const contracts = getContracts(chainId);
  const { data: pools } = useAllPools();

  return useMemo(() => {
    if (!tokenIn || !tokenOut || !contracts || !pools || pools.length === 0) return null;

    const hookAddr = contracts.BastionHook;
    const graph = buildAdjacencyGraph(pools, hookAddr);

    const inAddr = normalizeAddr(tokenIn);
    const outAddr = normalizeAddr(tokenOut);

    if (inAddr === outAddr) return null;

    // 1. Check for direct pool
    const directEdge = graph.get(inAddr)?.get(outAddr);
    if (directEdge) {
      const step = buildStep(directEdge, tokenIn, hookAddr);
      return {
        type: "direct",
        steps: [step],
        path: [tokenIn, tokenOut],
        pathSymbols: [tokenInSymbol || "?", tokenOutSymbol || "?"],
        numHops: 1,
      };
    }

    // 2. Try 2-hop route via each known intermediary
    // Collect all unique tokens as potential intermediaries
    const intermediaries = new Set<string>();
    for (const [token] of graph) {
      intermediaries.add(token);
    }

    for (const mid of intermediaries) {
      if (mid === inAddr || mid === outAddr) continue;

      const edge1 = graph.get(inAddr)?.get(mid);
      const edge2 = graph.get(mid)?.get(outAddr);

      if (edge1 && edge2) {
        const step1 = buildStep(edge1, tokenIn, hookAddr);
        // For step 2, the input is the intermediary token
        const midAddr = mid === normalizeAddr(edge2.currency0) ? edge2.currency0 : edge2.currency1;
        const step2 = buildStep(edge2, midAddr, hookAddr);

        const midSymbol = normalizeAddr(mid) === normalizeAddr(ZERO_ADDR)
          ? "ETH"
          : getSymbol(mid, pools);

        return {
          type: "multi-hop",
          steps: [step1, step2],
          path: [tokenIn, midAddr, tokenOut],
          pathSymbols: [tokenInSymbol || "?", midSymbol, tokenOutSymbol || "?"],
          numHops: 2,
        };
      }
    }

    return null;
  }, [tokenIn, tokenOut, tokenInSymbol, tokenOutSymbol, contracts, pools]);
}
