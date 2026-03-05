"use client";

import Link from "next/link";
import { useQuery } from "@tanstack/react-query";
import { gql } from "graphql-request";
import { graphClient } from "@/config/subgraph";

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
  return useQuery({
    queryKey: ["protocolStats"],
    queryFn: () =>
      graphClient.request<{ protocolStats: Stats | null }>(PROTOCOL_STATS_QUERY),
    select: (d) => d.protocolStats,
  });
}

/* ——— icons ——— */
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
  <li className="flex items-center gap-2 text-sm text-gray-300">
    <CheckCircle className="h-4 w-4 shrink-0 text-emerald-400" />
    {children}
  </li>
);

const XItem = ({ children }: { children: React.ReactNode }) => (
  <li className="flex items-center gap-2 text-sm text-gray-500">
    <svg className="h-4 w-4 shrink-0 text-gray-600" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.5}>
      <path strokeLinecap="round" strokeLinejoin="round" d="M6 18L18 6M6 6l12 12" />
    </svg>
    {children}
  </li>
);

export default function HomePage() {
  const { data: stats } = useProtocolStats();

  const statItems = [
    { label: "Bastion Pools", value: stats?.totalBastionPools ?? "—" },
    { label: "Escrow Locked", value: stats ? `${parseFloat(stats.totalEscrowLocked).toLocaleString(undefined, { maximumFractionDigits: 2 })} tokens` : "—" },
    { label: "Insurance Available", value: stats ? `${parseFloat(stats.totalInsuranceBalance).toFixed(2)} ETH` : "—" },
    { label: "Compensation Paid", value: stats ? `${parseFloat(stats.totalCompensationPaid).toFixed(2)} ETH` : "—" },
  ];

  return (
    <div className="space-y-24 pb-12">
      {/* ——— Hero ——— */}
      <section className="relative flex flex-col items-center pt-12 sm:pt-20 text-center">
        {/* Gradient orb */}
        <div className="pointer-events-none absolute -top-20 h-[400px] w-[600px] rounded-full bg-bastion-500/10 blur-[120px]" />

        <h1 className="relative text-4xl font-extrabold tracking-tight sm:text-5xl lg:text-6xl">
          Trade any token.{" "}
          <span className="bg-gradient-to-r from-emerald-400 to-bastion-300 bg-clip-text text-transparent">
            Get compensated
          </span>{" "}
          if it rugs.
        </h1>
        <p className="relative mt-5 max-w-2xl text-base text-gray-400 sm:text-lg">
          The first DEX with built-in escrow and insurance protection.
          Powered by Uniswap V4 hooks on Base.
        </p>
        <div className="relative mt-8 flex flex-col gap-3 sm:flex-row sm:gap-4">
          <Link href="/swap" className="btn-primary text-center">
            Start Trading
          </Link>
          <Link href="/create" className="btn-secondary text-center">
            Create Pool
          </Link>
        </div>

        {/* Protocol stats */}
        <div className="relative mt-14 grid w-full max-w-2xl grid-cols-2 gap-4 sm:grid-cols-4">
          {statItems.map(({ label, value }) => (
            <div key={label} className="glass-card px-4 py-4 text-center">
              <p className="text-lg font-bold sm:text-xl">{value}</p>
              <p className="text-xs text-gray-500">{label}</p>
            </div>
          ))}
        </div>
      </section>

      {/* ——— How It Works ——— */}
      <section>
        <h2 className="mb-10 text-center text-2xl font-bold sm:text-3xl">
          How It Works
        </h2>
        <div className="grid gap-6 sm:grid-cols-3">
          {[
            {
              icon: <LockIcon className="h-8 w-8 text-bastion-400" />,
              step: "1",
              title: "Issuer creates pool",
              desc: "Token issuer deposits into escrow with a vesting schedule. Commitment parameters are locked on-chain.",
            },
            {
              icon: <SwapIcon className="h-8 w-8 text-emerald-400" />,
              step: "2",
              title: "You trade freely",
              desc: "A small fee from each swap automatically builds the insurance pool. Trade with confidence.",
            },
            {
              icon: <ShieldIcon className="h-8 w-8 text-amber-400" />,
              step: "3",
              title: "If issuer rugs",
              desc: "Triggers detect rug pulls automatically. Escrow is redistributed and insurance pays compensation.",
            },
          ].map(({ icon, step, title, desc }) => (
            <div key={step} className="glass-card relative overflow-hidden p-6">
              <span className="absolute right-4 top-4 text-5xl font-black text-white/[0.03]">
                {step}
              </span>
              <div className="mb-4 flex h-14 w-14 items-center justify-center rounded-xl bg-surface-light">
                {icon}
              </div>
              <h3 className="mb-2 text-lg font-semibold">{title}</h3>
              <p className="text-sm text-gray-400 leading-relaxed">{desc}</p>
            </div>
          ))}
        </div>
      </section>

      {/* ——— Protected vs Standard ——— */}
      <section>
        <h2 className="mb-10 text-center text-2xl font-bold sm:text-3xl">
          Protected vs Standard
        </h2>
        <div className="grid gap-6 sm:grid-cols-2">
          {/* Protected */}
          <div className="glass-card relative overflow-hidden border-emerald-500/20 p-6 shadow-[0_0_30px_rgba(16,185,129,0.06)]">
            <div className="absolute inset-0 bg-gradient-to-br from-emerald-500/5 to-transparent" />
            <div className="relative">
              <div className="mb-4 flex items-center gap-2">
                <div className="flex h-10 w-10 items-center justify-center rounded-full bg-emerald-500/15">
                  <ShieldIcon className="h-5 w-5 text-emerald-400" />
                </div>
                <h3 className="text-lg font-bold text-emerald-400">Bastion Protected</h3>
              </div>
              <p className="mb-5 text-sm text-gray-400">
                For new token launches. Built-in safety for traders.
              </p>
              <ul className="space-y-2.5">
                <CheckItem>Issuer escrow with vesting schedule</CheckItem>
                <CheckItem>Automatic insurance pool from swap fees</CheckItem>
                <CheckItem>On-chain reputation tracking</CheckItem>
                <CheckItem>Rug-pull trigger detection</CheckItem>
                <CheckItem>Automatic compensation claims</CheckItem>
              </ul>
            </div>
          </div>

          {/* Standard */}
          <div className="glass-card p-6">
            <div className="mb-4 flex items-center gap-2">
              <div className="flex h-10 w-10 items-center justify-center rounded-full bg-gray-500/15">
                <SwapIcon className="h-5 w-5 text-gray-400" />
              </div>
              <h3 className="text-lg font-bold text-gray-400">Standard V4 Pool</h3>
            </div>
            <p className="mb-5 text-sm text-gray-500">
              For established pairs. Standard Uniswap V4 pool with no hook.
            </p>
            <ul className="space-y-2.5">
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
