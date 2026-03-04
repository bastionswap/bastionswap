"use client";

import { useState } from "react";
import { TokenIcon } from "@/components/ui/TokenIcon";
import { Badge } from "@/components/ui/Badge";

interface Token {
  address: string;
  symbol: string;
  name: string;
  isProtected?: boolean;
}

const POPULAR_TOKENS: Token[] = [
  {
    address: "0x0000000000000000000000000000000000000000",
    symbol: "ETH",
    name: "Ether",
  },
  {
    address: "0x036CbD53842c5426634e7929541eC2318f3dCF7e",
    symbol: "USDC",
    name: "USD Coin",
  },
];

interface TokenSelectModalProps {
  isOpen: boolean;
  onClose: () => void;
  onSelect: (token: Token) => void;
  protectedTokens?: string[];
}

export function TokenSelectModal({
  isOpen,
  onClose,
  onSelect,
  protectedTokens = [],
}: TokenSelectModalProps) {
  const [search, setSearch] = useState("");

  if (!isOpen) return null;

  const filtered = POPULAR_TOKENS.filter(
    (t) =>
      t.symbol.toLowerCase().includes(search.toLowerCase()) ||
      t.name.toLowerCase().includes(search.toLowerCase()) ||
      t.address.toLowerCase().includes(search.toLowerCase())
  );

  const isValidAddress = /^0x[a-fA-F0-9]{40}$/.test(search);
  const isProtected = (addr: string) =>
    protectedTokens.includes(addr.toLowerCase());

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 backdrop-blur-sm"
      onClick={(e) => { if (e.target === e.currentTarget) onClose(); }}
    >
      <div className="w-full max-w-md glass-card p-6 mx-4 animate-in fade-in duration-200">
        <div className="mb-4 flex items-center justify-between">
          <h3 className="text-lg font-semibold">Select Token</h3>
          <button
            onClick={onClose}
            className="rounded-lg p-1.5 text-gray-500 hover:bg-surface-light hover:text-white transition-colors"
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
            <button
              key={token.address}
              onClick={() => {
                onSelect(token);
                onClose();
              }}
              className="flex w-full items-center gap-3 rounded-xl px-3 py-3 hover:bg-surface-light transition-colors"
            >
              <TokenIcon address={token.address} size={36} />
              <div className="text-left">
                <div className="flex items-center gap-2">
                  <span className="font-medium">{token.symbol}</span>
                  {isProtected(token.address) && (
                    <Badge variant="protected">Protected</Badge>
                  )}
                </div>
                <span className="text-xs text-gray-500">{token.name}</span>
              </div>
            </button>
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
              className="flex w-full items-center gap-3 rounded-xl px-3 py-3 hover:bg-surface-light transition-colors"
            >
              <TokenIcon address={search} size={36} />
              <div className="text-left">
                <span className="font-medium">Import Token</span>
                <p className="text-xs text-gray-500">
                  {search.slice(0, 10)}...{search.slice(-8)}
                </p>
              </div>
            </button>
          )}
          {filtered.length === 0 && !isValidAddress && search && (
            <p className="py-8 text-center text-sm text-gray-500">
              No tokens found
            </p>
          )}
        </div>
      </div>
    </div>
  );
}
