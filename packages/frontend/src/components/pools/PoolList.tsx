"use client";

import { LoadingSpinner } from "@/components/ui/LoadingSpinner";
import { PoolCard } from "./PoolCard";
import type { SubgraphPool } from "@/hooks/usePools";

interface PoolListProps {
  pools: SubgraphPool[] | undefined;
  isLoading: boolean;
  error: Error | null;
}

export function PoolList({ pools, isLoading, error }: PoolListProps) {
  if (isLoading) {
    return (
      <div className="flex justify-center py-20">
        <LoadingSpinner size="lg" />
      </div>
    );
  }

  if (error) {
    return (
      <div className="rounded-2xl border border-gray-800 bg-gray-900 p-8 text-center">
        <p className="text-gray-400">
          Unable to load pools. The subgraph may not be deployed yet.
        </p>
        <p className="mt-2 text-xs text-gray-600">{error.message}</p>
      </div>
    );
  }

  if (!pools || pools.length === 0) {
    return (
      <div className="rounded-2xl border border-gray-800 bg-gray-900 p-8 text-center">
        <p className="text-gray-400">No pools found</p>
        <p className="mt-1 text-sm text-gray-600">
          Be the first to create a Bastion Protected pool!
        </p>
      </div>
    );
  }

  return (
    <div className="grid gap-4 md:grid-cols-2">
      {pools.map((pool) => (
        <PoolCard key={pool.id} pool={pool} />
      ))}
    </div>
  );
}
