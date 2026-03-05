"use client";

import { useReadContract } from "wagmi";
import { baseSepolia } from "wagmi/chains";
import { Card, CardHeader } from "@/components/ui/Card";
import { shortenAddress, explorerUrl, formatBps, formatDuration } from "@/lib/formatters";
import { getContracts } from "@/config/contracts";
import { ReputationEngineABI } from "@/config/abis";

interface IssuerInfoProps {
  issuer: {
    id: string;
    reputationScore: string;
    totalEscrowsCreated?: number;
    totalEscrowsCompleted?: number;
    totalTriggersActivated?: number;
  };
  commitment?: {
    dailyWithdrawLimit: string;
    lockDuration: string;
    maxSellPercent: string;
  } | null;
}

// Default commitment values from the protocol
const DEFAULTS = {
  dailyWithdrawLimit: 500, // 5% in bps
  lockDuration: 7_776_000, // 90 days
  maxSellPercent: 300, // 3% in bps
};

function SemiCircleGauge({ score }: { score: number }) {
  const pct = Math.min(score / 1000, 1);
  let color: string;
  if (score < 200) color = "#EF4444";
  else if (score < 500) color = "#F59E0B";
  else if (score < 800) color = "#10B981";
  else color = "#34D399";

  const r = 50;
  const c = Math.PI * r;
  const offset = c - pct * c;

  return (
    <div className="relative mx-auto h-20 w-36">
      <svg className="h-full w-full" viewBox="0 0 120 70">
        <path
          d="M 10 65 A 50 50 0 0 1 110 65"
          fill="none" stroke="#1E293B" strokeWidth="8" strokeLinecap="round"
        />
        <path
          d="M 10 65 A 50 50 0 0 1 110 65"
          fill="none" stroke={color} strokeWidth="8" strokeLinecap="round"
          strokeDasharray={c}
          strokeDashoffset={offset}
          className="transition-all duration-1000"
        />
      </svg>
      <div className="absolute bottom-0 left-1/2 -translate-x-1/2 text-center">
        <span className="text-xl font-bold" style={{ color }}>{score}</span>
        <p className="text-[10px] text-gray-500">/ 1000</p>
      </div>
    </div>
  );
}

function CommitmentTag({ value, defaultValue, isLowerBetter }: {
  value: number;
  defaultValue: number;
  isLowerBetter: boolean;
}) {
  const isDefault = value === defaultValue;
  const isStricter = isLowerBetter ? value < defaultValue : value > defaultValue;

  if (isDefault) {
    return <span className="text-[10px] text-gray-600 ml-1.5">Default</span>;
  }
  if (isStricter) {
    return (
      <span className="text-[10px] text-emerald-500 ml-1.5 flex items-center gap-0.5">
        <svg className="h-3 w-3" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
          <path strokeLinecap="round" strokeLinejoin="round" d="M5 13l4 4L19 7" />
        </svg>
        Strict
      </span>
    );
  }
  return <span className="text-[10px] text-amber-500 ml-1.5">Relaxed</span>;
}

function ScoreBreakdown({ issuerAddress }: { issuerAddress: string }) {
  const contracts = getContracts(baseSepolia.id);

  // Use encodeScoreData to get breakdown data
  const { data: encodedData } = useReadContract({
    address: contracts?.ReputationEngine as `0x${string}`,
    abi: ReputationEngineABI,
    functionName: "encodeScoreData",
    args: [issuerAddress as `0x${string}`],
    query: { enabled: !!contracts },
  });

  // Decode the encoded data
  const { data: decoded } = useReadContract({
    address: contracts?.ReputationEngine as `0x${string}`,
    abi: ReputationEngineABI,
    functionName: "decodeScoreData",
    args: encodedData ? [encodedData as `0x${string}`] : undefined,
    query: { enabled: !!encodedData },
  });

  if (!decoded) return null;

  const [, poolsCreated, escrowsCompleted, triggerCount, uniqueTokens] = decoded as [
    bigint, number, number, number, number
  ];

  return (
    <div className="mt-3 space-y-1.5">
      <p className="text-[10px] text-gray-500 uppercase tracking-wider">Score Components</p>
      {[
        { label: "Pools Created", value: poolsCreated },
        { label: "Escrows Completed", value: escrowsCompleted },
        { label: "Triggers", value: triggerCount, negative: true },
        { label: "Token Diversity", value: uniqueTokens },
      ].map(({ label, value, negative }) => (
        <div key={label} className="flex items-center justify-between text-[11px]">
          <span className="text-gray-500">{label}</span>
          <span className={negative && value > 0 ? "text-red-400" : "text-gray-400"}>
            {value}
          </span>
        </div>
      ))}
    </div>
  );
}

