"use client";

import { useEffect, useState } from "react";
import { Card, CardHeader } from "@/components/ui/Card";
import { Badge } from "@/components/ui/Badge";
import { formatBps } from "@/lib/formatters";

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
  tokenLabel?: string;
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
    <div className="relative mx-auto h-32 w-32">
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
    const id = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 60_000);
    return () => clearInterval(id);
  }, []);

  const diff = Math.max(targetTs - now, 0);
  if (diff === 0) return <span className="text-emerald-400 font-medium text-sm">Unlocked</span>;

  const d = Math.floor(diff / 86400);
  const h = Math.floor((diff % 86400) / 3600);
  const m = Math.floor((diff % 3600) / 60);
  const pad = (n: number) => n.toString().padStart(2, "0");

  return (
    <div className="flex gap-1 text-sm font-mono">
      {[
        { v: d, l: "d" },
        { v: h, l: "h" },
        { v: m, l: "m" },
      ].map(({ v, l }) => (
        <div key={l} className="rounded-md bg-surface-light px-1.5 py-0.5 text-center">
          <span className="font-semibold">{pad(v)}</span>
          <span className="text-[10px] text-gray-500">{l}</span>
        </div>
      ))}
    </div>
  );
}

function formatDate(ts: number): string {
  return new Date(ts * 1000).toLocaleDateString("en-US", {
    month: "short",
    day: "numeric",
    year: "numeric",
  });
}

