"use client";

import { useRouter } from "next/navigation";
import { Card } from "@/components/ui/Card";
import { Badge } from "@/components/ui/Badge";
import { TokenIcon } from "@/components/ui/TokenIcon";
import { shortenAddress } from "@/lib/formatters";
import type { SubgraphPool } from "@/hooks/usePools";

interface PoolCardProps {
  pool: SubgraphPool;
}

export function PoolCard({ pool }: PoolCardProps) {
  const router = useRouter();
  const isTriggered = pool.escrow?.isTriggered;

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
                {shortenAddress(pool.token0, 3)} / {shortenAddress(pool.token1, 3)}
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
        <div className="mt-4 grid grid-cols-3 gap-3">
          {[
            {
              label: "Escrow Locked",
              value: pool.escrow ? `${parseFloat(pool.escrow.totalLocked).toFixed(4)}` : "—",
              sub: "ETH",
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
