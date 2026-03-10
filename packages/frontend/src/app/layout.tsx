import type { Metadata } from "next";
import { Inter } from "next/font/google";
import "./globals.css";
import { Analytics } from "@vercel/analytics/next";
import { Providers } from "@/components/layout/Providers";
import { Header } from "@/components/layout/Header";

const inter = Inter({ subsets: ["latin"] });

export const metadata: Metadata = {
  title: "BastionSwap — Protected Token Swaps",
  description:
    "Swap tokens on Uniswap V4 with built-in escrow, insurance, and rug-pull protection.",
  icons: {
    icon: [
      { url: "/favicon.ico", sizes: "48x48" },
      { url: "/logo.png", type: "image/png", sizes: "1024x1024" },
    ],
    apple: "/logo.png",
  },
  openGraph: {
    title: "BastionSwap — Protected Token Swaps",
    description:
      "Swap tokens on Uniswap V4 with built-in escrow, insurance, and rug-pull protection.",
    images: ["/logo.png"],
  },
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en">
      <body className={inter.className}>
        <Providers>
          <div className="flex min-h-screen flex-col overflow-x-hidden">
            <Header />
            <main className="mx-auto w-full max-w-7xl flex-1 px-4 sm:px-6 py-6 sm:py-10">
              {children}
            </main>
            <footer className="border-t border-subtle bg-white py-8">
              <div className="mx-auto max-w-7xl px-4 sm:px-6 flex flex-col sm:flex-row items-center justify-between gap-4">
                <div className="flex items-center gap-2 text-sm text-gray-400">
                  <img src="/logo.png" alt="BastionSwap" width={20} height={20} className="rounded" />
                  BastionSwap
                </div>
                <p className="text-xs text-gray-400">Protected swaps on Uniswap V4 &middot; Base Sepolia Testnet</p>
              </div>
            </footer>
          </div>
        </Providers>
        <Analytics />
      </body>
    </html>
  );
}
