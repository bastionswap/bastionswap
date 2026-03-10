"use client";

import { useReadContract, useChainId } from "wagmi";
import { Badge } from "@/components/ui/Badge";
import { shortenAddress, explorerUrl, formatBps, formatDuration } from "@/lib/formatters";
import { getContracts } from "@/config/contracts";
import { ReputationEngineABI } from "@/config/abis";

interface PoolCommitmentData {
  lockDuration: number | bigint;
  vestingDuration: number | bigint;
  maxSingleLpRemovalBps: number | bigint;
  maxCumulativeLpRemovalBps: number | bigint;
  maxDailySellBps: number | bigint;
  weeklyDumpWindowSeconds: number | bigint;
  weeklyDumpThresholdBps: number | bigint;
  createdAt: number | bigint;
  isSet: boolean;
}

interface TriggerConfigData {
  lpRemovalThreshold: number | bigint;
  dumpThresholdPercent: number | bigint;
  dumpWindowSeconds: number | bigint;
  taxDeviationThreshold: number | bigint;
  slowRugWindowSeconds: number | bigint;
  slowRugCumulativeThreshold: number | bigint;
  weeklyDumpWindowSeconds: number | bigint;
  weeklyDumpThresholdPercent: number | bigint;
}

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
    maxSellPercent: string;
  } | null;
  lockDuration?: number;
  vestingDuration?: number;
  vestingStrictness?: "stricter" | "default" | "looser" | null;
  poolCommitment?: PoolCommitmentData;
  isStricterThanDefault?: boolean;
  triggerConfig?: TriggerConfigData;
}

const DEFAULTS = {
  dailyWithdrawLimit: 500,
  totalDuration: 7_776_000, // 90 days default
  maxSellPercent: 300,
};

function SemiCircleGauge({ score }: { score: number }) {
  const pct = Math.min(score / 1000, 1);
  let color: string;
  let label: string;
  if (score < 200) { color = "#DC2626"; label = "Low"; }
  else if (score < 500) { color = "#D97706"; label = "Medium"; }
  else if (score < 800) { color = "#059669"; label = "Good"; }
  else { color = "#10B981"; label = "Excellent"; }

  const r = 50;
  const c = Math.PI * r;
  const offset = c - pct * c;

  return (
    <div className="relative mx-auto h-24 w-40">
      <svg className="h-full w-full" viewBox="0 0 120 70">
        <path
          d="M 10 65 A 50 50 0 0 1 110 65"
          fill="none" stroke="#E2E8F0" strokeWidth="8" strokeLinecap="round"
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
        <span className="text-2xl font-bold" style={{ color }}>{score}</span>
        <p className="text-[10px] text-gray-400">{label}</p>
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
    return <span className="text-[10px] text-gray-400 ml-1.5 px-1.5 py-0.5 rounded bg-gray-100">Default</span>;
  }
  if (isStricter) {
    return (
      <span className="text-[10px] text-emerald-600 ml-1.5 flex items-center gap-0.5 px-1.5 py-0.5 rounded bg-emerald-50">
        <svg className="h-3 w-3" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
          <path strokeLinecap="round" strokeLinejoin="round" d="M5 13l4 4L19 7" />
        </svg>
        Strict
      </span>
    );
  }
  return <span className="text-[10px] text-amber-600 ml-1.5 px-1.5 py-0.5 rounded bg-amber-50">Relaxed</span>;
}

function ScoreBreakdown({ issuerAddress }: { issuerAddress: string }) {
  const chainId = useChainId();
  const contracts = getContracts(chainId);

  const { data: encodedData } = useReadContract({
    address: contracts?.ReputationEngine as `0x${string}`,
    abi: ReputationEngineABI,
    functionName: "encodeScoreData",
    args: [issuerAddress as `0x${string}`],
    query: { enabled: !!contracts },
  });

  const { data: decoded } = useReadContract({
    address: contracts?.ReputationEngine as `0x${string}`,
    abi: ReputationEngineABI,
    functionName: "decodeScoreData",
    args: encodedData ? [encodedData as `0x${string}`] : undefined,
    query: { enabled: !!encodedData },
  });

  if (!decoded) return null;

  const [, poolsCreated, escrowsCompleted, triggerCount] = decoded as [
    bigint, number, number, number
  ];

  return (
    <div className="mt-3 space-y-1.5">
      <p className="text-[10px] text-gray-400 uppercase tracking-wider">Score Components</p>
      {[
        { label: "Pools Created", value: poolsCreated },
        { label: "Escrows Completed", value: escrowsCompleted },
        { label: "Triggers", value: triggerCount, negative: true },
      ].map(({ label, value, negative }) => (
        <div key={label} className="flex items-center justify-between text-[11px]">
          <span className="text-gray-400">{label}</span>
          <span className={negative && value > 0 ? "text-red-600 font-medium" : "text-gray-600"}>
            {value}
          </span>
        </div>
      ))}
    </div>
  );
}

