"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { ConnectKitButton } from "connectkit";

const NAV_ITEMS = [
  { href: "/swap", label: "Swap" },
  { href: "/pools", label: "Pools" },
  { href: "/create", label: "Create Pool" },
];

export function Header() {
  const pathname = usePathname();

  return (
    <header className="border-b border-gray-800 bg-gray-950">
      <div className="mx-auto flex h-16 max-w-7xl items-center justify-between px-4">
        <div className="flex items-center gap-8">
          <Link href="/" className="text-xl font-bold text-white">
            Bastion<span className="text-bastion-400">Swap</span>
          </Link>
          <nav className="hidden md:flex items-center gap-1">
            {NAV_ITEMS.map(({ href, label }) => (
              <Link
                key={href}
                href={href}
                className={`rounded-lg px-3 py-2 text-sm font-medium transition-colors ${
                  pathname === href || pathname?.startsWith(href + "/")
                    ? "bg-gray-800 text-white"
                    : "text-gray-400 hover:text-white hover:bg-gray-800/50"
                }`}
              >
                {label}
              </Link>
            ))}
          </nav>
        </div>
        <div className="flex items-center gap-3">
          <span className="hidden sm:inline-flex items-center gap-1.5 rounded-full bg-yellow-500/10 px-3 py-1 text-xs font-medium text-yellow-400">
            <span className="h-1.5 w-1.5 rounded-full bg-yellow-400" />
            Base Sepolia
          </span>
          <ConnectKitButton />
        </div>
      </div>
    </header>
  );
}
