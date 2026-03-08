"use client";

import { useState } from "react";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { useAccount, useChainId, useSwitchChain } from "wagmi";
import { baseSepolia } from "wagmi/chains";
import { ConnectButton } from "@rainbow-me/rainbowkit";

const NAV_ITEMS = [
  { href: "/swap", label: "Swap", icon: "M7.5 21L3 16.5m0 0L7.5 12M3 16.5h13.5m0-13.5L21 7.5m0 0L16.5 12M21 7.5H7.5" },
  { href: "/pools", label: "Pools", icon: "M20 7l-8-4-8 4m16 0l-8 4m8-4v10l-8 4m0-10L4 7m8 4v10M4 7v10l8 4" },
  { href: "/create", label: "Create", icon: "M12 4.5v15m7.5-7.5h-15" },
  { href: "/history", label: "History", icon: "M12 6v6h4.5m4.5 0a9 9 0 11-18 0 9 9 0 0118 0z" },
];

export function Header() {
  const pathname = usePathname();
  const chainId = useChainId();
  const { isConnected } = useAccount();
  const { switchChain, isPending: isSwitching } = useSwitchChain();
  const [mobileOpen, setMobileOpen] = useState(false);
  const wrongNetwork = isConnected && chainId !== baseSepolia.id && chainId !== 31337;

  return (
    <>
      <header className="sticky top-0 z-40 border-b border-subtle bg-white/80 backdrop-blur-xl">
        <div className="mx-auto flex h-[60px] max-w-7xl items-center justify-between px-4 sm:px-6">
          <div className="flex items-center gap-10">
            <Link href="/" className="flex items-center gap-2.5">
              <div className="flex h-8 w-8 items-center justify-center rounded-lg bg-bastion-600">
                <svg className="h-5 w-5 text-white" viewBox="0 0 24 24" fill="currentColor">
                  <path d="M12 1L3 5v6c0 5.55 3.84 10.74 9 12 5.16-1.26 9-6.45 9-12V5l-9-4zm0 2.18l7 3.12v4.7c0 4.47-3.07 8.67-7 9.94-3.93-1.27-7-5.47-7-9.94V6.3l7-3.12z"/>
                  <path d="M10.5 14.5l-3-3 1.06-1.06L10.5 12.38l4.94-4.94L16.5 8.5l-6 6z" opacity="0.8"/>
                </svg>
              </div>
              <span className="text-lg font-bold text-gray-900">
                Bastion<span className="text-bastion-600">Swap</span>
              </span>
            </Link>
            <nav className="hidden md:flex items-center gap-1">
              {NAV_ITEMS.map(({ href, label, icon }) => {
                const isActive = pathname === href || pathname?.startsWith(href + "/");
                return (
                  <Link
                    key={href}
                    href={href}
                    className={`flex items-center gap-2 rounded-lg px-4 py-2 text-sm font-medium transition-all ${
                      isActive
                        ? "bg-bastion-50 text-bastion-700"
                        : "text-gray-500 hover:text-gray-900 hover:bg-gray-50"
                    }`}
                  >
                    <svg className="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5}>
                      <path strokeLinecap="round" strokeLinejoin="round" d={icon} />
                    </svg>
                    {label}
                  </Link>
                );
              })}
            </nav>
          </div>
          <div className="flex items-center gap-3">
            <span className="hidden sm:inline-flex items-center gap-1.5 rounded-full bg-amber-50 px-3 py-1 text-xs font-medium text-amber-700 border border-amber-200">
              <span className="h-1.5 w-1.5 animate-pulse-slow rounded-full bg-amber-500" />
              Base Sepolia
            </span>
            <ConnectButton showBalance={false} chainStatus="icon" />
            <button
              onClick={() => setMobileOpen(!mobileOpen)}
              className="md:hidden rounded-lg p-2 text-gray-400 hover:bg-gray-50 hover:text-gray-600"
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

        {mobileOpen && (
          <nav className="md:hidden border-t border-subtle px-4 py-3 space-y-1 bg-white">
            {NAV_ITEMS.map(({ href, label, icon }) => (
              <Link
                key={href}
                href={href}
                onClick={() => setMobileOpen(false)}
                className={`flex items-center gap-2 rounded-lg px-3 py-2.5 text-sm font-medium transition-colors ${
                  pathname === href || pathname?.startsWith(href + "/")
                    ? "bg-bastion-50 text-bastion-700"
                    : "text-gray-500 hover:text-gray-900 hover:bg-gray-50"
                }`}
              >
                <svg className="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5}>
                  <path strokeLinecap="round" strokeLinejoin="round" d={icon} />
                </svg>
                {label}
              </Link>
            ))}
          </nav>
        )}
      </header>

      {wrongNetwork && (
        <div className="bg-red-50 border-b border-red-200 px-4 py-2.5 text-center text-sm text-red-600 font-medium flex items-center justify-center gap-3">
          <span>Wrong network detected.</span>
          <button
            onClick={() => switchChain({ chainId: baseSepolia.id })}
            disabled={isSwitching}
            className="inline-flex items-center gap-1.5 rounded-lg bg-red-600 px-3 py-1 text-xs font-semibold text-white hover:bg-red-700 transition-colors disabled:opacity-50"
          >
            {isSwitching ? "Switching..." : "Switch to Base Sepolia"}
          </button>
        </div>
      )}
    </>
  );
}
