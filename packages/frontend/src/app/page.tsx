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
  <svg key="coin" className="h-5 w-5 text-emerald-500" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.5}><path strokeLinecap="round" strokeLinejoin="round" d="M12 6v12m-3-2.818l.879.659c1.171.879 3.07.879 4.242 0 1.172-.879 1.172-2.303 0-3.182C13.536 12.219 12.768 12 12 12c-.725 0-1.45-.22-2.003-.659-1.106-.879-1.106-2.303 0-3.182s2.9-.879 4.006 0l.415.33M21 12a9 9 0 11-18 0 9 9 0 0118 0z" /></svg>,
];

export default function HomePage() {
  const { data: stats } = useProtocolStats();

  const statItems = [
    { label: "Bastion Pools", value: stats?.totalBastionPools ?? "—" },
    { label: "Escrow Locked", value: stats ? `${parseFloat(stats.totalEscrowLocked).toLocaleString(undefined, { maximumFractionDigits: 2 })}` : "—", unit: "LP" },
    { label: "Insurance Available", value: stats ? `${parseFloat(stats.totalInsuranceBalance).toFixed(2)}` : "—", unit: "ETH" },
    { label: "Compensation Paid", value: stats ? `${parseFloat(stats.totalCompensationPaid).toFixed(2)}` : "—", unit: "ETH" },
  ];

  return (
    <div className="space-y-28 pb-16">
      {/* --- Hero --- */}
      <section className="relative flex flex-col items-center pt-16 sm:pt-24 text-center">
        <div className="pointer-events-none absolute -top-20 h-[500px] w-[700px] rounded-full bg-bastion-400/8 blur-[140px]" />

        <div className="relative inline-flex items-center gap-2 rounded-full bg-bastion-50 border border-bastion-100 px-4 py-1.5 text-sm font-medium text-bastion-700 mb-6">
          <ShieldIcon className="h-4 w-4" />
          Protected by smart contract escrow
        </div>

        <h1 className="relative text-4xl font-extrabold tracking-tight text-gray-900 sm:text-5xl lg:text-6xl leading-[1.1]">
          Trade any token.
          <br className="hidden sm:block" />{" "}
          <span className="bg-gradient-to-r from-bastion-600 to-emerald-600 bg-clip-text text-transparent">
            Get compensated
          </span>{" "}
          if it rugs.
        </h1>
        <p className="relative mt-6 max-w-xl text-lg text-gray-500 leading-relaxed">
          The first DEX with built-in escrow and insurance protection.
          Powered by Uniswap V4 hooks on Base.
        </p>
        <div className="relative mt-10 flex flex-col gap-3 sm:flex-row sm:gap-4">
          <Link href="/swap" className="btn-primary text-center px-8 py-3.5 text-base">
            Start Trading
          </Link>
          <Link href="/create" className="btn-secondary text-center px-8 py-3.5 text-base">
            Create Pool
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
            </div>
          ))}
        </div>
      </section>

      {/* --- How It Works --- */}
      <section>
        <div className="text-center mb-12">
          <p className="text-sm font-semibold text-bastion-600 uppercase tracking-wider mb-2">How it works</p>
          <h2 className="text-2xl font-bold text-gray-900 sm:text-3xl">
            Three layers of protection
          </h2>
        </div>
        <div className="grid gap-8 sm:grid-cols-3">
          {[
            {
              icon: <LockIcon className="h-7 w-7 text-bastion-600" />,
              step: "01",
              title: "Issuer creates pool",
              desc: "Token issuer deposits into escrow with a vesting schedule. Commitment parameters are locked on-chain.",
              color: "bg-bastion-50 border-bastion-100",
              iconBg: "bg-bastion-100",
            },
            {
              icon: <SwapIcon className="h-7 w-7 text-emerald-600" />,
              step: "02",
              title: "You trade freely",
              desc: "A small fee from each swap automatically builds the insurance pool. Trade with confidence.",
              color: "bg-emerald-50 border-emerald-100",
              iconBg: "bg-emerald-100",
            },
            {
              icon: <ShieldIcon className="h-7 w-7 text-amber-600" />,
              step: "03",
              title: "If issuer rugs",
              desc: "Triggers detect rug pulls automatically. Escrow is redistributed and insurance pays compensation.",
              color: "bg-amber-50 border-amber-100",
              iconBg: "bg-amber-100",
            },
          ].map(({ icon, step, title, desc, color, iconBg }) => (
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

      {/* --- Protected vs Standard --- */}
      <section>
        <div className="text-center mb-12">
          <p className="text-sm font-semibold text-bastion-600 uppercase tracking-wider mb-2">Compare</p>
          <h2 className="text-2xl font-bold text-gray-900 sm:text-3xl">
            Protected vs Standard
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
                <CheckItem>Issuer escrow with vesting schedule</CheckItem>
                <CheckItem>Automatic insurance pool from swap fees</CheckItem>
                <CheckItem>On-chain reputation tracking</CheckItem>
                <CheckItem>Rug-pull trigger detection</CheckItem>
                <CheckItem>Automatic compensation claims</CheckItem>
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
              <XItem>No escrow protection</XItem>
              <XItem>No insurance mechanism</XItem>
              <XItem>No issuer reputation</XItem>
              <XItem>No trigger detection</XItem>
              <XItem>Suitable for major token pairs (ETH/USDC)</XItem>
            </ul>
          </div>
        </div>
      </section>
    </div>
  );
}
