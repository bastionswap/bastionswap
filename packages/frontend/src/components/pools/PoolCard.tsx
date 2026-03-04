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

  return (
    <Card
      onClick={() => router.push(`/pools/${pool.id}`)}
      className="hover:border-bastion-500/30"
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
                {shortenAddress(pool.token0, 3)} /{" "}
                {shortenAddress(pool.token1, 3)}
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
        <div className="mt-4 grid grid-cols-3 gap-4">
          <div>
            <p className="text-xs text-gray-500">Escrow Locked</p>
            <p className="font-medium text-sm">
              {pool.escrow
                ? `${parseFloat(pool.escrow.totalLocked).toFixed(4)} ETH`
                : "—"}
            </p>
          </div>
          <div>
            <p className="text-xs text-gray-500">Insurance</p>
            <p className="font-medium text-sm">
              {pool.insurancePool
                ? `${parseFloat(pool.insurancePool.balance).toFixed(4)} ETH`
                : "—"}
            </p>
          </div>
          <div>
            <p className="text-xs text-gray-500">Reputation</p>
            <p className="font-medium text-sm">
              {pool.issuer ? `${pool.issuer.reputationScore}` : "—"}
            </p>
          </div>
        </div>
      )}

      {pool.escrow?.isTriggered && (
        <div className="mt-3 rounded-lg bg-red-500/10 px-3 py-2 text-xs text-red-400">
          Trigger activated — compensation available
        </div>
      )}
    </Card>
  );
}
