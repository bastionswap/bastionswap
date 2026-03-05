"use client";

import { SwapCard } from "@/components/swap/SwapCard";

export default function SwapPage() {
  return (
    <div className="flex flex-col items-center justify-center min-h-[calc(100vh-200px)] py-8">
      <div className="text-center mb-8">
        <h1 className="text-2xl font-bold text-gray-900 sm:text-3xl">Swap</h1>
        <p className="mt-2 text-sm text-gray-500">
          Trade tokens with built-in rug-pull protection
        </p>
      </div>
      <SwapCard />
    </div>
  );
}
