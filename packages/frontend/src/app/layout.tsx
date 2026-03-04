import type { Metadata } from "next";
import { Inter } from "next/font/google";
import "./globals.css";
import { Providers } from "@/components/layout/Providers";
import { Header } from "@/components/layout/Header";

const inter = Inter({ subsets: ["latin"] });

export const metadata: Metadata = {
  title: "BastionSwap — Protected Token Swaps",
  description:
    "Swap tokens on Uniswap V4 with built-in escrow, insurance, and rug-pull protection.",
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en" className="dark">
      <body className={inter.className}>
        <Providers>
          <div className="flex min-h-screen flex-col">
            <Header />
            <main className="mx-auto w-full max-w-7xl flex-1 px-4 py-6 sm:py-8">
              {children}
            </main>
            <footer className="border-t border-subtle py-6 text-center text-xs text-gray-600">
              BastionSwap — Protected swaps on Uniswap V4
            </footer>
          </div>
        </Providers>
      </body>
    </html>
  );
}
