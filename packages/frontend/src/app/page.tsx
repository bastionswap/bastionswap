"use client";

import Link from "next/link";
import { useChainId } from "wagmi";
import { useQuery } from "@tanstack/react-query";
import { gql } from "graphql-request";
import { graphClient } from "@/config/subgraph";
import { useBastionPools } from "@/hooks/usePools";

const PROTOCOL_STATS_QUERY = gql`
  query ProtocolStats {
    protocolStats(id: "global") {
      totalBastionPools
      totalEscrowLocked
      totalInsuranceBalance
      totalCompensationPaid
    }
  }
`;

interface Stats {
  totalBastionPools: number;
  totalEscrowLocked: string;
  totalInsuranceBalance: string;
  totalCompensationPaid: string;
}

function useProtocolStats() {
  const chainId = useChainId();
  const { data: pools } = useBastionPools();

  return useQuery({
    queryKey: ["protocolStats", chainId, pools?.length, pools?.[0]?.escrow?.totalLiquidity],
    queryFn: () => {
      if (chainId === 31337 && pools) {
        const stats: Stats = {
          totalBastionPools: pools.length,
          totalEscrowLocked: pools.reduce((sum, p) => sum + parseFloat(p.escrow?.totalLiquidity ?? "0"), 0).toString(),
          totalInsuranceBalance: pools.reduce((sum, p) => sum + parseFloat(p.insurancePool?.balance ?? "0"), 0).toString(),
          totalCompensationPaid: "0",
        };
        return { protocolStats: stats };
      }
      return graphClient.request<{ protocolStats: Stats | null }>(PROTOCOL_STATS_QUERY);
    },
    select: (d) => d.protocolStats,
  });
}

/* --- icons --- */
const ShieldIcon = ({ className = "" }: { className?: string }) => (
  <svg className={className} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.5}>
    <path strokeLinecap="round" strokeLinejoin="round" d="M9 12.75L11.25 15 15 9.75m-3-7.036A11.959 11.959 0 013.598 6 11.99 11.99 0 003 9.749c0 5.592 3.824 10.29 9 11.623 5.176-1.332 9-6.03 9-11.622 0-1.31-.21-2.571-.598-3.751h-.152c-3.196 0-6.1-1.248-8.25-3.285z" />
  </svg>
);
const LockIcon = ({ className = "" }: { className?: string }) => (
  <svg className={className} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.5}>
    <path strokeLinecap="round" strokeLinejoin="round" d="M16.5 10.5V6.75a4.5 4.5 0 10-9 0v3.75m-.75 11.25h10.5a2.25 2.25 0 002.25-2.25v-6.75a2.25 2.25 0 00-2.25-2.25H6.75a2.25 2.25 0 00-2.25 2.25v6.75a2.25 2.25 0 002.25 2.25z" />
  </svg>
);
const SwapIcon = ({ className = "" }: { className?: string }) => (
  <svg className={className} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.5}>
    <path strokeLinecap="round" strokeLinejoin="round" d="M7.5 21L3 16.5m0 0L7.5 12M3 16.5h13.5m0-13.5L21 7.5m0 0L16.5 12M21 7.5H7.5" />
  </svg>
);
const CheckCircle = ({ className = "" }: { className?: string }) => (
  <svg className={className} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.5}>
    <path strokeLinecap="round" strokeLinejoin="round" d="M9 12.75L11.25 15 15 9.75M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
  </svg>
);

const CheckItem = ({ children }: { children: React.ReactNode }) => (
  <li className="flex items-start gap-2.5 text-sm text-gray-600">
    <CheckCircle className="h-5 w-5 shrink-0 text-emerald-600 mt-0.5" />
    <span>{children}</span>
  </li>
);

const XItem = ({ children }: { children: React.ReactNode }) => (
  <li className="flex items-start gap-2.5 text-sm text-gray-400">
    <svg className="h-5 w-5 shrink-0 text-gray-300 mt-0.5" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.5}>
      <path strokeLinecap="round" strokeLinejoin="round" d="M6 18L18 6M6 6l12 12" />
    </svg>
    <span>{children}</span>
  </li>
);

