"use client";

import { useEffect, useState, useMemo } from "react";
import { Badge } from "@/components/ui/Badge";
import { VestingChart } from "@/components/ui/VestingChart";

interface EscrowStatusProps {
  escrow: {
    totalLiquidity: string;
    removedLiquidity: string;
    remainingLiquidity: string;
    isTriggered: boolean;
    createdAt?: string;
    lockDuration?: string;
    vestingDuration?: string;
    commitment?: {
      dailyWithdrawLimit: string;
      maxSellPercent: string;
    } | null;
  };
  tokenLabel?: string;
  tokenSymbol?: string;
  vestingEndTime?: number;
  /** Compact mode for sidebar display — hides VestingChart, uses smaller stats grid */
  compact?: boolean;
}

const DEFAULT_TOTAL_DAYS = 90;

function computeStrictnessLevel(
  lockDuration: number,
  vestingDuration: number
): "stricter" | "default" | "looser" | null {
  if (lockDuration === 0 && vestingDuration === 0) return null;
  const totalDays = Math.round((lockDuration + vestingDuration) / 86400);
  if (totalDays < DEFAULT_TOTAL_DAYS) return "looser";
  if (totalDays === DEFAULT_TOTAL_DAYS) return "default";
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
  if (n >= 1) return n.toFixed(4);
  return n.toFixed(6);
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

/* ── Full-width Linear Vesting Timeline ── */
function VestingTimeline({
  createdAt,
  lockDuration,
  vestingDuration,
  vestingEndTime,
}: {
  createdAt: number;
  lockDuration: number;
  vestingDuration: number;
  vestingEndTime?: number;
}) {
  const [now, setNow] = useState(Math.floor(Date.now() / 1000));
  useEffect(() => {
    const id = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 60_000);
    return () => clearInterval(id);
  }, []);

  const startTs = createdAt;
  const lockEndTs = createdAt + lockDuration;
  const endTs = vestingEndTime && vestingEndTime > 0
    ? vestingEndTime
    : createdAt + lockDuration + vestingDuration;
  const range = endTs - startTs;
  if (range <= 0) return null;

  const toPct = (ts: number) => Math.min(Math.max(((ts - startTs) / range) * 100, 0), 100);
  const currentPct = toPct(now);
  const lockPct = toPct(lockEndTs);
  const isLocked = now < lockEndTs;

  const phases: { label: string; color: string; bgColor: string; start: number; end: number; active: boolean }[] = [];
  if (lockDuration > 0) {
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
    label: "Linear Vesting",
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
        {lockDuration > 0 && lockPct > 15 && lockPct < 85 && (
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

export function EscrowStatus({ escrow, vestingEndTime, compact }: EscrowStatusProps) {
  const total = parseFloat(escrow.totalLiquidity);
  const removed = parseFloat(escrow.removedLiquidity);
  const remaining = parseFloat(escrow.remainingLiquidity);
  const progress = total > 0 ? (removed / total) * 100 : 0;

  const now = Math.floor(Date.now() / 1000);
  const createdAt = escrow.createdAt ? parseInt(escrow.createdAt) : 0;
  const lockDuration = escrow.lockDuration ? parseInt(escrow.lockDuration) : 0;
  const vestingDuration = escrow.vestingDuration ? parseInt(escrow.vestingDuration) : 0;
  const totalDuration = lockDuration + vestingDuration;

  const lockEndTs = createdAt + lockDuration;
  const vestEndTs = createdAt + totalDuration;
  const isLocked = now < lockEndTs;
  const allVested = now >= vestEndTs && createdAt > 0;

  const vestingStrictness = useMemo(
    () => computeStrictnessLevel(lockDuration, vestingDuration),
    [lockDuration, vestingDuration]
  );

  const lockDays = Math.round(lockDuration / 86400);
  const vestingDays = Math.round(vestingDuration / 86400);

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
            <p className="text-xs text-gray-400">LP lock & linear vesting</p>
          </div>
        </div>
        <div className="flex items-center gap-2">
          {!escrow.isTriggered && vestingStrictness && vestingStrictness !== "default" && (
            <span className={`text-[10px] font-medium px-2 py-0.5 rounded-full ${
              vestingStrictness === "stricter"
                ? "bg-emerald-50 text-emerald-700"
                : "bg-yellow-50 text-yellow-700"
            }`}>
              {vestingStrictness === "stricter"
                ? "Stricter than default"
                : `${lockDays + vestingDays}d vesting`}
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
        <div className={`flex items-end justify-between mb-4 ${compact ? "flex-wrap gap-3" : ""}`}>
          <div>
            <p className={`font-bold text-gray-900 tabular-nums ${compact ? "text-2xl" : "text-3xl"}`}>{progress.toFixed(1)}%</p>
            <p className="text-xs text-gray-400 mt-0.5">vested so far</p>
          </div>
          {!escrow.isTriggered && !allVested && isLocked && (
            <Countdown
              targetTs={lockEndTs}
              label="Lock ends in"
            />
          )}
          {!escrow.isTriggered && !allVested && !isLocked && (
            <Countdown
              targetTs={vestEndTs}
              label="Fully vested in"
            />
          )}
          {!escrow.isTriggered && allVested && (
            <div className="text-right">
              <div className="flex items-center gap-1.5 justify-end">
                <svg className="h-5 w-5 text-emerald-500" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                  <path strokeLinecap="round" strokeLinejoin="round" d="M9 12.75L11.25 15 15 9.75M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
                </svg>
                <span className="text-sm font-semibold text-emerald-600">Fully vested</span>
              </div>
            </div>
          )}
        </div>

        {/* Stats grid */}
        <div className={`grid gap-3 mb-1 ${compact ? "grid-cols-2" : "grid-cols-3"}`}>
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
      {!escrow.isTriggered && createdAt > 0 && totalDuration > 0 && (
        <div className="border-t border-subtle bg-gray-50/50 px-6 py-5">
          <p className="text-[11px] font-medium text-gray-400 uppercase tracking-wider mb-1">
            Escrow Timeline
          </p>
          <VestingTimeline
            createdAt={createdAt}
            lockDuration={lockDuration}
            vestingDuration={vestingDuration}
            vestingEndTime={vestingEndTime}
          />
        </div>
      )}

      {/* Vesting Chart + Summary */}
      {!escrow.isTriggered && totalDuration > 0 && (
        <div className="border-t border-subtle px-6 py-4">
          <VestingChart
            lockDays={lockDays}
            vestingDays={vestingDays}
            defaultLockDays={7}
            defaultVestingDays={83}
            label="This pool"
            height={compact ? 100 : 160}
          />
          {/* Vesting summary */}
          <div className={compact ? "mt-3" : "mt-5"}>
            {!compact && (
              <p className="text-[11px] font-medium text-gray-400 uppercase tracking-wider mb-3">
                Vesting Schedule
              </p>
            )}
            <div className={compact ? "flex items-center gap-4 text-xs text-gray-500" : "space-y-2"}>
              {compact ? (
                <>
                  <div className="flex items-center gap-1.5">
                    <div className="h-2 w-2 rounded-sm bg-amber-400/60" />
                    <span>Lock {lockDays}d</span>
                  </div>
                  <div className="flex items-center gap-1.5">
                    <div className="h-2 w-2 rounded-sm bg-emerald-400/50" />
                    <span>Vest {vestingDays}d</span>
                  </div>
                  <span className="font-medium text-gray-700">= {lockDays + vestingDays}d</span>
                </>
              ) : (
                <>
                  <div className="flex items-center justify-between text-sm">
                    <div className="flex items-center gap-2">
                      <div className="h-2.5 w-2.5 rounded-sm bg-amber-400/60" />
                      <span className="text-gray-600">Lock period</span>
                    </div>
                    <span className="font-medium text-gray-900 tabular-nums">{lockDays} days</span>
                  </div>
                  <div className="flex items-center justify-between text-sm">
                    <div className="flex items-center gap-2">
                      <div className="h-2.5 w-2.5 rounded-sm bg-emerald-400/50" />
                      <span className="text-gray-600">Linear vesting</span>
                    </div>
                    <span className="font-medium text-gray-900 tabular-nums">{vestingDays} days</span>
                  </div>
                  <div className="flex items-center justify-between text-sm pt-1 border-t border-gray-200">
                    <span className="text-gray-600 font-medium">Total duration</span>
                    <span className="font-semibold text-gray-900 tabular-nums">{lockDays + vestingDays} days</span>
                  </div>
                </>
              )}
            </div>
          </div>
        </div>
      )}

      {/* Fallback: vesting end time from chain if no durations */}
      {!escrow.isTriggered && totalDuration === 0 && vestingEndTime && vestingEndTime > 0 && (
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
