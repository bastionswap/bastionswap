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
    <div>
      <div className="mb-6 flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
        <div className="flex gap-1 rounded-xl bg-surface p-1 border border-subtle">
          <button
            onClick={() => setTab("bastion")}
            className={`flex items-center gap-1.5 rounded-lg px-4 py-2 text-sm font-medium transition-all ${
              tab === "bastion"
                ? "bg-surface-light text-white shadow-sm"
                : "text-gray-400 hover:text-white"
            }`}
          >
            <svg className="h-3.5 w-3.5 text-emerald-400" viewBox="0 0 16 16" fill="currentColor">
              <path d="M8 0L1 3v5c0 4.17 2.99 8.06 7 9 4.01-.94 7-4.83 7-9V3L8 0z" />
            </svg>
            Bastion Protected
          </button>
          <button
            onClick={() => setTab("all")}
            className={`rounded-lg px-4 py-2 text-sm font-medium transition-all ${
              tab === "all"
                ? "bg-surface-light text-white shadow-sm"
                : "text-gray-400 hover:text-white"
            }`}
          >
            All Pools
          </button>
        </div>
        <Link href="/create" className="btn-primary text-sm px-4 py-2.5 text-center">
          + Create Pool
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
