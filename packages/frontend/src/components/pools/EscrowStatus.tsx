"use client";

import { useEffect, useState } from "react";
import { Card, CardHeader } from "@/components/ui/Card";
import { Badge } from "@/components/ui/Badge";
import { timeUntil, formatBps } from "@/lib/formatters";

interface EscrowStatusProps {
  escrow: {
    totalLocked: string;
    released: string;
    remaining: string;
    isTriggered: boolean;
    createdAt?: string;
    commitment?: {
      dailyWithdrawLimit: string;
      lockDuration: string;
      maxSellPercent: string;
    } | null;
    vestingSchedule?: {
      id: string;
      timestamp: string;
      basisPoints: number;
    }[];
  };
}

function CircleProgress({
  progress,
  isTriggered,
}: {
  progress: number;
  isTriggered: boolean;
}) {
  const r = 54;
  const c = 2 * Math.PI * r;
  const offset = c - (Math.min(progress, 100) / 100) * c;
  const stroke = isTriggered ? "#EF4444" : "#10B981";

  return (
    <div className="relative mx-auto h-36 w-36">
      <svg className="h-full w-full -rotate-90" viewBox="0 0 120 120">
        <circle cx="60" cy="60" r={r} fill="none" stroke="#1E293B" strokeWidth="8" />
        <circle
          cx="60" cy="60" r={r} fill="none"
          stroke={stroke} strokeWidth="8" strokeLinecap="round"
          strokeDasharray={c} strokeDashoffset={offset}
          className="transition-all duration-1000"
        />
      </svg>
      <div className="absolute inset-0 flex flex-col items-center justify-center">
        <span className="text-2xl font-bold">{progress.toFixed(1)}%</span>
        <span className="text-xs text-gray-500">vested</span>
      </div>
    </div>
  );
}

function Countdown({ targetTs }: { targetTs: number }) {
  const [now, setNow] = useState(Math.floor(Date.now() / 1000));
  useEffect(() => {
    const id = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 1000);
    return () => clearInterval(id);
  }, []);

  const diff = Math.max(targetTs - now, 0);
  const d = Math.floor(diff / 86400);
  const h = Math.floor((diff % 86400) / 3600);
  const m = Math.floor((diff % 3600) / 60);
  const s = diff % 60;
  const pad = (n: number) => n.toString().padStart(2, "0");

  if (diff === 0) return <span className="text-emerald-400 font-medium">Unlocked</span>;

  return (
    <div className="flex gap-1.5 text-sm font-mono">
      {[
        { v: d, l: "d" },
        { v: h, l: "h" },
        { v: m, l: "m" },
        { v: s, l: "s" },
      ].map(({ v, l }) => (
        <div key={l} className="rounded-md bg-surface-light px-2 py-1 text-center">
          <span className="font-semibold">{pad(v)}</span>
          <span className="text-[10px] text-gray-500">{l}</span>
        </div>
      ))}
    </div>
  );
}

export function EscrowStatus({ escrow }: EscrowStatusProps) {
  const total = parseFloat(escrow.totalLocked);
  const released = parseFloat(escrow.released);
  const remaining = parseFloat(escrow.remaining);
  const progress = total > 0 ? (released / total) * 100 : 0;

  const now = Math.floor(Date.now() / 1000);
  const sortedMilestones = escrow.vestingSchedule
    ?.slice()
    .sort((a, b) => parseInt(a.timestamp) - parseInt(b.timestamp));
  const nextMilestone = sortedMilestones?.find(
    (m) => parseInt(m.timestamp) > now
  );

  return (
    <Card glow={escrow.isTriggered ? "red" : "none"}>
      <CardHeader>
        <h3 className="text-lg font-semibold">Escrow Status</h3>
        {escrow.isTriggered ? (
          <Badge variant="triggered">TRIGGERED</Badge>
        ) : (
          <Badge variant="protected">Active</Badge>
        )}
      </CardHeader>

      {escrow.isTriggered && (
        <div className="mb-5 flex items-start gap-3 rounded-xl bg-red-500/10 border border-red-500/20 px-4 py-3">
          <span className="text-lg">&#128680;</span>
          <div>
            <p className="text-sm font-medium text-red-400">
              Trigger activated
            </p>
            <p className="text-xs text-red-400/70">
              Escrowed funds have been redistributed to protect holders.
            </p>
          </div>
        </div>
      )}

      {/* Circle progress */}
      <CircleProgress progress={progress} isTriggered={escrow.isTriggered} />

      {/* Stats row */}
      <div className="mt-5 grid grid-cols-3 gap-3">
        {[
          { label: "Total Locked", value: total.toFixed(4), color: "text-gray-100" },
          { label: "Released", value: released.toFixed(4), color: "text-emerald-400" },
          { label: "Remaining", value: remaining.toFixed(4), color: "text-bastion-300" },
        ].map(({ label, value, color }) => (
          <div key={label} className="rounded-xl bg-surface-light p-3 text-center">
            <p className="text-xs text-gray-500">{label}</p>
            <p className={`text-sm font-semibold ${color}`}>{value}</p>
          </div>
        ))}
      </div>

      {/* Next unlock countdown */}
      {nextMilestone && !escrow.isTriggered && (
        <div className="mt-5 flex flex-col items-center gap-2">
          <p className="text-xs text-gray-500">Next unlock in</p>
          <Countdown targetTs={parseInt(nextMilestone.timestamp)} />
          <p className="text-xs text-gray-600">
            ({formatBps(nextMilestone.basisPoints)} cumulative)
          </p>
        </div>
      )}

      {/* Timeline */}
      {sortedMilestones && sortedMilestones.length > 0 && (
        <div className="mt-5 border-t border-subtle pt-4">
          <p className="text-xs text-gray-500 mb-3">Vesting Timeline</p>
          <div className="relative">
            {/* Track */}
            <div className="absolute left-[7px] top-2 bottom-2 w-0.5 bg-surface-lighter" />
            <div className="space-y-3">
              {sortedMilestones.map((milestone) => {
                const ts = parseInt(milestone.timestamp);
                const isPast = ts <= now;
                return (
                  <div key={milestone.id} className="flex items-center gap-3 relative">
                    <div
                      className={`relative z-10 h-3.5 w-3.5 rounded-full border-2 ${
                        isPast
                          ? "border-emerald-500 bg-emerald-500"
                          : "border-gray-600 bg-surface"
                      }`}
                    />
                    <span className="text-xs text-gray-400 w-24 tabular-nums">
                      {new Date(ts * 1000).toLocaleDateString()}
                    </span>
                    <span className={`text-xs font-medium ${isPast ? "text-emerald-400" : "text-gray-500"}`}>
                      {formatBps(milestone.basisPoints)}
                    </span>
                  </div>
                );
              })}
            </div>
          </div>
        </div>
      )}
    </Card>
  );
}
