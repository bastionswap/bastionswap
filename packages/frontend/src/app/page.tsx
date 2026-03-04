import Link from "next/link";

export default function HomePage() {
  return (
    <div className="flex flex-col items-center justify-center py-20 text-center">
      <h1 className="text-5xl font-bold tracking-tight">
        Swap with <span className="text-bastion-400">Protection</span>
      </h1>
      <p className="mt-4 max-w-xl text-lg text-gray-400">
        BastionSwap adds escrow, insurance, and reputation layers to Uniswap V4
        — so you can trade new tokens without fear of rug pulls.
      </p>
      <div className="mt-8 flex gap-4">
        <Link
          href="/swap"
          className="rounded-xl bg-bastion-500 px-6 py-3 font-semibold text-white hover:bg-bastion-600 transition-colors"
        >
          Launch App
        </Link>
        <Link
          href="/pools"
          className="rounded-xl border border-gray-700 px-6 py-3 font-semibold text-gray-300 hover:border-gray-600 hover:text-white transition-colors"
        >
          Explore Pools
        </Link>
      </div>
    </div>
  );
}
