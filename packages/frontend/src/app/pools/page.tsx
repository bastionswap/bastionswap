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
      <div className="mb-6 flex items-center justify-between">
        <div className="flex gap-1 rounded-xl bg-gray-900 p-1">
          <button
            onClick={() => setTab("bastion")}
            className={`rounded-lg px-4 py-2 text-sm font-medium transition-colors ${
              tab === "bastion"
                ? "bg-gray-800 text-white"
                : "text-gray-400 hover:text-white"
            }`}
          >
            Bastion Protected
          </button>
          <button
            onClick={() => setTab("all")}
            className={`rounded-lg px-4 py-2 text-sm font-medium transition-colors ${
              tab === "all"
                ? "bg-gray-800 text-white"
                : "text-gray-400 hover:text-white"
            }`}
          >
            All Pools
          </button>
        </div>
        <Link
          href="/create"
          className="rounded-xl bg-bastion-500 px-4 py-2 text-sm font-semibold text-white hover:bg-bastion-600 transition-colors"
        >
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