function timeAgo(ts: number): string {
  const diff = Math.floor(Date.now() / 1000) - ts;
  if (diff < 60) return "just now";
  if (diff < 3600) return `${Math.floor(diff / 60)}m ago`;
  if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`;
  return `${Math.floor(diff / 86400)}d ago`;
}

function HorizontalTimeline({
  milestones,
  createdAt,
  lockDuration,
}: {
  milestones: { id: string; timestamp: string; basisPoints: number }[];
  createdAt: number;
  lockDuration?: number;
}) {
  const now = Math.floor(Date.now() / 1000);
  const sorted = milestones
    .slice()
    .sort((a, b) => parseInt(a.timestamp) - parseInt(b.timestamp));

  if (sorted.length === 0) return null;

  const startTs = createdAt;
  const endTs = parseInt(sorted[sorted.length - 1].timestamp);
  const range = endTs - startTs;
  if (range <= 0) return null;

  const currentPct = Math.min(Math.max(((now - startTs) / range) * 100, 0), 100);
  const lockPct = lockDuration && lockDuration > 0
    ? Math.min((lockDuration / range) * 100, 100)
    : 0;
  const lockEndTs = lockDuration ? createdAt + lockDuration : 0;
  const isLocked = lockEndTs > 0 && now < lockEndTs;
  const lockRemainingDays = isLocked ? Math.ceil((lockEndTs - now) / 86400) : 0;

  return (
    <div className="mt-5 border-t border-subtle pt-4">
      <p className="text-xs text-gray-500 mb-4">Vesting Timeline</p>

      {/* Horizontal bar */}
      <div className="relative h-2 rounded-full bg-surface-lighter">
        {/* Lock duration overlay */}
        {lockPct > 0 && (
          <div
            className="absolute inset-y-0 left-0 rounded-l-full bg-amber-500/20 z-[1]"
            style={{ width: `${lockPct}%` }}
          />
        )}
        {/* Filled portion */}
        <div
          className="absolute inset-y-0 left-0 rounded-full bg-emerald-500/40 transition-all duration-500 z-[2]"
          style={{ width: `${currentPct}%` }}
        />
        {/* Lock boundary marker */}
        {lockPct > 0 && lockPct < 100 && (
          <div
            className="absolute top-1/2 -translate-y-1/2 -translate-x-1/2 z-[15] flex flex-col items-center"
            style={{ left: `${lockPct}%` }}
          >
            <div className={`h-4 w-4 rounded-full border-2 flex items-center justify-center ${isLocked ? "border-amber-500 bg-amber-500/30" : "border-gray-500 bg-surface"}`}>
              <svg className={`h-2.5 w-2.5 ${isLocked ? "text-amber-400" : "text-gray-500"}`} viewBox="0 0 24 24" fill="currentColor">
                <path d="M18 8h-1V6c0-2.76-2.24-5-5-5S7 3.24 7 6v2H6c-1.1 0-2 .9-2 2v10c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V10c0-1.1-.9-2-2-2zM12 17c-1.1 0-2-.9-2-2s.9-2 2-2 2 .9 2 2-.9 2-2 2zM9 8V6c0-1.66 1.34-3 3-3s3 1.34 3 3v2H9z"/>
              </svg>
            </div>
          </div>
        )}
        {/* Current time marker */}
        <div
          className="absolute top-1/2 -translate-y-1/2 -translate-x-1/2 h-4 w-4 rounded-full bg-emerald-500 border-2 border-surface shadow-lg shadow-emerald-500/30 transition-all duration-500 z-20"
          style={{ left: `${currentPct}%` }}
        />

        {/* Milestone dots */}
        {sorted.map((m) => {
          const ts = parseInt(m.timestamp);
          const pct = ((ts - startTs) / range) * 100;
          const isPast = ts <= now;
          return (
            <div
              key={m.id}
              className="absolute top-1/2 -translate-y-1/2 -translate-x-1/2 z-10"
              style={{ left: `${pct}%` }}
            >
              <div
                className={`h-3 w-3 rounded-full border-2 ${
                  isPast
                    ? "border-emerald-500 bg-emerald-500"
                    : "border-gray-600 bg-surface"
                }`}
              />
            </div>
          );
        })}
      </div>

      {/* Lock status text */}
      {lockDuration && lockDuration > 0 && (
        <p className={`text-[10px] mt-2 ${isLocked ? "text-amber-400" : "text-gray-500"}`}>
          {isLocked
            ? `Liquidity locked until ${formatDate(lockEndTs)} (${lockRemainingDays}d remaining)`
            : "Lock period ended. Issuer can withdraw vested amounts."}
        </p>
      )}

      {/* Labels below */}
      <div className="relative mt-3 h-10">
        {/* Start label */}
        <div className="absolute left-0 text-center" style={{ transform: "translateX(0)" }}>
          <p className="text-[10px] text-gray-500">Start</p>
          <p className="text-[10px] text-gray-600 tabular-nums">{formatDate(startTs)}</p>
        </div>

        {sorted.map((m, i) => {
          const ts = parseInt(m.timestamp);
          const pct = ((ts - startTs) / range) * 100;
          const isPast = ts <= now;
          return (
            <div
              key={m.id}
              className="absolute text-center"
              style={{ left: `${pct}%`, transform: "translateX(-50%)" }}
            >
              <p className={`text-[10px] font-medium ${isPast ? "text-emerald-400" : "text-gray-500"}`}>
                {formatBps(m.basisPoints)}
              </p>
              <p className="text-[10px] text-gray-600 tabular-nums">
                {i === sorted.length - 1 ? formatDate(ts) : `${Math.round((ts - startTs) / 86400)}d`}
              </p>
            </div>
          );
        })}
      </div>
    </div>
  );
}

export function EscrowStatus({ escrow, tokenLabel = "tokens" }: EscrowStatusProps) {
  const total = parseFloat(escrow.totalLocked);
  const released = parseFloat(escrow.released);
  const remaining = parseFloat(escrow.remaining);
  const progress = total > 0 ? (released / total) * 100 : 0;

  const now = Math.floor(Date.now() / 1000);
  const createdAt = escrow.createdAt ? parseInt(escrow.createdAt) : 0;
  const lockDuration = escrow.commitment?.lockDuration
    ? parseInt(escrow.commitment.lockDuration)
    : 0;
  const fullUnlockTs = createdAt && lockDuration ? createdAt + lockDuration : 0;

  const sortedMilestones = escrow.vestingSchedule
    ?.slice()
    .sort((a, b) => parseInt(a.timestamp) - parseInt(b.timestamp));
  const nextMilestone = sortedMilestones?.find(
    (m) => parseInt(m.timestamp) > now
  );
  const allVested = sortedMilestones && sortedMilestones.length > 0 && !nextMilestone;

  // Calculate next unlock amount (incremental, not cumulative)
  const nextUnlockTokens = (() => {
    if (!nextMilestone || total <= 0) return null;
    const idx = sortedMilestones!.indexOf(nextMilestone);
    const prevBps = idx > 0 ? sortedMilestones![idx - 1].basisPoints : 0;
    const incrementBps = nextMilestone.basisPoints - prevBps;
    return (total * incrementBps) / 10000;
  })();

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
      <div className="mt-4 grid grid-cols-3 gap-3">
        {[
          { label: "Total Locked", value: total.toFixed(2), color: "text-gray-100" },
          { label: "Released", value: released.toFixed(2), color: "text-emerald-400" },
          { label: "Remaining", value: remaining.toFixed(2), color: "text-bastion-300" },
        ].map(({ label, value, color }) => (
          <div key={label} className="rounded-xl bg-surface-light p-3 text-center">
            <p className="text-xs text-gray-500">{label}</p>
            <p className={`text-sm font-semibold ${color}`}>{value}</p>
            <p className="text-[10px] text-gray-600">{tokenLabel}</p>
          </div>
        ))}
      </div>

      {/* Next unlock countdown or Fully Vested */}
      {!escrow.isTriggered && (
        <div className="mt-4 rounded-xl bg-surface-light p-3">
          {allVested ? (
            <div className="flex items-center justify-center gap-2">
              <svg className="h-4 w-4 text-emerald-400" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z" />
              </svg>
              <span className="text-sm font-medium text-emerald-400">Fully Vested</span>
            </div>
          ) : nextMilestone ? (
            <div className="flex items-center justify-between">
              <div>
                <p className="text-xs text-gray-500">Next Unlock</p>
                <p className="text-xs text-gray-400 mt-0.5">
                  {formatBps(nextMilestone.basisPoints)} cumulative
                  {nextUnlockTokens !== null && (
                    <span className="text-gray-500">
                      {" "}({nextUnlockTokens.toFixed(2)} {tokenLabel})
                    </span>
                  )}
                </p>
              </div>
              <Countdown targetTs={parseInt(nextMilestone.timestamp)} />
            </div>
          ) : (
            <p className="text-xs text-gray-500 text-center">No vesting schedule</p>
          )}
        </div>
      )}

      {/* Horizontal vesting timeline */}
      {sortedMilestones && sortedMilestones.length > 0 && createdAt > 0 && (
        <HorizontalTimeline milestones={sortedMilestones} createdAt={createdAt} lockDuration={lockDuration} />
      )}

      {/* Escrow dates */}
      {createdAt > 0 && (
        <div className="mt-4 border-t border-subtle pt-3 space-y-1">
          <div className="flex justify-between text-xs">
            <span className="text-gray-500">Created</span>
            <span className="text-gray-400">
              {formatDate(createdAt)}{" "}
              <span className="text-gray-600">({timeAgo(createdAt)})</span>
            </span>
          </div>
          {fullUnlockTs > 0 && (
            <div className="flex justify-between text-xs">
              <span className="text-gray-500">Full Unlock</span>
              <span className="text-gray-400">
                {formatDate(fullUnlockTs)}{" "}
                <span className="text-gray-600">
                  ({Math.round(lockDuration / 86400)}d from creation)
                </span>
              </span>
            </div>
          )}
        </div>
      )}
    </Card>
  );
}
