"use client";

import { useState } from "react";
import { useAccount } from "wagmi";
import { Card } from "@/components/ui/Card";
import { TokenIcon } from "@/components/ui/TokenIcon";
import { useTokenInfo } from "@/hooks/useTokenInfo";
import {
  useUserSwaps,
  useUserLiquidityEvents,
  useUserClaims,
  UserSwap,
  UserLiquidityEvent,
  UserClaim,
} from "@/hooks/useTransactionHistory";
import { shortenAddress, explorerUrl } from "@/lib/formatters";

type Tab = "swaps" | "liquidity" | "claims";

function timeAgo(ts: number): string {
  const diff = Math.floor(Date.now() / 1000) - ts;
  if (diff < 60) return "just now";
  if (diff < 3600) return `${Math.floor(diff / 60)}m ago`;
  if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`;
  return `${Math.floor(diff / 86400)}d ago`;
}

function formatRawAmount(raw: string, decimals: number): string {
  const val = Math.abs(Number(raw)) / 10 ** decimals;
  if (val === 0) return "0";
  if (val < 0.0001) return "<0.0001";
  return val.toLocaleString(undefined, { maximumFractionDigits: 4 });
}

// TokenPair component that resolves token names
function TokenPair({ token0, token1 }: { token0: string; token1: string }) {
  const t0 = useTokenInfo(token0 as `0x${string}`);
  const t1 = useTokenInfo(token1 as `0x${string}`);
  return (
    <div className="flex items-center gap-2">
      <div className="flex -space-x-1.5">
        <TokenIcon address={token0} size={20} />
        <TokenIcon address={token1} size={20} />
      </div>
      <span className="text-gray-700 font-medium">
        {t0.displayName}/{t1.displayName}
      </span>
    </div>
  );
}

function SwapRow({ swap }: { swap: UserSwap }) {
  const isBuy = BigInt(swap.amount1) < 0n;
  const t0 = useTokenInfo(swap.pool.token0 as `0x${string}`);
  const t1 = useTokenInfo(swap.pool.token1 as `0x${string}`);
  return (
    <tr className="border-b border-gray-50 last:border-0 hover:bg-gray-50/50">
      <td className="text-gray-500 px-4 py-3 text-xs">
        {timeAgo(parseInt(swap.timestamp))}
      </td>
      <td className="px-4 py-3">
        <TokenPair token0={swap.pool.token0} token1={swap.pool.token1} />
      </td>
      <td className="px-4 py-3">
        <span
          className={`text-xs font-medium ${
            isBuy ? "text-emerald-600" : "text-red-500"
          }`}
        >
          {isBuy ? "Buy" : "Sell"}
        </span>
      </td>
      <td className="text-right text-gray-700 px-4 py-3 text-xs tabular-nums">
        {formatRawAmount(swap.amount0, t0.decimals ?? 18)} {t0.symbol}
        {" / "}
        {formatRawAmount(swap.amount1, t1.decimals ?? 18)} {t1.symbol}
      </td>
      <td className="text-right px-4 py-3">
        <a
          href={explorerUrl(swap.transaction, "tx")}
          target="_blank"
          rel="noopener noreferrer"
          className="text-xs text-bastion-600 hover:text-bastion-700"
        >
          {shortenAddress(swap.transaction, 3)}
        </a>
      </td>
    </tr>
  );
}

function LiquidityRow({ event }: { event: UserLiquidityEvent }) {
  const isAdd = event.type === "ADD";
  const isCollect = event.type === "COLLECT";
  const t0 = useTokenInfo(event.pool.token0 as `0x${string}`);
  const t1 = useTokenInfo(event.pool.token1 as `0x${string}`);
  return (
    <tr className="border-b border-gray-50 last:border-0 hover:bg-gray-50/50">
      <td className="text-gray-500 px-4 py-3 text-xs">
        {timeAgo(parseInt(event.timestamp))}
      </td>
      <td className="px-4 py-3">
        <TokenPair token0={event.pool.token0} token1={event.pool.token1} />
      </td>
      <td className="px-4 py-3">
        <span
          className={`text-xs font-medium ${
            isAdd ? "text-emerald-600" : isCollect ? "text-blue-500" : "text-red-500"
          }`}
        >
          {isAdd ? "Add" : isCollect ? "Collect Fees" : "Remove"}
        </span>
      </td>
      <td className="text-right text-gray-700 px-4 py-3 text-xs tabular-nums">
        {formatRawAmount(event.amount0, t0.decimals ?? 18)} {t0.symbol}
        {" / "}
        {formatRawAmount(event.amount1, t1.decimals ?? 18)} {t1.symbol}
      </td>
      <td className="text-right px-4 py-3">
        <a
          href={explorerUrl(event.transaction, "tx")}
          target="_blank"
          rel="noopener noreferrer"
          className="text-xs text-bastion-600 hover:text-bastion-700"
        >
          {shortenAddress(event.transaction, 3)}
        </a>
      </td>
    </tr>
  );
}

function ClaimRow({ claim }: { claim: UserClaim }) {
  return (
    <tr className="border-b border-gray-50 last:border-0 hover:bg-gray-50/50">
      <td className="text-gray-500 px-4 py-3 text-xs">
        {timeAgo(parseInt(claim.claimedAt))}
      </td>
      <td className="px-4 py-3">
        <TokenPair token0={claim.pool.token0} token1={claim.pool.token1} />
      </td>
      <td className="text-right text-gray-700 px-4 py-3 text-xs tabular-nums">
        {parseFloat(claim.amount).toFixed(4)} ETH
      </td>
      <td className="text-right px-4 py-3">
        <a
          href={explorerUrl(claim.transactionHash, "tx")}
          target="_blank"
          rel="noopener noreferrer"
          className="text-xs text-bastion-600 hover:text-bastion-700"
        >
          {shortenAddress(claim.transactionHash, 3)}
        </a>
      </td>
    </tr>
  );
}

export default function HistoryPage() {
  const { address } = useAccount();
  const [tab, setTab] = useState<Tab>("swaps");

  const swaps = useUserSwaps(address);
  const liquidity = useUserLiquidityEvents(address);
  const claims = useUserClaims(address);

  if (!address) {
    return (
      <div className="max-w-4xl mx-auto py-20 text-center">
        <div className="mx-auto mb-5 flex h-16 w-16 items-center justify-center rounded-full bg-gray-50">
          <svg
            className="h-8 w-8 text-gray-300"
            fill="none"
            viewBox="0 0 24 24"
            stroke="currentColor"
            strokeWidth={1.5}
          >
            <path
              strokeLinecap="round"
              strokeLinejoin="round"
              d="M21 12a2.25 2.25 0 00-2.25-2.25H15a3 3 0 11-6 0H5.25A2.25 2.25 0 003 12m18 0v6a2.25 2.25 0 01-2.25 2.25H5.25A2.25 2.25 0 013 18v-6m18 0V9M3 12V9m18 0a2.25 2.25 0 00-2.25-2.25H5.25A2.25 2.25 0 003 9m18 0V6a2.25 2.25 0 00-2.25-2.25H5.25A2.25 2.25 0 003 6v3"
            />
          </svg>
        </div>
        <p className="text-lg font-semibold text-gray-600 mb-2">
          Connect wallet to view history
        </p>
        <p className="text-sm text-gray-400">
          Your swaps, liquidity events, and insurance claims will appear here.
        </p>
      </div>
    );
  }

  const tabs: { key: Tab; label: string }[] = [
    { key: "swaps", label: "Swaps" },
    { key: "liquidity", label: "Liquidity" },
    { key: "claims", label: "Claims" },
  ];

  const allSwaps = swaps.data?.pages.flatMap((p) => p.swaps) ?? [];
  const allLiquidity =
    liquidity.data?.pages.flatMap((p) => p.liquidityEvents) ?? [];
  const allClaims = claims.data?.pages.flatMap((p) => p.claims) ?? [];

  const isLoading =
    (tab === "swaps" && swaps.isLoading) ||
    (tab === "liquidity" && liquidity.isLoading) ||
    (tab === "claims" && claims.isLoading);

  const hasMore =
    (tab === "swaps" && swaps.hasNextPage) ||
    (tab === "liquidity" && liquidity.hasNextPage) ||
    (tab === "claims" && claims.hasNextPage);

  const loadMore = () => {
    if (tab === "swaps") swaps.fetchNextPage();
    if (tab === "liquidity") liquidity.fetchNextPage();
    if (tab === "claims") claims.fetchNextPage();
  };

  return (
    <div className="max-w-5xl mx-auto">
      <h1 className="text-2xl font-bold text-gray-900 mb-6">
        Transaction History
      </h1>

      <Card>
        {/* Tabs */}
        <div className="flex gap-1 mb-4 border-b border-gray-100 -mx-6 px-6">
          {tabs.map(({ key, label }) => (
            <button
              key={key}
              onClick={() => setTab(key)}
              className={`px-4 py-2.5 text-sm font-medium border-b-2 -mb-px transition-colors ${
                tab === key
                  ? "border-bastion-600 text-bastion-700"
                  : "border-transparent text-gray-400 hover:text-gray-600"
              }`}
            >
              {label}
            </button>
          ))}
        </div>

        {isLoading ? (
          <div className="flex items-center justify-center py-12">
            <div className="h-5 w-5 animate-spin rounded-full border-2 border-gray-200 border-t-bastion-500" />
          </div>
        ) : (
          <>
            {/* Swaps tab */}
            {tab === "swaps" &&
              (allSwaps.length === 0 ? (
                <p className="text-center text-sm text-gray-400 py-12">
                  No swaps yet
                </p>
              ) : (
                <div className="overflow-x-auto -mx-6">
                  <table className="w-full text-sm">
                    <thead>
                      <tr className="border-b border-gray-100">
                        <th className="text-left font-medium text-gray-400 text-xs px-4 py-2">
                          Time
                        </th>
                        <th className="text-left font-medium text-gray-400 text-xs px-4 py-2">
                          Pair
                        </th>
                        <th className="text-left font-medium text-gray-400 text-xs px-4 py-2">
                          Type
                        </th>
                        <th className="text-right font-medium text-gray-400 text-xs px-4 py-2">
                          Amount
                        </th>
                        <th className="text-right font-medium text-gray-400 text-xs px-4 py-2">
                          Tx
                        </th>
                      </tr>
                    </thead>
                    <tbody>
                      {allSwaps.map((s) => (
                        <SwapRow key={s.id} swap={s} />
                      ))}
                    </tbody>
                  </table>
                </div>
              ))}

            {/* Liquidity tab */}
            {tab === "liquidity" &&
              (allLiquidity.length === 0 ? (
                <p className="text-center text-sm text-gray-400 py-12">
                  No liquidity events yet
                </p>
              ) : (
                <div className="overflow-x-auto -mx-6">
                  <table className="w-full text-sm">
                    <thead>
                      <tr className="border-b border-gray-100">
                        <th className="text-left font-medium text-gray-400 text-xs px-4 py-2">
                          Time
                        </th>
                        <th className="text-left font-medium text-gray-400 text-xs px-4 py-2">
                          Pool
                        </th>
                        <th className="text-left font-medium text-gray-400 text-xs px-4 py-2">
                          Type
                        </th>
                        <th className="text-right font-medium text-gray-400 text-xs px-4 py-2">
                          Amounts
                        </th>
                        <th className="text-right font-medium text-gray-400 text-xs px-4 py-2">
                          Tx
                        </th>
                      </tr>
                    </thead>
                    <tbody>
                      {allLiquidity.map((e) => (
                        <LiquidityRow key={e.id} event={e} />
                      ))}
                    </tbody>
                  </table>
                </div>
              ))}

            {/* Claims tab */}
            {tab === "claims" &&
              (allClaims.length === 0 ? (
                <p className="text-center text-sm text-gray-400 py-12">
                  No claims yet
                </p>
              ) : (
                <div className="overflow-x-auto -mx-6">
                  <table className="w-full text-sm">
                    <thead>
                      <tr className="border-b border-gray-100">
                        <th className="text-left font-medium text-gray-400 text-xs px-4 py-2">
                          Time
                        </th>
                        <th className="text-left font-medium text-gray-400 text-xs px-4 py-2">
                          Pool
                        </th>
                        <th className="text-right font-medium text-gray-400 text-xs px-4 py-2">
                          Compensation
                        </th>
                        <th className="text-right font-medium text-gray-400 text-xs px-4 py-2">
                          Tx
                        </th>
                      </tr>
                    </thead>
                    <tbody>
                      {allClaims.map((c) => (
                        <ClaimRow key={c.id} claim={c} />
                      ))}
                    </tbody>
                  </table>
                </div>
              ))}

            {/* Load More */}
            {hasMore && (
              <div className="text-center pt-4">
                <button
                  onClick={loadMore}
                  className="btn-secondary text-sm px-6 py-2"
                >
                  Load More
                </button>
              </div>
            )}
          </>
        )}
      </Card>
    </div>
  );
}
