"use client";

import { Card, CardHeader } from "@/components/ui/Card";
import { useRecentTrades, SubgraphSwap } from "@/hooks/useRecentTrades";
import { useTokenInfo } from "@/hooks/useTokenInfo";
import { shortenAddress, explorerUrl } from "@/lib/formatters";

function timeAgo(ts: number): string {
  const diff = Math.floor(Date.now() / 1000) - ts;
  if (diff < 60) return "just now";
  if (diff < 3600) return `${Math.floor(diff / 60)}m ago`;
  if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`;
  return `${Math.floor(diff / 86400)}d ago`;
}

function formatAmount(raw: string, decimals: number | null): string {
  const val = Math.abs(Number(raw)) / 10 ** (decimals ?? 18);
  if (val === 0) return "0";
  if (val < 0.0001) return "<0.0001";
  return val.toLocaleString(undefined, { maximumFractionDigits: 4 });
}

interface RecentTradesProps {
  poolId: string;
  token0: string;
  token1: string;
  issuedToken?: string;
}

export function RecentTrades({
  poolId,
  token0,
  token1,
  issuedToken,
}: RecentTradesProps) {
  const { data: trades, isLoading } = useRecentTrades(poolId);
  const token0Info = useTokenInfo(token0 as `0x${string}`);
  const token1Info = useTokenInfo(token1 as `0x${string}`);

  // Buy = user receives token1 (amount1 < 0 means token1 goes to user)
  // If issuedToken == token1, negative amount1 = Buy
  // If issuedToken == token0, negative amount0 = Buy
  const isToken1Issued =
    issuedToken?.toLowerCase() === token1.toLowerCase();

  function getTradeType(swap: SubgraphSwap): "Buy" | "Sell" {
    if (isToken1Issued) {
      return BigInt(swap.amount1) < 0n ? "Buy" : "Sell";
    }
    return BigInt(swap.amount0) < 0n ? "Buy" : "Sell";
  }

  return (
    <Card>
      <CardHeader>
        <h3 className="text-sm font-semibold text-gray-900">Recent Trades</h3>
      </CardHeader>

      {isLoading ? (
        <div className="flex items-center justify-center py-8">
          <div className="h-5 w-5 animate-spin rounded-full border-2 border-gray-200 border-t-bastion-500" />
        </div>
      ) : !trades || trades.length === 0 ? (
        <p className="text-center text-sm text-gray-400 py-8">No trades yet</p>
      ) : (
        <div className="overflow-x-auto -mx-6">
          <table className="w-full text-xs">
            <thead>
              <tr className="border-b border-gray-100">
                <th className="text-left font-medium text-gray-400 px-6 py-2">
                  Time
                </th>
                <th className="text-left font-medium text-gray-400 px-3 py-2">
                  Type
                </th>
                <th className="text-right font-medium text-gray-400 px-3 py-2">
                  {token0Info.symbol || "Token0"}
                </th>
                <th className="text-right font-medium text-gray-400 px-3 py-2">
                  {token1Info.symbol || "Token1"}
                </th>
                <th className="text-right font-medium text-gray-400 px-6 py-2">
                  Tx
                </th>
              </tr>
            </thead>
            <tbody>
              {trades.map((swap) => {
                const type = getTradeType(swap);
                const isBuy = type === "Buy";
                return (
                  <tr
                    key={swap.id}
                    className="border-b border-gray-50 last:border-0"
                  >
                    <td className="text-gray-500 px-6 py-2.5">
                      {timeAgo(parseInt(swap.timestamp))}
                    </td>
                    <td className="px-3 py-2.5">
                      <span
                        className={`font-medium ${
                          isBuy ? "text-emerald-600" : "text-red-500"
                        }`}
                      >
                        {type}
                      </span>
                    </td>
                    <td className="text-right text-gray-700 px-3 py-2.5 tabular-nums">
                      {formatAmount(swap.amount0, token0Info.decimals)}
                    </td>
                    <td className="text-right text-gray-700 px-3 py-2.5 tabular-nums">
                      {formatAmount(swap.amount1, token1Info.decimals)}
                    </td>
                    <td className="text-right px-6 py-2.5">
                      <a
                        href={explorerUrl(swap.transaction, "tx")}
                        target="_blank"
                        rel="noopener noreferrer"
                        className="text-bastion-600 hover:text-bastion-700 transition-colors"
                      >
                        {shortenAddress(swap.transaction, 3)}
                      </a>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
    </Card>
  );
}
