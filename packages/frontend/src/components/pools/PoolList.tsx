"use client";

import Link from "next/link";
import { SkeletonCard } from "@/components/ui/LoadingSpinner";
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
      <div className="grid gap-4 md:grid-cols-2">
        {Array.from({ length: 4 }).map((_, i) => (
          <SkeletonCard key={i} />
        ))}
      </div>
    );
  }

  if (error) {
    return (
      <div className="glass-card p-10 text-center">
        <p className="text-base text-gray-400 mb-2">Something went wrong</p>
        <p className="text-sm text-gray-600 mb-4">
          Unable to load pools. The subgraph may not be deployed yet.
        </p>
        <button
          onClick={() => window.location.reload()}
          className="btn-secondary text-sm px-4 py-2"
        >
          Try Again
        </button>
      </div>
    );
  }

  if (!pools || pools.length === 0) {
    return (
      <div className="glass-card p-10 text-center">
        <div className="mx-auto mb-4 flex h-16 w-16 items-center justify-center rounded-full bg-surface-light">
          <svg className="h-8 w-8 text-gray-600" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.5}>
            <path strokeLinecap="round" strokeLinejoin="round" d="M9 12.75L11.25 15 15 9.75m-3-7.036A11.959 11.959 0 013.598 6 11.99 11.99 0 003 9.749c0 5.592 3.824 10.29 9 11.623 5.176-1.332 9-6.03 9-11.622 0-1.31-.21-2.571-.598-3.751h-.152c-3.196 0-6.1-1.248-8.25-3.285z" />
          </svg>
        </div>
        <p className="text-base text-gray-400 mb-1">No Bastion pools yet</p>
        <p className="text-sm text-gray-600 mb-5">
          Be the first to create a protected pool!
        </p>
        <Link href="/create" className="btn-primary text-sm px-5 py-2.5">
          Create Pool
        </Link>
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
