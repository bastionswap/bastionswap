"use client";

import { useState, useMemo } from "react";
import { TokenIcon } from "@/components/ui/TokenIcon";
import { Badge } from "@/components/ui/Badge";
import { useAllPools, useBastionPools } from "@/hooks/usePools";
import { useTokenInfo } from "@/hooks/useTokenInfo";

interface Token {
  address: string;
  symbol: string;
  name: string;
  isProtected?: boolean;
}

const ETH_TOKEN: Token = {
  address: "0x0000000000000000000000000000000000000000",
  symbol: "ETH",
  name: "Ether",
};

interface TokenSelectModalProps {
  isOpen: boolean;
  onClose: () => void;
  onSelect: (token: Token) => void;
  protectedTokens?: string[];
}

/** Extract unique token addresses from pool data */
function usePoolTokens(): Token[] {
  const { data: allPools } = useAllPools();
  const { data: bastionPools } = useBastionPools();

  return useMemo(() => {
    if (!allPools || allPools.length === 0) return [ETH_TOKEN];

    const bastionTokens = new Set(
      (bastionPools ?? [])
        .filter((p) => p.issuedToken)
        .map((p) => p.issuedToken!.toLowerCase())
    );

    // Collect unique token addresses from all pools
    const seen = new Set<string>();
    const tokens: Token[] = [ETH_TOKEN];
    seen.add(ETH_TOKEN.address);

    for (const pool of allPools) {
      for (const addr of [pool.token0, pool.token1]) {
        const lower = addr.toLowerCase();
        if (seen.has(lower)) continue;
        seen.add(lower);

        tokens.push({
          address: addr,
          symbol: "", // filled by TokenEntry component
          name: "",
          isProtected: bastionTokens.has(lower),
        });
      }
    }

    return tokens;
  }, [allPools, bastionPools]);
}

/** Single token entry that resolves its own name/symbol on-chain */
function TokenEntry({
  token,
  isProtected,
  onSelect,
  onClose,
}: {
  token: Token;
  isProtected: boolean;
  onSelect: (token: Token) => void;
  onClose: () => void;
}) {
  const info = useTokenInfo(token.address as `0x${string}`);
  const symbol = token.symbol || info.symbol || `${token.address.slice(0, 6)}…`;
  const name = token.name || info.name || "Unknown Token";

  return (
    <button
      onClick={() => {
        onSelect({ ...token, symbol, name });
        onClose();
      }}
      className="flex w-full items-center gap-3 rounded-xl px-3 py-3 hover:bg-gray-50 transition-colors"
    >
      <TokenIcon address={token.address} size={36} />
      <div className="text-left flex-1 min-w-0">
        <div className="flex items-center gap-2">
          <span className="font-medium text-gray-900">{symbol}</span>
          {(token.isProtected || isProtected) && (
            <Badge variant="protected">Protected</Badge>
          )}
        </div>
        <span className="text-xs text-gray-400 truncate block">{name}</span>
      </div>
    </button>
  );
}

export function TokenSelectModal({
  isOpen,
  onClose,
  onSelect,
  protectedTokens = [],
}: TokenSelectModalProps) {
  const [search, setSearch] = useState("");
  const poolTokens = usePoolTokens();

  if (!isOpen) return null;

  const isProtected = (addr: string) =>
    protectedTokens.includes(addr.toLowerCase());

  const filtered = poolTokens
    .filter((t) => {
      if (!search) return true;
      const q = search.toLowerCase();
      return (
        t.symbol.toLowerCase().includes(q) ||
        t.name.toLowerCase().includes(q) ||
        t.address.toLowerCase().includes(q)
      );
    })
    .sort((a, b) => {
      const aProtected = a.isProtected || isProtected(a.address) ? 1 : 0;
      const bProtected = b.isProtected || isProtected(b.address) ? 1 : 0;
      return bProtected - aProtected;
    });

  const isValidAddress = /^0x[a-fA-F0-9]{40}$/.test(search);

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/20 backdrop-blur-sm"
      onClick={(e) => { if (e.target === e.currentTarget) onClose(); }}
    >
      <div className="w-full max-w-md glass-card p-6 mx-4 animate-in fade-in duration-200 shadow-xl">
        <div className="mb-4 flex items-center justify-between">
          <h3 className="text-lg font-semibold text-gray-900">Select Token</h3>
          <button
            onClick={onClose}
            className="rounded-lg p-1.5 text-gray-400 hover:bg-gray-50 hover:text-gray-600 transition-colors"
          >
            <svg className="h-5 w-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M6 18L18 6M6 6l12 12" />
            </svg>
          </button>
        </div>
        <input
          type="text"
          placeholder="Search name, symbol, or paste address"
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          className="input-base mb-4"
          autoFocus
        />
        <div className="max-h-80 space-y-1 overflow-y-auto">
          {filtered.map((token) => (
            <TokenEntry
              key={token.address}
              token={token}
              isProtected={isProtected(token.address)}
              onSelect={onSelect}
              onClose={onClose}
            />
          ))}
          {isValidAddress && filtered.length === 0 && (
            <button
              onClick={() => {
                onSelect({
                  address: search,
                  symbol: search.slice(0, 6),
                  name: "Custom Token",
                });
                onClose();
              }}
              className="flex w-full items-center gap-3 rounded-xl px-3 py-3 hover:bg-gray-50 transition-colors"
            >
              <TokenIcon address={search} size={36} />
              <div className="text-left">
                <span className="font-medium text-gray-900">Import Token</span>
                <p className="text-xs text-gray-400">
                  {search.slice(0, 10)}...{search.slice(-8)}
                </p>
              </div>
            </button>
          )}
          {filtered.length === 0 && !isValidAddress && search && (
            <p className="py-8 text-center text-sm text-gray-400">
              No tokens found
            </p>
          )}
        </div>
      </div>
    </div>
  );
}
