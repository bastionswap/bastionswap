"use client";

import { useRouter } from "next/navigation";
import { Card } from "@/components/ui/Card";
import { Badge } from "@/components/ui/Badge";
import { TokenIcon } from "@/components/ui/TokenIcon";
import { shortenAddress } from "@/lib/formatters";
import { useTokenInfo } from "@/hooks/useTokenInfo";
import type { SubgraphPool } from "@/hooks/usePools";

interface PoolCardProps {
  pool: SubgraphPool;
}

export function PoolCard({ pool }: PoolCardProps) {
  const router = useRouter();
  const isTriggered = pool.escrow?.isTriggered;

  const token0Info = useTokenInfo(pool.token0 as `0x${string}`);
  const token1Info = useTokenInfo(pool.token1 as `0x${string}`);
  const issuedInfo = useTokenInfo(pool.issuedToken as `0x${string}` | undefined);

  const token0Label = token0Info.displayName;
  const token1Label = token1Info.displayName;
  const issuedLabel = issuedInfo.symbol || (pool.issuedToken ? shortenAddress(pool.issuedToken, 3) : "tokens");

  const formatReserve = (val: string | null, tokenDecimals: number | null): string => {
    if (!val || parseFloat(val) === 0) return "0";
    let n = parseFloat(val);
    if (tokenDecimals) n = n / Math.pow(10, tokenDecimals);
    if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(2)}M`;
    if (n >= 1_000) return `${(n / 1_000).toFixed(2)}K`;
    if (n >= 1) return n.toFixed(2);
    return n.toFixed(4);
  };

  return (
    <Card
      onClick={() => router.push(`/pools/${pool.id}`)}
      glow={isTriggered ? "red" : pool.isBastion ? "emerald" : "none"}
    >
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-4">
          <div className="flex -space-x-3">
            <TokenIcon address={pool.token0} size={44} />
            <TokenIcon address={pool.token1} size={44} />
          </div>
          <div>
            <div className="flex items-center gap-2.5">
              <span className="text-base font-semibold text-gray-900">
                {token0Label} / {token1Label}
              </span>
              {pool.isBastion ? (
                <Badge variant="protected">Protected</Badge>
              ) : (
                <Badge variant="standard">Standard</Badge>
              )}
            </div>
            {pool.issuer && (
              <p className="mt-1 text-xs text-gray-400">
                Issuer: {shortenAddress(pool.issuer.id)}
                {pool.issuer.reputationScore && (
                  <span className="ml-2 text-gray-300">
                    Score: {pool.issuer.reputationScore}
                  </span>
                )}
              </p>
            )}
          </div>
        </div>
        <svg className="h-5 w-5 text-gray-300 shrink-0" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5}>
          <path strokeLinecap="round" strokeLinejoin="round" d="M8.25 4.5l7.5 7.5-7.5 7.5" />
        </svg>
      </div>

      {pool.isBastion && (
        <div className="mt-5 grid grid-cols-2 gap-3 sm:grid-cols-4">
          {[
            {
              label: "Reserves",
              value: pool.reserve0 || pool.reserve1
                ? `${formatReserve(pool.reserve0, token0Info.decimals)} / ${formatReserve(pool.reserve1, token1Info.decimals)}`
                : "—",
              sub: pool.reserve0 || pool.reserve1
                ? `${token0Info.symbol || "T0"} / ${token1Info.symbol || "T1"}`
                : "",
            },
            {
              label: "LP Escrowed",
              value: pool.escrow ? `${parseFloat(pool.escrow.totalLiquidity).toFixed(2)}` : "—",
              sub: pool.escrow ? `LP · ${(parseFloat(pool.escrow.removedLiquidity) / parseFloat(pool.escrow.totalLiquidity) * 100 || 0).toFixed(0)}% removed` : "LP",
            },
            {
              label: "Insurance",
              value: pool.insurancePool ? `${parseFloat(pool.insurancePool.balance).toFixed(4)}` : "—",
              sub: "ETH",
            },
            {
              label: "Reputation",
              value: pool.issuer?.reputationScore ?? "—",
              sub: "/ 1000",
            },
          ].map(({ label, value, sub }) => (
            <div key={label} className="rounded-xl bg-gray-50 px-3 py-3">
              <p className="text-[11px] text-gray-400 mb-1">{label}</p>
              <p className="text-sm font-semibold text-gray-900 tabular-nums">
                {value}
                {sub && <span className="text-[10px] text-gray-400 font-normal ml-1">{sub}</span>}
              </p>
            </div>
          ))}
        </div>
      )}

      {isTriggered && (
        <div className="mt-4 flex items-center gap-2 rounded-xl bg-red-50 border border-red-200 px-4 py-2.5 text-xs text-red-600 font-medium">
          <svg className="h-4 w-4 shrink-0" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
            <path strokeLinecap="round" strokeLinejoin="round" d="M12 9v3.75m-9.303 3.376c-.866 1.5.217 3.374 1.948 3.374h14.71c1.73 0 2.813-1.874 1.948-3.374L13.949 3.378c-.866-1.5-3.032-1.5-3.898 0L2.697 16.126zM12 15.75h.007v.008H12v-.008z" />
          </svg>
          Trigger activated — remaining LP redistributed to holders
        </div>
      )}
    </Card>
  );
}
