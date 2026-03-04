"use client";

import { Card, CardHeader } from "@/components/ui/Card";
import { shortenAddress, explorerUrl, formatBps, formatDuration } from "@/lib/formatters";

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

function SemiCircleGauge({ score }: { score: number }) {
  const pct = Math.min(score / 1000, 1);
  const angle = pct * 180;
  // Color based on score range
  let color: string;
  if (score < 200) color = "#EF4444";
  else if (score < 500) color = "#F59E0B";
  else if (score < 800) color = "#10B981";
  else color = "#34D399";

  const r = 50;
  const c = Math.PI * r; // half circumference
  const offset = c - (pct * c);

  return (
    <div className="relative mx-auto h-20 w-36">
      <svg className="h-full w-full" viewBox="0 0 120 70">
        {/* Background arc */}
        <path
          d="M 10 65 A 50 50 0 0 1 110 65"
          fill="none" stroke="#1E293B" strokeWidth="8" strokeLinecap="round"
        />
        {/* Filled arc */}
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
      {commitment && (
        <div className="mt-4 border-t border-subtle pt-4">
          <p className="text-xs text-gray-500 mb-3">Commitment Parameters</p>
          <div className="space-y-2.5">
            {[
              { label: "Daily Withdraw Limit", value: formatBps(parseInt(commitment.dailyWithdrawLimit)) },
              { label: "Lock Duration", value: formatDuration(parseInt(commitment.lockDuration)) },
              { label: "Max Sell / 24h", value: formatBps(parseInt(commitment.maxSellPercent)) },
            ].map(({ label, value }) => (
              <div key={label} className="flex items-center justify-between text-sm">
                <span className="text-gray-500">{label}</span>
                <span className="font-medium tabular-nums">{value}</span>
              </div>
            ))}
          </div>
        </div>
      )}
    </Card>
  );
}