export function IssuerInfo({ issuer, commitment, lockDuration, vestingDuration, vestingStrictness, poolCommitment, isStricterThanDefault, triggerConfig }: IssuerInfoProps) {
  const score = parseInt(issuer.reputationScore);
  const created = issuer.totalEscrowsCreated ?? 0;
  const completed = issuer.totalEscrowsCompleted ?? 0;
  const triggers = issuer.totalTriggersActivated ?? 0;
  const successRate = created > 0 ? ((completed / created) * 100).toFixed(0) : "—";

  return (
    <div className="glass-card p-0 overflow-hidden">
      {/* Header */}
      <div className="px-6 pt-5 pb-4 flex items-center justify-between">
        <div className="flex items-center gap-3">
          <div className="flex h-10 w-10 items-center justify-center rounded-xl bg-bastion-50">
            <svg className="h-5 w-5 text-bastion-600" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5}>
              <path strokeLinecap="round" strokeLinejoin="round" d="M15.75 6a3.75 3.75 0 11-7.5 0 3.75 3.75 0 017.5 0zM4.501 20.118a7.5 7.5 0 0114.998 0A17.933 17.933 0 0112 21.75c-2.676 0-5.216-.584-7.499-1.632z" />
            </svg>
          </div>
          <div>
            <h3 className="text-base font-semibold text-gray-900">Issuer Profile</h3>
            <a
              href={explorerUrl(issuer.id)}
              target="_blank"
              rel="noopener noreferrer"
              className="text-xs text-bastion-600 hover:text-bastion-700 transition-colors"
            >
              {shortenAddress(issuer.id)} &#8599;
            </a>
          </div>
        </div>
      </div>

      {/* Reputation Gauge */}
      <div className="px-6 pb-4">
        <SemiCircleGauge score={score} />
        <ScoreBreakdown issuerAddress={issuer.id} />
      </div>

      {/* History Grid */}
      <div className="border-t border-subtle px-6 py-4">
        <div className="grid grid-cols-4 gap-2">
          {[
            { label: "Created", value: created, color: "text-gray-900" },
            { label: "Completed", value: completed, color: "text-emerald-600" },
            { label: "Triggers", value: triggers, color: "text-red-600" },
            { label: "Success", value: `${successRate}%`, color: "text-bastion-600" },
          ].map(({ label, value, color }) => (
            <div key={label} className="rounded-xl bg-gray-50 p-2.5 text-center">
              <p className={`text-base font-semibold ${color} tabular-nums`}>{value}</p>
              <p className="text-[10px] text-gray-400">{label}</p>
            </div>
          ))}
        </div>
      </div>

      {/* Commitment Parameters */}
      {(commitment || poolCommitment?.isSet) ? (
        <div className="border-t border-subtle px-6 py-4">
          <p className="text-[11px] font-medium text-gray-400 uppercase tracking-wider mb-3">Commitments</p>
          <div className="space-y-2.5">
            {vestingStrictness && (
              <div className="flex items-center justify-between text-sm">
                <span className="text-gray-400">Vesting Schedule</span>
                <span className={`text-xs font-medium px-2 py-0.5 rounded-full ${
                  vestingStrictness === "stricter"
                    ? "bg-emerald-50 text-emerald-700"
                    : vestingStrictness === "default"
                      ? "bg-gray-100 text-gray-600"
                      : "bg-yellow-50 text-yellow-700"
                }`}>
                  {vestingStrictness === "stricter" ? "Stricter" : vestingStrictness === "default" ? "Default" : "Below default"}
                </span>
              </div>
            )}
            {[
              ...(commitment ? [
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
              ] : []),
              {
                label: "Total Duration",
                value: formatDuration(
                  poolCommitment?.isSet
                    ? Number(poolCommitment.lockDuration) + Number(poolCommitment.vestingDuration)
                    : (lockDuration ?? 0) + (vestingDuration ?? 0)
                ),
                raw: poolCommitment?.isSet
                  ? Number(poolCommitment.lockDuration) + Number(poolCommitment.vestingDuration)
                  : (lockDuration ?? 0) + (vestingDuration ?? 0),
                default_: DEFAULTS.totalDuration,
                lowerBetter: false,
              },
            ].map(({ label, value, raw, default_, lowerBetter }) => (
              <div key={label} className="flex items-center justify-between text-sm">
                <span className="text-gray-400">{label}</span>
                <div className="flex items-center">
                  <span className="font-medium text-gray-900 tabular-nums">{value}</span>
                  <CommitmentTag
                    value={raw}
                    defaultValue={default_}
                    isLowerBetter={lowerBetter}
                  />
                </div>
              </div>
            ))}
            {/* Trigger Detection Thresholds from TriggerOracle */}
            {triggerConfig && (
              <>
                <div className="my-2 border-t border-gray-100" />
                <p className="text-[10px] text-gray-400 uppercase tracking-wider mb-1">Trigger Thresholds</p>
                {[
                  {
                    label: "Max LP Removal / tx",
                    value: formatBps(Number(triggerConfig.lpRemovalThreshold)),
                    raw: Number(triggerConfig.lpRemovalThreshold),
                    default_: 5000,
                    lowerBetter: true,
                  },
                  {
                    label: "Max Issuer Sell",
                    value: formatBps(Number(triggerConfig.dumpThresholdPercent)),
                    raw: Number(triggerConfig.dumpThresholdPercent),
                    default_: 3000,
                    lowerBetter: true,
                  },
                  {
                    label: "Sell Window",
                    value: formatDuration(Number(triggerConfig.dumpWindowSeconds)),
                    raw: Number(triggerConfig.dumpWindowSeconds),
                    default_: 86400,
                    lowerBetter: false,
                  },
                  {
                    label: "Hidden Tax Threshold",
                    value: formatBps(Number(triggerConfig.taxDeviationThreshold)),
                    raw: Number(triggerConfig.taxDeviationThreshold),
                    default_: 500,
                    lowerBetter: true,
                  },
                  {
                    label: "Cumulative LP Removal",
                    value: formatBps(Number(triggerConfig.slowRugCumulativeThreshold)),
                    raw: Number(triggerConfig.slowRugCumulativeThreshold),
                    default_: 8000,
                    lowerBetter: true,
                  },
                  {
                    label: "LP Removal Window",
                    value: formatDuration(Number(triggerConfig.slowRugWindowSeconds)),
                    raw: Number(triggerConfig.slowRugWindowSeconds),
                    default_: 86400,
                    lowerBetter: false,
                  },
                  {
                    label: "Weekly Issuer Sell",
                    value: formatBps(Number(triggerConfig.weeklyDumpThresholdPercent)),
                    raw: Number(triggerConfig.weeklyDumpThresholdPercent),
                    default_: 5000,
                    lowerBetter: true,
                  },
                  {
                    label: "Weekly Sell Window",
                    value: formatDuration(Number(triggerConfig.weeklyDumpWindowSeconds)),
                    raw: Number(triggerConfig.weeklyDumpWindowSeconds),
                    default_: 604800,
                    lowerBetter: false,
                  },
                ].map(({ label, value, raw, default_, lowerBetter }) => (
                  <div key={label} className="flex items-center justify-between text-sm">
                    <span className="text-gray-400">{label}</span>
                    <div className="flex items-center">
                      <span className="font-medium text-gray-900 tabular-nums">{value}</span>
                      <CommitmentTag
                        value={raw}
                        defaultValue={default_}
                        isLowerBetter={lowerBetter}
                      />
                    </div>
                  </div>
                ))}
              </>
            )}
            {/* Stricter than default badge */}
            {isStricterThanDefault && (
              <div className="mt-2 flex items-center gap-1.5 rounded-lg bg-emerald-50 px-3 py-1.5">
                <svg className="h-4 w-4 text-emerald-600" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                  <path strokeLinecap="round" strokeLinejoin="round" d="M9 12.75L11.25 15 15 9.75m-1.5-8.25a48.109 48.109 0 011.913-.247C12.735 2.16 14.335 3 16.34 4.37c1.406.96 2.86 2.195 3.66 3.288V19.5a2.25 2.25 0 01-2.25 2.25H6.25A2.25 2.25 0 014 19.5V7.658c.8-1.093 2.254-2.328 3.66-3.288C9.665 3 11.265 2.16 12.587 2.253z" />
                </svg>
                <span className="text-xs font-medium text-emerald-700">Stricter than defaults</span>
              </div>
            )}
            {/* Immutable creation timestamp */}
            {poolCommitment?.isSet && Number(poolCommitment.createdAt) > 0 && (
              <div className="mt-1 text-[10px] text-gray-400 flex items-center gap-1">
                <svg className="h-3 w-3" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                  <path strokeLinecap="round" strokeLinejoin="round" d="M12 6v6h4.5m4.5 0a9 9 0 11-18 0 9 9 0 0118 0z" />
                </svg>
                Set on {new Date(Number(poolCommitment.createdAt) * 1000).toLocaleDateString()} (immutable)
              </div>
            )}
          </div>
        </div>
      ) : (
        <div className="border-t border-subtle px-6 py-4">
          <p className="text-[11px] font-medium text-gray-400 uppercase tracking-wider mb-2">Commitments</p>
          <p className="text-xs text-gray-400">Using default parameters</p>
        </div>
      )}
    </div>
  );
}
