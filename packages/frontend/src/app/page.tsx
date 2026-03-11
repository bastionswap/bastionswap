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
const EyeIcon = ({ className = "" }: { className?: string }) => (
  <svg className={className} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.5}>
    <path strokeLinecap="round" strokeLinejoin="round" d="M2.036 12.322a1.012 1.012 0 010-.639C3.423 7.51 7.36 4.5 12 4.5c4.638 0 8.573 3.007 9.963 7.178.07.207.07.431 0 .639C20.577 16.49 16.64 19.5 12 19.5c-4.638 0-8.573-3.007-9.963-7.178z" />
    <path strokeLinecap="round" strokeLinejoin="round" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z" />
  </svg>
);
const BoltIcon = ({ className = "" }: { className?: string }) => (
  <svg className={className} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.5}>
    <path strokeLinecap="round" strokeLinejoin="round" d="M3.75 13.5l10.5-11.25L12 10.5h8.25L9.75 21.75 12 13.5H3.75z" />
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
  <svg key="coin" className="h-5 w-5 text-emerald-500" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.5}><path strokeLinecap="round" strokeLinejoin="round" d="M12 6v12m-3-2.818l.879.659c1.171.879 3.07.879 4.242 0 1.172-.879 1.172-2.303 0-3.182C13.536 12.219 12.768 12 12 12c-.725 0-1.45-.22-2.003-.659-1.106-.879-1.106-2.303 0-3.182s2.9-.879 4.006 0l.415.33M21 12a9 9 0 11-18 0 9 9 0 0118 0z" /></svg>,
];

export default function HomePage() {
  const { data: stats } = useProtocolStats();

  const statItems = [
    { label: "Protected Pools", value: stats?.totalBastionPools ?? 0 },
    { label: "LP Locked in Escrow", value: stats ? `${parseFloat(stats.totalEscrowLocked).toLocaleString(undefined, { maximumFractionDigits: 6 })}` : "0", unit: "LP" },
    { label: "Insurance Pool Total", value: stats ? `${parseFloat(stats.totalInsuranceBalance).toFixed(4)}` : "0", unit: "ETH" },
    { label: "Paid to Holders", value: stats ? `${parseFloat(stats.totalCompensationPaid).toFixed(4)}` : "0", unit: "ETH" },
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
          The DEX where rug pulls{" "}
          <br className="hidden sm:block" />
          <span className="bg-gradient-to-r from-bastion-600 to-emerald-600 bg-clip-text text-transparent">
            don&apos;t pay.
          </span>
        </h1>
        <p className="relative mt-6 max-w-2xl text-lg text-gray-500 leading-relaxed">
          BastionSwap locks issuer liquidity with on-chain vesting
          and automatically compensates holders if anything goes wrong.
          <br className="hidden sm:block" />
          Trade any token — if the issuer rugs, you get paid back.
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
            Every day, thousands of tokens launch on DEXs.
            <br className="hidden sm:block" />
            <span className="text-gray-400"> Most are scams.</span>
          </h2>
          <div className="mt-8 space-y-5 text-base sm:text-lg text-gray-400 leading-relaxed text-left sm:text-center">
            <p>
              On Uniswap alone, new tokens launch every minute. Anyone can
              create a token, add liquidity, and pull it all out once buyers
              drive up the price. There&apos;s no protection, no refund, no recourse.
            </p>
            <p>
              Token scanners play whack-a-mole with new scam patterns.
              Template launchpads restrict what you can build.
              Neither solves the root cause.
            </p>
            <p className="text-white font-medium">
              BastionSwap takes a different approach: instead of trying to
              detect scams, we make scamming unprofitable.
            </p>
          </div>
        </div>
      </section>

      {/* --- How It Works --- */}
      <section>
        <div className="text-center mb-12">
          <p className="text-sm font-semibold text-bastion-600 uppercase tracking-wider mb-2">How it works</p>
          <h2 className="text-2xl font-bold text-gray-900 sm:text-3xl">
            Four layers of protection
          </h2>
        </div>
        <div className="grid gap-6 sm:grid-cols-2 lg:grid-cols-4">
          {[
            {
              icon: <LockIcon className="h-7 w-7 text-bastion-600" />,
              step: "01",
              title: "Issuer launches token",
              desc: "The issuer creates a pool with initial liquidity. The protocol automatically locks their LP with a vesting schedule — 7-day lockup, then 83-day linear unlock. No extra steps, no separate escrow deposit.",
              iconBg: "bg-bastion-100",
            },
            {
              icon: <ShieldIcon className="h-7 w-7 text-emerald-600" />,
              step: "02",
              title: "Insurance builds automatically",
              desc: "Every time someone buys the token, 1% goes into a per-token insurance pool denominated in ETH or USDC. The issuer can't touch it. Nobody can — except the protocol.",
              iconBg: "bg-emerald-100",
            },
            {
              icon: <EyeIcon className="h-7 w-7 text-blue-600" />,
              step: "03",
              title: "You trade with full transparency",
              desc: "The dashboard shows everything: escrow countdown, insurance pool size, issuer reputation score, and commitment parameters. You see exactly how protected you are before you buy.",
              iconBg: "bg-blue-100",
            },
            {
              icon: <BoltIcon className="h-7 w-7 text-amber-600" />,
              step: "04",
              title: "If anything goes wrong",
              desc: "The protocol detects rug pulls, mass dumps, and commitment breaches automatically on-chain. Issuer LP is seized, combined with the insurance pool, and distributed to holders as compensation. Detection and seizure are automatic — holders claim their share from the dashboard.",
              iconBg: "bg-amber-100",
            },
          ].map(({ icon, step, title, desc, iconBg }) => (
            <div key={step} className="glass-card relative overflow-hidden p-7">
              <div className="flex items-center gap-3 mb-4">
                <div className={`flex h-12 w-12 items-center justify-center rounded-xl ${iconBg}`}>
                  {icon}
                </div>
                <span className="text-xs font-bold text-gray-300 uppercase tracking-widest">Step {step}</span>
              </div>
              <h3 className="mb-2 text-base font-semibold text-gray-900">{title}</h3>
              <p className="text-sm text-gray-500 leading-relaxed">{desc}</p>
            </div>
          ))}
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
              Buyers avoid new tokens because they can&apos;t tell scams
              from real projects. BastionSwap fixes this.
            </p>
            <p>
              When you launch on BastionSwap, your commitment is
              visible on-chain: lock-up period, vesting schedule,
              sell limits — all immutable. Buyers see exactly what
              you&apos;ve promised and can verify it themselves.
            </p>
            <p>
              Stricter commitments earn higher reputation scores
              and featured placement. Complete your vesting and
              earn 10% of the insurance pool as a reward.
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
                <CheckItem>1% insurance pool auto-funded from every buy</CheckItem>
                <CheckItem>On-chain rug pull detection (LP removal, dumps, commitment breach)</CheckItem>
                <CheckItem>Automatic compensation to holders if triggered</CheckItem>
                <CheckItem>Issuer reputation score visible on dashboard</CheckItem>
                <CheckItem>Works through any frontend or aggregator — protection is at the protocol level</CheckItem>
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
              <XItem>No insurance mechanism</XItem>
              <XItem>No on-chain monitoring</XItem>
              <XItem>Suitable for established pairs (ETH/USDC, WBTC/ETH)</XItem>
            </ul>
          </div>
        </div>
      </section>
    </div>
  );
}
