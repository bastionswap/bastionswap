"use client";

import { useState } from "react";
import Link from "next/link";
import { useBastionPools, useAllPools } from "@/hooks/usePools";
import { PoolList } from "@/components/pools/PoolList";

type Tab = "bastion" | "all";

export default function PoolsPage() {
  const [tab, setTab] = useState<Tab>("bastion");
  const bastionQuery = useBastionPools();
  const allQuery = useAllPools();

  const current = tab === "bastion" ? bastionQuery : allQuery;

  return (
    <div className="max-w-5xl mx-auto">
      {/* Page Header */}
      <div className="mb-8">
        <h1 className="text-2xl font-bold text-gray-900 sm:text-3xl">Pools</h1>
        <p className="mt-2 text-sm text-gray-500">
          Browse protected and standard liquidity pools
        </p>
      </div>

      {/* Controls */}
      <div className="mb-6 flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
        <div className="flex gap-1 rounded-xl bg-gray-100 p-1">
          <button
            onClick={() => setTab("bastion")}
            className={`flex items-center gap-1.5 rounded-lg px-5 py-2.5 text-sm font-medium transition-all ${
              tab === "bastion"
                ? "bg-white text-gray-900 shadow-sm"
                : "text-gray-500 hover:text-gray-700"
            }`}
          >
            <svg className="h-3.5 w-3.5 text-emerald-600" viewBox="0 0 16 16" fill="currentColor">
              <path d="M8 0L1 3v5c0 4.17 2.99 8.06 7 9 4.01-.94 7-4.83 7-9V3L8 0z" />
            </svg>
            Bastion Protected
          </button>
          <button
            onClick={() => setTab("all")}
            className={`rounded-lg px-5 py-2.5 text-sm font-medium transition-all ${
              tab === "all"
                ? "bg-white text-gray-900 shadow-sm"
                : "text-gray-500 hover:text-gray-700"
            }`}
          >
            All Pools
          </button>
        </div>
        <Link href="/create" className="btn-primary text-sm px-5 py-2.5 text-center inline-flex items-center gap-1.5">
          <svg className="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
            <path strokeLinecap="round" strokeLinejoin="round" d="M12 4.5v15m7.5-7.5h-15" />
          </svg>
          Create Pool
        </Link>
      </div>

      <PoolList
        pools={current.data}
        isLoading={current.isLoading}
        error={current.error}
      />
    </div>
  );
}