const statIcons = [
  <svg key="pools" className="h-5 w-5 text-bastion-500" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.5}><path strokeLinecap="round" strokeLinejoin="round" d="M20 7l-8-4-8 4m16 0l-8 4m8-4v10l-8 4m0-10L4 7m8 4v10M4 7v10l8 4" /></svg>,
  <svg key="lock" className="h-5 w-5 text-bastion-500" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.5}><path strokeLinecap="round" strokeLinejoin="round" d="M16.5 10.5V6.75a4.5 4.5 0 10-9 0v3.75m-.75 11.25h10.5a2.25 2.25 0 002.25-2.25v-6.75a2.25 2.25 0 00-2.25-2.25H6.75a2.25 2.25 0 00-2.25 2.25v6.75a2.25 2.25 0 002.25 2.25z" /></svg>,
  <svg key="shield" className="h-5 w-5 text-emerald-500" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.5}><path strokeLinecap="round" strokeLinejoin="round" d="M9 12.75L11.25 15 15 9.75m-3-7.036A11.959 11.959 0 013.598 6 11.99 11.99 0 003 9.749c0 5.592 3.824 10.29 9 11.623 5.176-1.332 9-6.03 9-11.622 0-1.31-.21-2.571-.598-3.751h-.152c-3.196 0-6.1-1.248-8.25-3.285z" /></svg>,
  <svg key="block" className="h-5 w-5 text-emerald-500" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.5}><path strokeLinecap="round" strokeLinejoin="round" d="M18.364 18.364A9 9 0 005.636 5.636m12.728 12.728A9 9 0 015.636 5.636m12.728 12.728L5.636 5.636" /></svg>,
];

