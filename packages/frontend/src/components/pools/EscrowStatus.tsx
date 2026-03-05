"use client";

import { useEffect, useState, useMemo } from "react";
import { Badge } from "@/components/ui/Badge";
import { VestingChart } from "@/components/ui/VestingChart";
import { formatBps } from "@/lib/formatters";

interface EscrowStatusProps {
  escrow: {
    totalLiquidity: string;
    removedLiquidity: string;
    remainingLiquidity: string;
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
  tokenSymbol?: string;
  vestingEndTime?: number;
}

// Default milestones for strictness comparison
const DEFAULT_MILESTONES = [
  { time: 7 * 86400, bps: 1000 },
  { time: 30 * 86400, bps: 3000 },
  { time: 90 * 86400, bps: 10000 },
];

function computeStrictnessLevel(
  milestones: { timestamp: string; basisPoints: number }[],
  createdAt: number,
  lockDuration: number
): "stricter" | "default" | "looser" | null {
  if (!milestones || milestones.length === 0 || createdAt === 0) return null;

  const sorted = milestones.slice().sort((a, b) => parseInt(a.timestamp) - parseInt(b.timestamp));
  const vestingStart = createdAt + lockDuration;
  const offsets = sorted.map((m) => ({
    timeOffset: parseInt(m.timestamp) - vestingStart,
    bps: m.basisPoints,
  }));
  const lastOffset = offsets[offsets.length - 1].timeOffset;

  if (lastOffset < 90 * 86400) return "looser";

  const getBpsAtOffset = (offset: number): number => {
    let bps = 0;
    for (const o of offsets) {
      if (o.timeOffset <= offset) bps = o.bps;
      else break;
    }
    return bps;
  };

  let allSame = true;

  for (const def of DEFAULT_MILESTONES) {
    const customBps = getBpsAtOffset(def.time);
    if (customBps > def.bps) return "looser";
    if (customBps !== def.bps) allSame = false;
  }

  if (allSame && lastOffset === 90 * 86400) return "default";
  return "stricter";
}

function formatDate(ts: number): string {
  return new Date(ts * 1000).toLocaleDateString("en-US", {
    month: "short",
    day: "numeric",
    year: "numeric",
  });
}

function formatShortDate(ts: number): string {
  return new Date(ts * 1000).toLocaleDateString("en-US", {
    month: "short",
    day: "numeric",
  });
}

function formatCompact(n: number): string {
  if (n === 0) return "0";
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`;
  if (n >= 1_000) return `${(n / 1_000).toFixed(1)}K`;
  if (n >= 1) return n.toFixed(2);
  return n.toFixed(4);
}

/** Format LP liquidity amount */
function formatLP(amount: number): string {
  return `${formatCompact(amount)} LP`;
}

/** Format LP at a specific bps proportion */
function formatLPAtBps(totalLiquidity: number, bps: number): string {
  const part = (totalLiquidity * bps) / 10000;
  return `${formatCompact(part)} LP`;
}

function Countdown({ targetTs, label }: { targetTs: number; label?: string }) {
  const [now, setNow] = useState(Math.floor(Date.now() / 1000));
  useEffect(() => {
    const id = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 1000);
    return () => clearInterval(id);
  }, []);

  const diff = Math.max(targetTs - now, 0);
  if (diff === 0) {
    return (
      <div className="flex items-center gap-1.5">
        <div className="h-2 w-2 rounded-full bg-emerald-500" />
        <span className="text-sm font-medium text-emerald-600">Complete</span>
      </div>
    );
  }

  const d = Math.floor(diff / 86400);
  const h = Math.floor((diff % 86400) / 3600);
  const m = Math.floor((diff % 3600) / 60);
  const s = diff % 60;

  return (
    <div>
      {label && <p className="text-[11px] text-gray-400 mb-1.5">{label}</p>}
      <div className="flex gap-1.5">
        {[
          { v: d, l: "days" },
          { v: h, l: "hrs" },
          { v: m, l: "min" },
          { v: s, l: "sec" },
        ].map(({ v, l }) => (
          <div
            key={l}
            className="flex flex-col items-center rounded-lg bg-gray-900 px-2.5 py-1.5 min-w-[44px]"
          >
            <span className="text-base font-bold text-white tabular-nums leading-tight">
              {v.toString().padStart(2, "0")}
            </span>
            <span className="text-[9px] text-gray-400 uppercase tracking-wider">{l}</span>
          </div>
        ))}
      </div>
    </div>
  );
}

/* ── Full-width Vesting Timeline ── */
function VestingTimeline({
  milestones,
  createdAt,
  lockDuration,
  vestingEndTime,
  total,
}: {
  milestones: { id: string; timestamp: string; basisPoints: number }[];
  createdAt: number;
  lockDuration: number;
  vestingEndTime?: number;
  total: number;
}) {
  const [now, setNow] = useState(Math.floor(Date.now() / 1000));
  useEffect(() => {
    const id = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 60_000);
    return () => clearInterval(id);
  }, []);

  const sorted = useMemo(
    () => milestones.slice().sort((a, b) => parseInt(a.timestamp) - parseInt(b.timestamp)),
    [milestones]
  );

  const startTs = createdAt;
  const lastMilestoneTs = sorted.length > 0 ? parseInt(sorted[sorted.length - 1].timestamp) : 0;
  const endTs = vestingEndTime && vestingEndTime > lastMilestoneTs
    ? vestingEndTime
    : lastMilestoneTs > 0
      ? lastMilestoneTs
      : lockDuration > 0
        ? createdAt + lockDuration
        : createdAt + 86400 * 90;
  const range = endTs - startTs;
  if (range <= 0) return null;

  const toPct = (ts: number) => Math.min(Math.max(((ts - startTs) / range) * 100, 0), 100);
  const currentPct = toPct(now);
  const lockEndTs = lockDuration > 0 ? createdAt + lockDuration : 0;
  const lockPct = lockEndTs > 0 ? toPct(lockEndTs) : 0;
  const isLocked = lockEndTs > 0 && now < lockEndTs;

  const phases: { label: string; color: string; bgColor: string; start: number; end: number; active: boolean }[] = [];
  if (lockPct > 0) {
    phases.push({
      label: "Lock Period",
      color: isLocked ? "text-amber-700" : "text-gray-400",
      bgColor: isLocked ? "bg-amber-400/60" : "bg-amber-200/40",
      start: 0,
      end: lockPct,
      active: isLocked,
    });
  }
  phases.push({
    label: "Vesting",
    color: !isLocked && currentPct < 100 ? "text-emerald-700" : "text-gray-400",
    bgColor: !isLocked && currentPct < 100 ? "bg-emerald-400/50" : "bg-emerald-200/30",
    start: lockPct,
    end: 100,
    active: !isLocked && currentPct < 100,
  });

  return (
    <div className="mt-6">
      {/* Phase labels */}
      <div className="flex mb-3">
        {phases.map((p) => (
          <div
            key={p.label}
            className="flex items-center gap-1.5"
            style={{ width: `${p.end - p.start}%`, marginLeft: p.start > 0 ? undefined : 0 }}
          >
            <div className={`h-2.5 w-2.5 rounded-sm ${p.bgColor}`} />
            <span className={`text-[11px] font-medium ${p.color}`}>
              {p.label}
              {p.active && (
                <span className="ml-1 inline-flex h-1.5 w-1.5 rounded-full bg-current animate-pulse" />
              )}
            </span>
          </div>
        ))}
      </div>

      {/* Timeline track */}
      <div className="relative">
        <div className="h-3 rounded-full bg-gray-100 overflow-hidden">
          {lockPct > 0 && (
            <div
              className="absolute inset-y-0 left-0 bg-amber-100 rounded-l-full"
              style={{ width: `${lockPct}%`, height: "12px" }}
            />
          )}
          <div
            className={`absolute inset-y-0 left-0 rounded-full transition-all duration-1000 ${
              isLocked ? "bg-amber-400" : "bg-emerald-500"
            }`}
            style={{ width: `${currentPct}%`, height: "12px" }}
          />
        </div>

        {/* Lock end marker */}
        {lockPct > 0 && lockPct < 100 && (
          <div
            className="absolute top-1/2 -translate-y-1/2 z-20"
            style={{ left: `${lockPct}%`, transform: `translateX(-50%) translateY(-50%)` }}
          >
            <div
              className={`h-5 w-5 rounded-full border-2 border-white shadow-md flex items-center justify-center ${
                isLocked ? "bg-amber-500" : "bg-gray-300"
              }`}
            >
              <svg className="h-3 w-3 text-white" viewBox="0 0 24 24" fill="currentColor">
                <path d="M18 8h-1V6c0-2.76-2.24-5-5-5S7 3.24 7 6v2H6c-1.1 0-2 .9-2 2v10c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V10c0-1.1-.9-2-2-2zM12 17c-1.1 0-2-.9-2-2s.9-2 2-2 2 .9 2 2-.9 2-2 2zM9 8V6c0-1.66 1.34-3 3-3s3 1.34 3 3v2H9z" />
              </svg>
            </div>
          </div>
        )}

        {/* Milestone markers */}
        {sorted.map((m, i) => {
          const ts = parseInt(m.timestamp);
          const pct = toPct(ts);
          const isPast = ts <= now;
          const cumulativeBps = m.basisPoints;

          return (
            <div
              key={m.id}
              className="absolute top-1/2 z-10 group"
              style={{ left: `${pct}%`, transform: "translateX(-50%) translateY(-50%)" }}
            >
              <div
                className={`h-4 w-4 rounded-full border-2 border-white shadow-sm transition-all ${
                  isPast ? "bg-emerald-500" : "bg-white border-gray-300"
                }`}
              />
              {/* Tooltip on hover */}
              <div className="absolute bottom-full mb-2 left-1/2 -translate-x-1/2 hidden group-hover:block z-50">
                <div className="bg-gray-900 text-white rounded-lg px-3 py-2 text-xs whitespace-nowrap shadow-lg">
                  <p className="font-medium">{formatBps(cumulativeBps)} LP vested</p>
                  <p className="text-gray-400">{formatLPAtBps(total, cumulativeBps)}</p>
                  <p className="text-gray-400">{formatDate(ts)}</p>
                  <div className="absolute top-full left-1/2 -translate-x-1/2 border-4 border-transparent border-t-gray-900" />
                </div>
              </div>
            </div>
          );
        })}

        {/* Current position indicator */}
        <div
          className="absolute top-1/2 z-30"
          style={{ left: `${currentPct}%`, transform: "translateX(-50%) translateY(-50%)" }}
        >
          <div className={`h-6 w-6 rounded-full border-3 border-white shadow-lg ${
            isLocked ? "bg-amber-500" : "bg-emerald-600"
          }`}>
            <div className="absolute inset-0 rounded-full animate-ping opacity-30" style={{
              backgroundColor: isLocked ? "#f59e0b" : "#059669"
            }} />
          </div>
        </div>
      </div>

      {/* Timeline dates */}
      <div className="relative mt-3 flex justify-between text-[11px] text-gray-400">
        <span>{formatShortDate(startTs)}</span>
        {lockEndTs > 0 && lockPct > 15 && lockPct < 85 && (
          <span className="absolute" style={{ left: `${lockPct}%`, transform: "translateX(-50%)" }}>
            <span className={isLocked ? "text-amber-600 font-medium" : ""}>
              {formatShortDate(lockEndTs)}
            </span>
          </span>
        )}
        <span>{formatShortDate(endTs)}</span>
      </div>

      {/* Lock status */}
      {lockDuration > 0 && (
        <div className={`mt-3 rounded-lg px-3 py-2 text-xs flex items-center gap-2 ${
          isLocked ? "bg-amber-50 text-amber-700" : "bg-gray-50 text-gray-500"
        }`}>
          <svg className="h-3.5 w-3.5 shrink-0" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2}>
            <path strokeLinecap="round" strokeLinejoin="round" d="M16.5 10.5V6.75a4.5 4.5 0 10-9 0v3.75m-.75 11.25h10.5a2.25 2.25 0 002.25-2.25v-6.75a2.25 2.25 0 00-2.25-2.25H6.75a2.25 2.25 0 00-2.25 2.25v6.75a2.25 2.25 0 002.25 2.25z" />
          </svg>
          {isLocked
            ? `Locked until ${formatDate(lockEndTs)} (${Math.ceil((lockEndTs - now) / 86400)} days remaining)`
            : `Lock period ended on ${formatDate(lockEndTs)}`
          }
        </div>
      )}
    </div>
  );
}

/* ── Milestone List ── */
function MilestoneList({
  milestones,
  total,
}: {
  milestones: { id: string; timestamp: string; basisPoints: number }[];
  total: number;
}) {
  const now = Math.floor(Date.now() / 1000);
  const sorted = milestones.slice().sort((a, b) => parseInt(a.timestamp) - parseInt(b.timestamp));

  return (
    <div className="mt-5">
      <p className="text-[11px] font-medium text-gray-400 uppercase tracking-wider mb-3">
        Vesting Schedule
      </p>
      <div className="space-y-0">
        {sorted.map((m, i) => {
          const ts = parseInt(m.timestamp);
          const isPast = ts <= now;
          const isNext = !isPast && (i === 0 || parseInt(sorted[i - 1].timestamp) <= now);

          return (
            <div key={m.id} className="flex items-start gap-3">
              {/* Timeline connector */}
              <div className="flex flex-col items-center">
                <div
                  className={`h-3 w-3 rounded-full border-2 shrink-0 mt-1 ${
                    isPast
                      ? "bg-emerald-500 border-emerald-500"
                      : isNext
                        ? "bg-white border-emerald-500"
                        : "bg-white border-gray-300"
                  }`}
                />
                {i < sorted.length - 1 && (
                  <div className={`w-0.5 h-8 ${isPast ? "bg-emerald-300" : "bg-gray-200"}`} />
                )}
              </div>
              {/* Content */}
              <div className={`flex-1 flex items-center justify-between pb-3 ${
                isNext ? "bg-emerald-50/50 -mx-2 px-2 rounded-lg" : ""
              }`}>
                <div>
                  <p className={`text-sm font-medium ${isPast ? "text-gray-400" : isNext ? "text-emerald-700" : "text-gray-700"}`}>
                    {formatBps(m.basisPoints)} LP
                    {isNext && <span className="text-[10px] ml-1.5 text-emerald-600 font-semibold">NEXT</span>}
                  </p>
                  <p className="text-[11px] text-gray-400">
                    {formatDate(ts)} &middot; {formatLPAtBps(total, m.basisPoints)}
                  </p>
                </div>
                {isPast && (
                  <svg className="h-4 w-4 text-emerald-500 shrink-0" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                    <path strokeLinecap="round" strokeLinejoin="round" d="M5 13l4 4L19 7" />
                  </svg>
                )}
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}

export function EscrowStatus({ escrow, vestingEndTime }: EscrowStatusProps) {
  const total = parseFloat(escrow.totalLiquidity);
  const removed = parseFloat(escrow.removedLiquidity);
  const remaining = parseFloat(escrow.remainingLiquidity);
  const progress = total > 0 ? (removed / total) * 100 : 0;

  const now = Math.floor(Date.now() / 1000);
  const createdAt = escrow.createdAt ? parseInt(escrow.createdAt) : 0;
  const lockDuration = escrow.commitment?.lockDuration
    ? parseInt(escrow.commitment.lockDuration)
    : 0;

  const sortedMilestones = escrow.vestingSchedule
    ?.slice()
    .sort((a, b) => parseInt(a.timestamp) - parseInt(b.timestamp));
  const nextMilestone = sortedMilestones?.find(
    (m) => parseInt(m.timestamp) > now
  );
  const allVested = sortedMilestones && sortedMilestones.length > 0 && !nextMilestone;

  const nextMilestoneBps = nextMilestone?.basisPoints ?? 0;

  const vestingStrictness = useMemo(
    () => sortedMilestones ? computeStrictnessLevel(sortedMilestones, createdAt, lockDuration) : null,
    [sortedMilestones, createdAt, lockDuration]
  );

  return (
    <div className="glass-card p-0 overflow-hidden">
      {/* Header */}
      <div className="px-6 pt-5 pb-4 flex items-center justify-between">
        <div className="flex items-center gap-3">
          <div className={`flex h-10 w-10 items-center justify-center rounded-xl ${
            escrow.isTriggered ? "bg-red-100" : "bg-emerald-100"
          }`}>
            <svg className={`h-5 w-5 ${escrow.isTriggered ? "text-red-600" : "text-emerald-600"}`} fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5}>
              <path strokeLinecap="round" strokeLinejoin="round" d="M16.5 10.5V6.75a4.5 4.5 0 10-9 0v3.75m-.75 11.25h10.5a2.25 2.25 0 002.25-2.25v-6.75a2.25 2.25 0 00-2.25-2.25H6.75a2.25 2.25 0 00-2.25 2.25v6.75a2.25 2.25 0 002.25 2.25z" />
            </svg>
          </div>
          <div>
            <h3 className="text-base font-semibold text-gray-900">Escrow Vault</h3>
            <p className="text-xs text-gray-400">LP lock & vesting</p>
          </div>
        </div>
        <div className="flex items-center gap-2">
          {!escrow.isTriggered && vestingStrictness && vestingStrictness !== "default" && (
            <span className={`text-[10px] font-medium px-2 py-0.5 rounded-full ${
              vestingStrictness === "stricter"
                ? "bg-emerald-50 text-emerald-700"
                : "bg-yellow-50 text-yellow-700"
            }`}>
              {vestingStrictness === "stricter" ? "Stricter than default" : `${
                sortedMilestones ? Math.round((parseInt(sortedMilestones[sortedMilestones.length - 1].timestamp) - createdAt) / 86400) : 0
              }d vesting`}
            </span>
          )}
          {escrow.isTriggered ? (
            <Badge variant="triggered">TRIGGERED</Badge>
          ) : allVested ? (
            <Badge variant="protected">Fully Vested</Badge>
          ) : (
            <Badge variant="protected">Active</Badge>
          )}
        </div>
      </div>

      {/* Triggered warning */}
      {escrow.isTriggered && (
        <div className="mx-6 mb-4 flex items-start gap-3 rounded-xl bg-red-50 border border-red-200 px-4 py-3">
          <svg className="h-5 w-5 text-red-500 shrink-0 mt-0.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
            <path strokeLinecap="round" strokeLinejoin="round" d="M12 9v3.75m-9.303 3.376c-.866 1.5.217 3.374 1.948 3.374h14.71c1.73 0 2.813-1.874 1.948-3.374L13.949 3.378c-.866-1.5-3.032-1.5-3.898 0L2.697 16.126zM12 15.75h.007v.008H12v-.008z" />
          </svg>
          <div>
            <p className="text-sm font-medium text-red-700">Trigger activated — LP Force Removed</p>
            <p className="text-xs text-red-600/70">
              Issuer LP has been force-removed and sent to the Insurance Pool for holder compensation.
            </p>
          </div>
        </div>
      )}

      {/* Progress bar + stats */}
      <div className="px-6 pb-4">
        {/* Big number */}
        <div className="flex items-end justify-between mb-4">
          <div>
            <p className="text-3xl font-bold text-gray-900 tabular-nums">{progress.toFixed(1)}%</p>
            <p className="text-xs text-gray-400 mt-0.5">vested so far</p>
          </div>
          {!escrow.isTriggered && nextMilestone && (
            <Countdown
              targetTs={parseInt(nextMilestone.timestamp)}
              label={`Next unlock: ${formatBps(nextMilestoneBps)} LP`}
            />
          )}
          {!escrow.isTriggered && allVested && (
            <div className="text-right">
              <div className="flex items-center gap-1.5 justify-end">
                <svg className="h-5 w-5 text-emerald-500" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                  <path strokeLinecap="round" strokeLinejoin="round" d="M9 12.75L11.25 15 15 9.75M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
                </svg>
                <span className="text-sm font-semibold text-emerald-600">All milestones reached</span>
              </div>
            </div>
          )}
        </div>

        {/* Stats grid */}
        <div className="grid grid-cols-3 gap-3 mb-1">
          {[
            {
              label: "Total LP Locked",
              val: formatCompact(total),
              pct: null as string | null,
              color: "text-gray-900",
              icon: "M12 15v2m-6 4h12a2 2 0 002-2v-6a2 2 0 00-2-2H6a2 2 0 00-2 2v6a2 2 0 002 2zm10-10V7a4 4 0 00-8 0v4h8z",
            },
            {
              label: "LP Removed",
              val: formatCompact(removed),
              pct: `${progress.toFixed(0)}%`,
              color: "text-emerald-600",
              icon: "M9 12.75L11.25 15 15 9.75M21 12a9 9 0 11-18 0 9 9 0 0118 0z",
            },
            {
              label: "LP Remaining",
              val: formatCompact(remaining),
              pct: `${(100 - progress).toFixed(0)}%`,
              color: "text-bastion-600",
              icon: "M12 6v6h4.5m4.5 0a9 9 0 11-18 0 9 9 0 0118 0z",
            },
          ].map(({ label, val, pct, color, icon }) => (
            <div key={label} className="rounded-xl bg-gray-50 p-3">
              <div className="flex items-center gap-1.5 mb-1">
                <svg className="h-3 w-3 text-gray-400" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                  <path strokeLinecap="round" strokeLinejoin="round" d={icon} />
                </svg>
                <p className="text-[11px] text-gray-400">{label}</p>
              </div>
              <p className={`text-sm font-bold ${color} tabular-nums leading-tight`}>
                {val} <span className="text-[10px] font-normal text-gray-400">LP</span>
              </p>
              {pct && <p className="text-[10px] text-gray-400 mt-0.5">{pct}</p>}
            </div>
          ))}
        </div>
      </div>

      {/* Full-width timeline */}
      {!escrow.isTriggered && sortedMilestones && sortedMilestones.length > 0 && createdAt > 0 && (
        <div className="border-t border-subtle bg-gray-50/50 px-6 py-5">
          <p className="text-[11px] font-medium text-gray-400 uppercase tracking-wider mb-1">
            Escrow Timeline
          </p>
          <VestingTimeline
            milestones={sortedMilestones}
            createdAt={createdAt}
            lockDuration={lockDuration}
            vestingEndTime={vestingEndTime}
            total={total}
          />
        </div>
      )}

      {/* Vesting Chart + Milestone list */}
      {!escrow.isTriggered && sortedMilestones && sortedMilestones.length > 0 && (
        <div className="border-t border-subtle px-6 py-4">
          <VestingChart
            milestones={sortedMilestones.map((m) => ({
              days: Math.round((parseInt(m.timestamp) - createdAt - lockDuration) / 86400),
              bps: m.basisPoints,
            }))}
            lockDays={Math.round(lockDuration / 86400)}
            defaultMilestones={[
              { days: 7, bps: 1000 },
              { days: 30, bps: 3000 },
              { days: 90, bps: 10000 },
            ]}
            defaultLockDays={90}
            label="This pool"
            height={160}
          />
          <MilestoneList milestones={sortedMilestones} total={total} />
        </div>
      )}

      {/* Fallback: vesting end time from chain if no milestones */}
      {!escrow.isTriggered && (!sortedMilestones || sortedMilestones.length === 0) && vestingEndTime && vestingEndTime > 0 && (
        <div className="border-t border-subtle px-6 py-4">
          <div className="flex items-center justify-between">
            <div>
              <p className="text-xs text-gray-400">Full Vesting</p>
              <p className="text-sm text-gray-600 mt-0.5">{formatDate(vestingEndTime)}</p>
            </div>
            <Countdown targetTs={vestingEndTime} />
          </div>
        </div>
      )}

      {/* Dates footer */}
      {createdAt > 0 && (
        <div className="border-t border-subtle px-6 py-3 flex items-center justify-between text-[11px] text-gray-400">
          <span>Created {formatDate(createdAt)}</span>
          {vestingEndTime && vestingEndTime > 0 && (
            <span>Ends {formatDate(vestingEndTime)}</span>
          )}
        </div>
      )}
    </div>
  );
}
