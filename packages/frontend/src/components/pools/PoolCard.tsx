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
    // Subgraph stores raw amounts; divide by 10^decimals for human-readable
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
      <div className="flex items-start justify-between">
        <div className="flex items-center gap-3">
          <div className="flex -space-x-2">
            <TokenIcon address={pool.token0} size={36} />
            <TokenIcon address={pool.token1} size={36} />
          </div>
          <div>
            <div className="flex items-center gap-2">
              <span className="font-medium">
                {token0Label} / {token1Label}
              </span>
              {pool.isBastion ? (
                <Badge variant="protected">Protected</Badge>
              ) : (
                <Badge variant="standard">Standard</Badge>
              )}
            </div>
            {pool.issuer && (
              <p className="mt-0.5 text-xs text-gray-500">
                Issuer: {shortenAddress(pool.issuer.id)}
              </p>
            )}
          </div>
        </div>
      </div>

      {pool.isBastion && (
        <div className="mt-4 grid grid-cols-4 gap-3">
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
              label: "Escrow Locked",
              value: pool.escrow ? `${parseFloat(pool.escrow.totalLocked).toFixed(2)}` : "—",
              sub: issuedLabel,
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
            <div key={label} className="rounded-lg bg-surface-light p-2.5">
              <p className="text-[10px] text-gray-500">{label}</p>
              <p className="text-sm font-semibold">
                {value} <span className="text-[10px] text-gray-600 font-normal">{sub}</span>
              </p>
            </div>
          ))}
        </div>
      )}

      {isTriggered && (
        <div className="mt-3 flex items-center gap-2 rounded-lg bg-red-500/10 border border-red-500/20 px-3 py-2 text-xs text-red-400">
          <span>&#128680;</span>
          Trigger activated — compensation available
        </div>
      )}
    </Card>
  );
}
