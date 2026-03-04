"use client";

import { useState } from "react";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { useAccount, useChainId } from "wagmi";
import { baseSepolia } from "wagmi/chains";
import { ConnectKitButton } from "connectkit";

const NAV_ITEMS = [
  { href: "/swap", label: "Swap" },
  { href: "/pools", label: "Pools" },
  { href: "/create", label: "Create Pool" },
];

export function Header() {
  const pathname = usePathname();
  const chainId = useChainId();
  const { isConnected } = useAccount();
  const [mobileOpen, setMobileOpen] = useState(false);
  const wrongNetwork = isConnected && chainId !== baseSepolia.id;

  return (
    <>
      <header className="sticky top-0 z-40 border-b border-subtle bg-body/80 backdrop-blur-xl">
        <div className="mx-auto flex h-16 max-w-7xl items-center justify-between px-4">
          <div className="flex items-center gap-8">
            <Link href="/" className="flex items-center gap-2 text-xl font-bold text-white">
              <svg className="h-7 w-7 text-emerald-400" viewBox="0 0 24 24" fill="currentColor">
                <path d="M12 1L3 5v6c0 5.55 3.84 10.74 9 12 5.16-1.26 9-6.45 9-12V5l-9-4zm0 2.18l7 3.12v4.7c0 4.47-3.07 8.67-7 9.94-3.93-1.27-7-5.47-7-9.94V6.3l7-3.12z"/>
                <path d="M10.5 14.5l-3-3 1.06-1.06L10.5 12.38l4.94-4.94L16.5 8.5l-6 6z" opacity="0.7"/>
              </svg>
              Bastion<span className="text-bastion-400">Swap</span>
            </Link>
            <nav className="hidden md:flex items-center gap-1">
              {NAV_ITEMS.map(({ href, label }) => (
                <Link
                  key={href}
                  href={href}
                  className={`rounded-lg px-3 py-2 text-sm font-medium transition-colors ${
                    pathname === href || pathname?.startsWith(href + "/")
                      ? "bg-surface-light text-white"
                      : "text-gray-400 hover:text-white hover:bg-surface-light/50"
                  }`}
                >
                  {label}
                </Link>
              ))}
            </nav>
          </div>
          <div className="flex items-center gap-3">
            <span className="hidden sm:inline-flex items-center gap-1.5 rounded-full bg-amber-500/10 px-3 py-1 text-xs font-medium text-amber-400 border border-amber-500/20">
              <span className="h-1.5 w-1.5 animate-pulse-slow rounded-full bg-amber-400" />
              Base Sepolia
            </span>
            <ConnectKitButton />
            {/* Mobile hamburger */}
            <button
              onClick={() => setMobileOpen(!mobileOpen)}
              className="md:hidden rounded-lg p-2 text-gray-400 hover:bg-surface-light hover:text-white"
              aria-label="Toggle menu"
            >
              {mobileOpen ? (
                <svg className="h-5 w-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                  <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M6 18L18 6M6 6l12 12" />
                </svg>
              ) : (
                <svg className="h-5 w-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                  <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M4 6h16M4 12h16M4 18h16" />
                </svg>
              )}
            </button>
          </div>
        </div>

        {/* Mobile nav */}
        {mobileOpen && (
          <nav className="md:hidden border-t border-subtle px-4 py-3 space-y-1">
            {NAV_ITEMS.map(({ href, label }) => (
              <Link
                key={href}
                href={href}
                onClick={() => setMobileOpen(false)}
                className={`block rounded-lg px-3 py-2.5 text-sm font-medium transition-colors ${
                  pathname === href || pathname?.startsWith(href + "/")
                    ? "bg-surface-light text-white"
                    : "text-gray-400 hover:text-white hover:bg-surface-light/50"
                }`}
              >
                {label}
              </Link>
            ))}
          </nav>
        )}
      </header>

      {/* Wrong network banner */}
      {wrongNetwork && (
        <div className="bg-red-500/10 border-b border-red-500/20 px-4 py-2.5 text-center text-sm text-red-400">
          Please switch to Base Sepolia to use BastionSwap
        </div>
      )}
    </>
  );
}