export function IssuerInfo({ issuer, commitment }: IssuerInfoProps) {
  const score = parseInt(issuer.reputationScore);
  const created = issuer.totalEscrowsCreated ?? 0;
  const completed = issuer.totalEscrowsCompleted ?? 0;
  const triggers = issuer.totalTriggersActivated ?? 0;
  const successRate = created > 0 ? ((completed / created) * 100).toFixed(0) : "—";

  return (
    <Card>
      <CardHeader>
        <h3 className="text-lg font-semibold">Issuer Profile</h3>
      </CardHeader>

      <div className="mb-4 flex items-center gap-2">
        <div className="flex h-8 w-8 items-center justify-center rounded-full bg-surface-light text-xs font-bold text-bastion-300">
          {issuer.id.slice(2, 4).toUpperCase()}
        </div>
        <a
          href={explorerUrl(issuer.id)}
          target="_blank"
          rel="noopener noreferrer"
          className="text-sm text-bastion-300 hover:text-bastion-200 transition-colors"
        >
          {shortenAddress(issuer.id)}
          <span className="ml-1 text-gray-600">&#8599;</span>
        </a>
      </div>

      {/* Reputation Gauge */}
      <SemiCircleGauge score={score} />

      {/* Score Breakdown */}
      <ScoreBreakdown issuerAddress={issuer.id} />

      {/* History Grid */}
      <div className="mt-4 grid grid-cols-4 gap-2">
        {[
          { label: "Created", value: created, color: "text-gray-100" },
          { label: "Completed", value: completed, color: "text-emerald-400" },
          { label: "Triggers", value: triggers, color: "text-red-400" },
          { label: "Success", value: `${successRate}%`, color: "text-bastion-300" },
        ].map(({ label, value, color }) => (
          <div key={label} className="rounded-lg bg-surface-light p-2.5 text-center">
            <p className={`text-base font-semibold ${color}`}>{value}</p>
            <p className="text-[10px] text-gray-500">{label}</p>
          </div>
        ))}
      </div>

      {/* Commitment Parameters */}
      {commitment ? (
        <div className="mt-4 border-t border-subtle pt-4">
          <p className="text-xs text-gray-500 mb-3">Commitments</p>
          <div className="space-y-2.5">
            {[
              {
                label: "Daily Withdraw Limit",
                value: formatBps(parseInt(commitment.dailyWithdrawLimit)),
                raw: parseInt(commitment.dailyWithdrawLimit),
                default_: DEFAULTS.dailyWithdrawLimit,
                lowerBetter: true,
              },
              {
                label: "Max Sell / 24h",
                value: formatBps(parseInt(commitment.maxSellPercent)),
                raw: parseInt(commitment.maxSellPercent),
                default_: DEFAULTS.maxSellPercent,
                lowerBetter: true,
              },
              {
                label: "Lock Duration",
                value: formatDuration(parseInt(commitment.lockDuration)),
                raw: parseInt(commitment.lockDuration),
                default_: DEFAULTS.lockDuration,
                lowerBetter: false,
              },
            ].map(({ label, value, raw, default_, lowerBetter }) => (
              <div key={label} className="flex items-center justify-between text-sm">
                <span className="text-gray-500">{label}</span>
                <div className="flex items-center">
                  <span className="font-medium tabular-nums">{value}</span>
                  <CommitmentTag
                    value={raw}
                    defaultValue={default_}
                    isLowerBetter={lowerBetter}
                  />
                </div>
              </div>
            ))}
          </div>
        </div>
      ) : (
        <div className="mt-4 border-t border-subtle pt-4">
          <p className="text-xs text-gray-500 mb-2">Commitments</p>
          <p className="text-xs text-gray-600">No custom commitments (using defaults)</p>
        </div>
      )}
    </Card>
  );
}