export default function HomePage() {
  const { data: stats } = useProtocolStats();

  const statItems = [
    { label: "Protected Pools", value: stats?.totalBastionPools ?? 0 },
    { label: "LP Locked", value: stats ? `${parseFloat(stats.totalEscrowLocked).toLocaleString(undefined, { maximumFractionDigits: 6 })}` : "0", unit: "LP" },
    { label: "Insurance Pools", value: stats ? `${parseFloat(stats.totalInsuranceBalance).toFixed(4)}` : "0", unit: "ETH" },
    { label: "Transactions Protected", value: stats?.totalBastionPools ? `${(stats.totalBastionPools * 0).toLocaleString()}` : "0" },
  ];

  return (
    <div className="space-y-28 pb-16">
      {/* --- Hero --- */}
      <section className="relative flex flex-col items-center pt-16 sm:pt-24 text-center">
        <div className="pointer-events-none absolute -top-20 h-[500px] w-[700px] rounded-full bg-bastion-400/8 blur-[140px]" />

        <div className="relative inline-flex items-center gap-2 rounded-full bg-bastion-50 border border-bastion-100 px-4 py-1.5 text-sm font-medium text-bastion-700 mb-6">
          Built on Uniswap V4 Hooks &middot; Base
        </div>

        <h1 className="relative text-4xl font-extrabold tracking-tight text-gray-900 sm:text-5xl lg:text-6xl leading-[1.1]">
          The DEX where rug pulls are{" "}
          <br className="hidden sm:block" />
          <span className="bg-gradient-to-r from-bastion-600 to-emerald-600 bg-clip-text text-transparent">
            blocked on-chain.
          </span>
        </h1>
        <p className="relative mt-6 max-w-2xl text-lg text-gray-500 leading-relaxed">
          BastionSwap enforces issuer sell limits and LP vesting
          directly in the swap transaction. Exceeding limits?
          The transaction reverts. It never happened.
          <br className="hidden sm:block" />
          <span className="mt-2 block text-base text-gray-400">
            Powered by Uniswap V4 Hooks on Base.
          </span>
        </p>
        <div className="relative mt-10 flex flex-col gap-3 sm:flex-row sm:gap-4">
          <Link href="/swap" className="btn-primary text-center px-8 py-3.5 text-base">
            Start Trading
          </Link>
          <Link href="/create" className="btn-secondary text-center px-8 py-3.5 text-base">
            Launch a Token
          </Link>
        </div>

        {/* Protocol stats */}
        <div className="relative mt-20 grid w-full max-w-3xl grid-cols-2 gap-4 sm:grid-cols-4">
          {statItems.map(({ label, value, unit }, i) => (
            <div key={label} className="glass-card px-5 py-5 text-center">
              <div className="mx-auto mb-2 flex h-9 w-9 items-center justify-center rounded-lg bg-gray-50">
                {statIcons[i]}
              </div>
              <p className="text-xl font-bold text-gray-900 sm:text-2xl">
                {value}
                {unit && <span className="text-sm font-normal text-gray-400 ml-1">{unit}</span>}
              </p>
              <p className="text-xs text-gray-400 mt-1">{label}</p>
              <p className="text-[10px] text-gray-300 mt-0.5">Testnet</p>
            </div>
          ))}
        </div>
      </section>

      {/* --- The Problem --- */}
      <section className="relative -mx-4 sm:-mx-6 px-4 sm:px-6 py-16 sm:py-20 bg-gray-950 text-white">
        <div className="mx-auto max-w-3xl text-center">
          <h2 className="text-2xl font-bold sm:text-3xl lg:text-4xl leading-tight">
            Every day, thousands of tokens launch.
            <br className="hidden sm:block" />
            <span className="text-gray-400"> Most are scams.</span>
          </h2>
          <div className="mt-8 space-y-5 text-base sm:text-lg text-gray-400 leading-relaxed text-left sm:text-center">
            <p>
              On DEXs, anyone can create a token, add liquidity, and drain it.
              Token scanners detect yesterday&apos;s scam patterns.
              Template launchpads restrict what you can build.
            </p>
            <p className="text-white font-medium">
              BastionSwap doesn&apos;t detect scams.
              It makes them impossible to execute.
            </p>
          </div>
        </div>
      </section>

      {/* --- Two Lines of Defense --- */}
      <section>
        <div className="text-center mb-12">
          <p className="text-sm font-semibold text-bastion-600 uppercase tracking-wider mb-2">How it works</p>
          <h2 className="text-2xl font-bold text-gray-900 sm:text-3xl">
            Two lines of defense
          </h2>
        </div>
        <div className="grid gap-6 sm:grid-cols-2 max-w-5xl mx-auto">
          {/* Defense 01 — Prevention */}
          <div className="glass-card relative overflow-hidden p-7">
            <div className="flex items-center gap-3 mb-4">
              <div className="flex h-12 w-12 items-center justify-center rounded-xl bg-bastion-100">
                <LockIcon className="h-7 w-7 text-bastion-600" />
              </div>
              <span className="text-xs font-bold text-gray-300 uppercase tracking-widest">Defense 01</span>
            </div>
            <h3 className="mb-2 text-base font-semibold text-gray-900">Prevention: blocked before it happens</h3>
            <div className="space-y-3 text-sm text-gray-500 leading-relaxed">
              <p>
                When an issuer creates a pool, their LP is locked with
                a vesting schedule — they can&apos;t pull liquidity early.
              </p>
              <p>
                Sell limits are enforced on every swap. If the issuer tries
                to dump tokens beyond their committed daily or weekly limit,
                the entire transaction reverts. This works regardless of
                how the swap is routed — direct, through a router,
                or via any aggregator.
              </p>
              <p className="text-gray-700 font-medium">
                The harmful action never executes. No damage, no recovery needed.
              </p>
            </div>
          </div>

          {/* Defense 02 — Compensation */}
          <div className="glass-card relative overflow-hidden p-7">
            <div className="flex items-center gap-3 mb-4">
              <div className="flex h-12 w-12 items-center justify-center rounded-xl bg-emerald-100">
                <ShieldIcon className="h-7 w-7 text-emerald-600" />
              </div>
              <span className="text-xs font-bold text-gray-300 uppercase tracking-widest">Defense 02</span>
            </div>
            <h3 className="mb-2 text-base font-semibold text-gray-900">Compensation: insurance for what prevention can&apos;t catch</h3>
            <div className="space-y-3 text-sm text-gray-500 leading-relaxed">
              <p>
                1% of every buy swap builds a per-token insurance pool.
                In v2, this pool will cover losses from contract-level exploits
                like honeypots and hidden taxes that slip past on-chain prevention.
                If a token is confirmed malicious, the issuer&apos;s remaining LP
                is seized and combined with the insurance pool to compensate holders.
              </p>
            </div>
          </div>
        </div>
      </section>

      {/* --- For Issuers --- */}
      <section className="relative">
        <div className="mx-auto max-w-3xl text-center">
          <p className="text-sm font-semibold text-bastion-600 uppercase tracking-wider mb-2">For token issuers</p>
          <h2 className="text-2xl font-bold text-gray-900 sm:text-3xl">
            Launching a token? Build trust from day one.
          </h2>
          <div className="mt-8 space-y-5 text-base text-gray-500 leading-relaxed text-left sm:text-center">
            <p>
              When you launch on BastionSwap, your commitments are
              on-chain and immutable: lock-up period, vesting schedule,
              daily and weekly sell limits — all visible to buyers.
            </p>
            <p>
              Set stricter limits, earn a higher reputation score.
              Complete your vesting, earn 10% of the insurance pool
              as a reward.
            </p>
            <p className="text-gray-700 font-medium">
              Same Uniswap V4 liquidity. Same trading experience.
              More buyers who trust you.
            </p>
          </div>
          <div className="mt-10">
            <Link href="/create" className="btn-primary inline-flex items-center gap-2 px-8 py-3.5 text-base">
              Launch Your Token
              <svg className="h-4 w-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M13.5 4.5L21 12m0 0l-7.5 7.5M21 12H3" />
              </svg>
            </Link>
          </div>
        </div>
      </section>

      {/* --- Protected vs Standard --- */}
      <section>
        <div className="text-center mb-12">
          <p className="text-sm font-semibold text-bastion-600 uppercase tracking-wider mb-2">Compare</p>
          <h2 className="text-2xl font-bold text-gray-900 sm:text-3xl">
            Two types of pools. One clear choice for new tokens.
          </h2>
        </div>
        <div className="grid gap-6 sm:grid-cols-2 max-w-4xl mx-auto">
          {/* Protected */}
          <div className="glass-card relative overflow-hidden border-emerald-200 p-7">
            <div className="absolute top-0 right-0 bg-emerald-600 text-white text-[10px] font-bold uppercase tracking-wider px-3 py-1 rounded-bl-lg">
              Recommended
            </div>
            <div className="absolute inset-0 bg-gradient-to-br from-emerald-50/80 to-transparent" />
            <div className="relative">
              <div className="mb-5 flex items-center gap-3">
                <div className="flex h-11 w-11 items-center justify-center rounded-xl bg-emerald-100">
                  <ShieldIcon className="h-6 w-6 text-emerald-600" />
                </div>
                <div>
                  <h3 className="text-base font-bold text-emerald-700">Bastion Protected</h3>
                  <p className="text-xs text-gray-500">For new token launches</p>
                </div>
              </div>
              <ul className="space-y-3">
                <CheckItem>Issuer LP locked with customizable vesting (7d–365d)</CheckItem>
                <CheckItem>Daily and weekly sell limits enforced by transaction revert</CheckItem>
                <CheckItem>1% insurance pool auto-funded from every buy</CheckItem>
                <CheckItem>Issuer reputation score on dashboard</CheckItem>
                <CheckItem>Works through any frontend or aggregator</CheckItem>
              </ul>
            </div>
          </div>

          {/* Standard */}
          <div className="glass-card p-7">
            <div className="mb-5 flex items-center gap-3">
              <div className="flex h-11 w-11 items-center justify-center rounded-xl bg-gray-100">
                <SwapIcon className="h-6 w-6 text-gray-400" />
              </div>
              <div>
                <h3 className="text-base font-bold text-gray-400">Standard V4 Pool</h3>
                <p className="text-xs text-gray-400">For established pairs</p>
              </div>
            </div>
            <ul className="space-y-3">
              <XItem>No LP restrictions — issuer can remove anytime</XItem>
              <XItem>No sell limits — issuer can dump freely</XItem>
              <XItem>No insurance mechanism</XItem>
              <XItem>Suitable for established pairs (ETH/USDC, WBTC/ETH)</XItem>
            </ul>
          </div>
        </div>
      </section>
    </div>
  );
}
