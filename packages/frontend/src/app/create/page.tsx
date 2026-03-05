"use client";

import { useState, useMemo } from "react";
import { useAccount, useChainId } from "wagmi";
import { ConnectKitButton } from "connectkit";
import { Card } from "@/components/ui/Card";
import { Badge } from "@/components/ui/Badge";
import { useCreateBastionPool } from "@/hooks/useCreatePool";
import { LoadingSpinner } from "@/components/ui/LoadingSpinner";
import { formatBps, formatDuration } from "@/lib/formatters";
import { getContracts } from "@/config/contracts";
import { PoolManagerABI } from "@/config/abis";

type Step = 1 | 2 | 3 | 4;

const SQRT_PRICE_1_1 = 79228162514264337593543950336n;

const DEFAULT_COMMITMENT = {
  dailyWithdrawLimit: 500, // 5% in bps
  lockDuration: 7776000, // 90 days in seconds
  maxSellPercent: 300, // 3% in bps
};

// Vesting schedule types and presets
type VestingMode = "standard" | "quick" | "extended" | "custom";

interface Milestone {
  days: number;
  bps: number;
}

const VESTING_PRESETS: Record<Exclude<VestingMode, "custom">, Milestone[]> = {
  standard: [
    { days: 7, bps: 1000 },
    { days: 30, bps: 3000 },
    { days: 90, bps: 10000 },
  ],
  quick: [
    { days: 7, bps: 3000 },
    { days: 30, bps: 10000 },
  ],
  extended: [
    { days: 14, bps: 500 },
    { days: 60, bps: 2000 },
    { days: 180, bps: 10000 },
  ],
};

// Default milestones for strictness comparison
const DEFAULT_MILESTONES = [
  { time: 7, bps: 1000 },
  { time: 30, bps: 3000 },
  { time: 90, bps: 10000 },
];

function computeStrictnessLevel(
  milestones: Milestone[]
): "stricter" | "default" | "looser" | "invalid" {
  if (milestones.length === 0) return "invalid";
  const last = milestones[milestones.length - 1];
  if (last.days < 7) return "invalid";
  if (last.bps !== 10000) return "invalid";

  // Check total duration >= 90 days
  if (last.days < 90) return "looser";

  // Check at each default milestone time point
  const getBpsAtTime = (time: number): number => {
    let bps = 0;
    for (const m of milestones) {
      if (m.days <= time) bps = m.bps;
      else break;
    }
    return bps;
  };

  let allSameOrStricter = true;
  let allSame = true;

  for (const def of DEFAULT_MILESTONES) {
    const customBps = getBpsAtTime(def.time);
    if (customBps > def.bps) return "looser";
    if (customBps < def.bps) allSame = false;
    if (customBps !== def.bps) allSameOrStricter = true;
  }

  if (allSame && last.days === 90) return "default";
  return "stricter";
}

const STEP_LABELS = ["Token", "Liquidity", "Commitment", "Confirm"];

export default function CreatePoolPage() {
  const { isConnected, address } = useAccount();
  const [step, setStep] = useState<Step>(1);
  const [tokenAddress, setTokenAddress] = useState("");
  const [ethAmount, setEthAmount] = useState("");
  const [tokenAmount, setTokenAmount] = useState("");
  const [commitment, setCommitment] = useState(DEFAULT_COMMITMENT);
  const [vestingMode, setVestingMode] = useState<VestingMode>("standard");
  const [customMilestones, setCustomMilestones] = useState<Milestone[]>([
    { days: 7, bps: 1000 },
    { days: 30, bps: 3000 },
    { days: 90, bps: 10000 },
  ]);

  const activeMilestones = vestingMode === "custom" ? customMilestones : VESTING_PRESETS[vestingMode];

  const strictness = useMemo(() => computeStrictnessLevel(activeMilestones), [activeMilestones]);

  const isVestingValid = useMemo(() => {
    if (activeMilestones.length === 0) return false;
    const last = activeMilestones[activeMilestones.length - 1];
    if (last.days < 7 || last.bps !== 10000) return false;
    for (let i = 1; i < activeMilestones.length; i++) {
      if (activeMilestones[i].days <= activeMilestones[i - 1].days) return false;
      if (activeMilestones[i].bps <= activeMilestones[i - 1].bps) return false;
    }
    return true;
  }, [activeMilestones]);
  const { createPool, isWriting, isConfirming, isSuccess, hash, error } =
    useCreateBastionPool();
  const chainId = useChainId();
  const contracts = getContracts(chainId);

  const handleCreatePool = () => {
    if (!contracts || !address) return;
    const hookAddr = contracts.BastionHook as `0x${string}`;
    const tokenAddr = tokenAddress as `0x${string}`;
    const weth = "0x4200000000000000000000000000000000000006" as `0x${string}`;
    const [currency0, currency1] =
      tokenAddr.toLowerCase() < weth.toLowerCase()
        ? [tokenAddr, weth]
        : [weth, tokenAddr];

    createPool({
      address: contracts.PoolManager as `0x${string}`,
      abi: PoolManagerABI,
      functionName: "initialize",
      args: [
        {
          currency0,
          currency1,
          fee: 3000,
          tickSpacing: 60,
          hooks: hookAddr,
        },
        SQRT_PRICE_1_1,
      ],
    });
  };

  const trustLevel =
    commitment.lockDuration >= 7776000 && commitment.maxSellPercent <= 300
      ? "High"
      : commitment.lockDuration >= 2592000
        ? "Medium"
        : "Low";
  const trustColor =
    trustLevel === "High"
      ? "text-emerald-600"
      : trustLevel === "Medium"
        ? "text-yellow-600"
        : "text-red-600";

  if (!isConnected) {
    return (
      <div className="mx-auto max-w-xl py-16 text-center">
        <div className="mx-auto mb-6 flex h-16 w-16 items-center justify-center rounded-2xl bg-bastion-50">
          <svg className="h-8 w-8 text-bastion-600" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5}>
            <path strokeLinecap="round" strokeLinejoin="round" d="M12 4.5v15m7.5-7.5h-15" />
          </svg>
        </div>
        <h1 className="text-2xl font-bold text-gray-900 sm:text-3xl mb-3">Create Bastion Pool</h1>
        <p className="text-gray-500 mb-8 max-w-sm mx-auto">
          Launch a protected pool with escrow, insurance, and rug-pull triggers. Connect your wallet to get started.
        </p>
        <ConnectKitButton />
      </div>
    );
  }

  return (
    <div className="mx-auto max-w-xl">
      {/* Page Header */}
      <div className="mb-8 text-center">
        <h1 className="text-2xl font-bold text-gray-900 sm:text-3xl">Create Bastion Pool</h1>
        <p className="mt-2 text-sm text-gray-500">
          Set up protection parameters for your token launch
        </p>
      </div>

      {/* Step Indicators with Labels */}
      <div className="mb-10">
        <div className="flex items-center justify-between">
          {[1, 2, 3, 4].map((s) => (
            <div key={s} className="flex flex-col items-center gap-2 flex-1">
              <div className="flex items-center w-full">
                {s > 1 && (
                  <div className={`h-0.5 flex-1 ${step >= s ? "bg-bastion-600" : "bg-gray-200"}`} />
                )}
                <div
                  className={`flex h-10 w-10 shrink-0 items-center justify-center rounded-full text-sm font-semibold transition-all ${
                    step > s
                      ? "bg-bastion-600 text-white"
                      : step === s
                        ? "bg-bastion-600 text-white ring-4 ring-bastion-100"
                        : "bg-gray-100 text-gray-400"
                  }`}
                >
                  {step > s ? (
                    <svg className="h-5 w-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2.5}>
                      <path strokeLinecap="round" strokeLinejoin="round" d="M5 13l4 4L19 7" />
                    </svg>
                  ) : (
                    s
                  )}
                </div>
                {s < 4 && (
                  <div className={`h-0.5 flex-1 ${step > s ? "bg-bastion-600" : "bg-gray-200"}`} />
                )}
              </div>
              <span className={`text-xs font-medium ${step >= s ? "text-bastion-600" : "text-gray-400"}`}>
                {STEP_LABELS[s - 1]}
              </span>
            </div>
          ))}
        </div>
      </div>

      {/* Step 1: Token Selection */}
      {step === 1 && (
        <Card>
          <div className="flex items-center gap-3 mb-5">
            <div className="flex h-10 w-10 items-center justify-center rounded-xl bg-bastion-50">
              <svg className="h-5 w-5 text-bastion-600" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M21 21l-5.197-5.197m0 0A7.5 7.5 0 105.196 5.196a7.5 7.5 0 0010.607 10.607z" />
              </svg>
            </div>
            <div>
              <h2 className="text-lg font-semibold text-gray-900">Select Token</h2>
              <p className="text-sm text-gray-500">
                Enter the contract address of your token
              </p>
            </div>
          </div>
          <input
            type="text"
            value={tokenAddress}
            onChange={(e) => setTokenAddress(e.target.value)}
            placeholder="0x..."
            className="input-base font-mono text-sm"
          />
          <button
            onClick={() => setStep(2)}
            disabled={!/^0x[a-fA-F0-9]{40}$/.test(tokenAddress)}
            className="btn-primary mt-5 w-full py-3.5 text-base"
          >
            Continue
          </button>
        </Card>
      )}

      {/* Step 2: Liquidity */}
      {step === 2 && (
        <Card>
          <div className="flex items-center gap-3 mb-5">
            <div className="flex h-10 w-10 items-center justify-center rounded-xl bg-emerald-50">
              <svg className="h-5 w-5 text-emerald-600" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M12 6v12m-3-2.818l.879.659c1.171.879 3.07.879 4.242 0 1.172-.879 1.172-2.303 0-3.182C13.536 12.219 12.768 12 12 12c-.725 0-1.45-.22-2.003-.659-1.106-.879-1.106-2.303 0-3.182s2.9-.879 4.006 0l.415.33M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
              </svg>
            </div>
            <div>
              <h2 className="text-lg font-semibold text-gray-900">Initial Liquidity</h2>
              <p className="text-sm text-gray-500">
                Set the initial token and ETH amounts
              </p>
            </div>
          </div>
          <div className="space-y-4">
            <div>
              <label className="text-sm font-medium text-gray-700 mb-1.5 block">Token Amount</label>
              <input
                type="number"
                value={tokenAmount}
                onChange={(e) => setTokenAmount(e.target.value)}
                placeholder="0"
                className="input-base text-lg"
              />
            </div>
            <div>
              <label className="text-sm font-medium text-gray-700 mb-1.5 block">ETH Amount</label>
              <input
                type="number"
                value={ethAmount}
                onChange={(e) => setEthAmount(e.target.value)}
                placeholder="0"
                className="input-base text-lg"
              />
            </div>
          </div>
          <div className="mt-5 flex gap-3">
            <button
              onClick={() => setStep(1)}
              className="btn-secondary flex-1 py-3.5"
            >
              Back
            </button>
            <button
              onClick={() => setStep(3)}
              disabled={!ethAmount || !tokenAmount}
              className="btn-primary flex-1 py-3.5 disabled:opacity-40"
            >
              Continue
            </button>
          </div>
        </Card>
      )}

      {/* Step 3: Vesting & Commitment */}
      {step === 3 && (
        <div className="space-y-4">
          {/* Vesting Schedule Card */}
          <Card>
            <div className="flex items-center justify-between mb-5">
              <div className="flex items-center gap-3">
                <div className="flex h-10 w-10 items-center justify-center rounded-xl bg-violet-50">
                  <svg className="h-5 w-5 text-violet-600" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5}>
                    <path strokeLinecap="round" strokeLinejoin="round" d="M12 6v6h4.5m4.5 0a9 9 0 11-18 0 9 9 0 0118 0z" />
                  </svg>
                </div>
                <div>
                  <h2 className="text-lg font-semibold text-gray-900">Vesting Schedule</h2>
                  <p className="text-sm text-gray-500">Define how tokens unlock over time</p>
                </div>
              </div>
            </div>

            {/* Preset Buttons */}
            <div className="grid grid-cols-4 gap-2 mb-5">
              {([
                { mode: "standard" as const, label: "Standard", desc: "90 days" },
                { mode: "quick" as const, label: "Quick", desc: "30 days" },
                { mode: "extended" as const, label: "Extended", desc: "180 days" },
                { mode: "custom" as const, label: "Custom", desc: "Your rules" },
              ]).map(({ mode, label, desc }) => (
                <button
                  key={mode}
                  onClick={() => {
                    setVestingMode(mode);
                    if (mode !== "custom") {
                      setCustomMilestones(VESTING_PRESETS[mode]);
                    }
                  }}
                  className={`rounded-xl border px-3 py-2.5 text-center transition-all ${
                    vestingMode === mode
                      ? "border-bastion-600 bg-bastion-50 ring-1 ring-bastion-600"
                      : "border-gray-200 hover:border-gray-300"
                  }`}
                >
                  <p className={`text-sm font-medium ${vestingMode === mode ? "text-bastion-700" : "text-gray-700"}`}>{label}</p>
                  <p className="text-[11px] text-gray-400">{desc}</p>
                </button>
              ))}
            </div>

            {/* Custom Milestone Editor */}
            {vestingMode === "custom" && (
              <div className="space-y-3 mb-4">
                <div className="flex items-center gap-2 text-[11px] text-gray-400 uppercase tracking-wider font-medium px-1">
                  <span className="flex-1">Day</span>
                  <span className="flex-1">Percentage</span>
                  <span className="w-8" />
                </div>
                {customMilestones.map((m, i) => (
                  <div key={i} className="flex items-center gap-2">
                    <div className="flex-1">
                      <input
                        type="number"
                        min={1}
                        value={m.days}
                        onChange={(e) => {
                          const newMs = [...customMilestones];
                          newMs[i] = { ...newMs[i], days: parseInt(e.target.value) || 0 };
                          setCustomMilestones(newMs);
                        }}
                        className="input-base text-sm tabular-nums"
                        placeholder="Days"
                      />
                    </div>
                    <div className="flex-1">
                      <div className="relative">
                        <input
                          type="number"
                          min={1}
                          max={100}
                          value={m.bps / 100}
                          onChange={(e) => {
                            const newMs = [...customMilestones];
                            const pct = Math.min(100, Math.max(0, parseInt(e.target.value) || 0));
                            newMs[i] = { ...newMs[i], bps: pct * 100 };
                            setCustomMilestones(newMs);
                          }}
                          className="input-base text-sm tabular-nums pr-8"
                          placeholder="%"
                        />
                        <span className="absolute right-3 top-1/2 -translate-y-1/2 text-gray-400 text-sm">%</span>
                      </div>
                    </div>
                    <button
                      onClick={() => {
                        if (customMilestones.length > 1) {
                          setCustomMilestones(customMilestones.filter((_, j) => j !== i));
                        }
                      }}
                      disabled={customMilestones.length <= 1}
                      className="w-8 h-8 flex items-center justify-center rounded-lg text-gray-400 hover:text-red-500 hover:bg-red-50 transition-colors disabled:opacity-30"
                    >
                      <svg className="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                        <path strokeLinecap="round" strokeLinejoin="round" d="M6 18L18 6M6 6l12 12" />
                      </svg>
                    </button>
                  </div>
                ))}
                {customMilestones.length < 10 && (
                  <button
                    onClick={() => {
                      const lastDay = customMilestones.length > 0 ? customMilestones[customMilestones.length - 1].days : 0;
                      const lastBps = customMilestones.length > 0 ? customMilestones[customMilestones.length - 1].bps : 0;
                      setCustomMilestones([
                        ...customMilestones,
                        { days: lastDay + 30, bps: Math.min(10000, lastBps + 2000) },
                      ]);
                    }}
                    className="w-full rounded-xl border border-dashed border-gray-300 py-2.5 text-sm text-gray-500 hover:border-bastion-400 hover:text-bastion-600 transition-colors"
                  >
                    + Add Milestone
                  </button>
                )}
              </div>
            )}

            {/* Milestone Preview for Presets */}
            {vestingMode !== "custom" && (
              <div className="rounded-xl bg-gray-50 p-4 mb-4">
                <div className="space-y-2">
                  {activeMilestones.map((m, i) => (
                    <div key={i} className="flex items-center justify-between text-sm">
                      <span className="text-gray-500">Day {m.days}</span>
                      <span className="font-medium text-gray-900 tabular-nums">{m.bps / 100}% unlocked</span>
                    </div>
                  ))}
                </div>
              </div>
            )}

            {/* Strictness Indicator */}
            {strictness === "stricter" && (
              <div className="rounded-xl bg-emerald-50 border border-emerald-200 px-4 py-3 flex items-start gap-2.5">
                <svg className="h-5 w-5 text-emerald-600 shrink-0 mt-0.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                  <path strokeLinecap="round" strokeLinejoin="round" d="M9 12.75L11.25 15 15 9.75m-1.5-8.25a48.109 48.109 0 011.913-.247C12.735 2.16 14.335 3 16.34 4.37c1.406.96 2.86 2.195 3.66 3.288V19.5a2.25 2.25 0 01-2.25 2.25H6.25A2.25 2.25 0 014 19.5V7.658c.8-1.093 2.254-2.328 3.66-3.288C9.665 3 11.265 2.16 12.587 2.253z" />
                </svg>
                <div>
                  <p className="text-sm font-medium text-emerald-700">Stricter than default</p>
                  <p className="text-xs text-emerald-600/70">Higher trust signal for traders</p>
                </div>
              </div>
            )}
            {strictness === "default" && (
              <div className="rounded-xl bg-gray-50 border border-gray-200 px-4 py-3 flex items-start gap-2.5">
                <svg className="h-5 w-5 text-gray-500 shrink-0 mt-0.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                  <path strokeLinecap="round" strokeLinejoin="round" d="M9 12.75L11.25 15 15 9.75M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
                </svg>
                <div>
                  <p className="text-sm font-medium text-gray-700">Standard schedule</p>
                  <p className="text-xs text-gray-500">Default 90-day vesting</p>
                </div>
              </div>
            )}
            {strictness === "looser" && (
              <div className="rounded-xl bg-yellow-50 border border-yellow-200 px-4 py-3 flex items-start gap-2.5">
                <svg className="h-5 w-5 text-yellow-600 shrink-0 mt-0.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                  <path strokeLinecap="round" strokeLinejoin="round" d="M12 9v3.75m-9.303 3.376c-.866 1.5.217 3.374 1.948 3.374h14.71c1.73 0 2.813-1.874 1.948-3.374L13.949 3.378c-.866-1.5-3.032-1.5-3.898 0L2.697 16.126zM12 15.75h.007v.008H12v-.008z" />
                </svg>
                <div>
                  <p className="text-sm font-medium text-yellow-700">Shorter than default (90d)</p>
                  <p className="text-xs text-yellow-600/70">Traders will see this as a reduced protection signal</p>
                </div>
              </div>
            )}
            {strictness === "invalid" && (
              <div className="rounded-xl bg-red-50 border border-red-200 px-4 py-3 flex items-start gap-2.5">
                <svg className="h-5 w-5 text-red-600 shrink-0 mt-0.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                  <path strokeLinecap="round" strokeLinejoin="round" d="M12 9v3.75m-9.303 3.376c-.866 1.5.217 3.374 1.948 3.374h14.71c1.73 0 2.813-1.874 1.948-3.374L13.949 3.378c-.866-1.5-3.032-1.5-3.898 0L2.697 16.126zM12 15.75h.007v.008H12v-.008z" />
                </svg>
                <div>
                  <p className="text-sm font-medium text-red-700">Invalid schedule</p>
                  <p className="text-xs text-red-600/70">Minimum 7 days required, last milestone must be 100%</p>
                </div>
              </div>
            )}
          </Card>

          {/* Commitment Card */}
          <Card>
            <div className="flex items-center justify-between mb-5">
              <div className="flex items-center gap-3">
                <div className="flex h-10 w-10 items-center justify-center rounded-xl bg-amber-50">
                  <svg className="h-5 w-5 text-amber-600" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5}>
                    <path strokeLinecap="round" strokeLinejoin="round" d="M16.5 10.5V6.75a4.5 4.5 0 10-9 0v3.75m-.75 11.25h10.5a2.25 2.25 0 002.25-2.25v-6.75a2.25 2.25 0 00-2.25-2.25H6.75a2.25 2.25 0 00-2.25 2.25v6.75a2.25 2.25 0 002.25 2.25z" />
                  </svg>
                </div>
                <div>
                  <h2 className="text-lg font-semibold text-gray-900">Commitment</h2>
                  <p className="text-sm text-gray-500">Set your trust parameters</p>
                </div>
              </div>
              <div className={`text-sm font-semibold ${trustColor} flex items-center gap-1.5 rounded-full px-3 py-1 ${
                trustLevel === "High" ? "bg-emerald-50" : trustLevel === "Medium" ? "bg-yellow-50" : "bg-red-50"
              }`}>
                <span className={`h-2 w-2 rounded-full ${
                  trustLevel === "High" ? "bg-emerald-500" : trustLevel === "Medium" ? "bg-yellow-500" : "bg-red-500"
                }`} />
                {trustLevel} Trust
              </div>
            </div>

            <div className="space-y-7">
              <div>
                <div className="flex justify-between text-sm mb-3">
                  <span className="text-gray-600 font-medium">Daily Withdraw Limit</span>
                  <span className="text-gray-900 font-semibold tabular-nums">{formatBps(commitment.dailyWithdrawLimit)}</span>
                </div>
                <input
                  type="range"
                  min={100}
                  max={2000}
                  step={50}
                  value={commitment.dailyWithdrawLimit}
                  onChange={(e) =>
                    setCommitment({
                      ...commitment,
                      dailyWithdrawLimit: parseInt(e.target.value),
                    })
                  }
                  className="w-full accent-bastion-600"
                />
                <div className="flex justify-between text-[11px] text-gray-400 mt-1">
                  <span>1% (Strict)</span>
                  <span>20% (Relaxed)</span>
                </div>
              </div>
              <div>
                <div className="flex justify-between text-sm mb-3">
                  <span className="text-gray-600 font-medium">Lock Duration</span>
                  <span className="text-gray-900 font-semibold tabular-nums">{formatDuration(commitment.lockDuration)}</span>
                </div>
                <input
                  type="range"
                  min={604800}
                  max={31536000}
                  step={604800}
                  value={commitment.lockDuration}
                  onChange={(e) =>
                    setCommitment({
                      ...commitment,
                      lockDuration: parseInt(e.target.value),
                    })
                  }
                  className="w-full accent-bastion-600"
                />
                <div className="flex justify-between text-[11px] text-gray-400 mt-1">
                  <span>1 week</span>
                  <span>1 year</span>
                </div>
              </div>
              <div>
                <div className="flex justify-between text-sm mb-3">
                  <span className="text-gray-600 font-medium">Max Sell per 24h</span>
                  <span className="text-gray-900 font-semibold tabular-nums">{formatBps(commitment.maxSellPercent)}</span>
                </div>
                <input
                  type="range"
                  min={100}
                  max={1000}
                  step={50}
                  value={commitment.maxSellPercent}
                  onChange={(e) =>
                    setCommitment({
                      ...commitment,
                      maxSellPercent: parseInt(e.target.value),
                    })
                  }
                  className="w-full accent-bastion-600"
                />
                <div className="flex justify-between text-[11px] text-gray-400 mt-1">
                  <span>1% (Strict)</span>
                  <span>10% (Relaxed)</span>
                </div>
              </div>
            </div>

            <button
              onClick={() => setCommitment(DEFAULT_COMMITMENT)}
              className="mt-4 text-xs text-bastion-600 hover:text-bastion-700 hover:underline transition-colors"
            >
              Reset to defaults
            </button>
          </Card>

          <div className="flex gap-3">
            <button
              onClick={() => setStep(2)}
              className="btn-secondary flex-1 py-3.5"
            >
              Back
            </button>
            <button
              onClick={() => setStep(4)}
              disabled={!isVestingValid}
              className="btn-primary flex-1 py-3.5 disabled:opacity-40"
            >
              Review
            </button>
          </div>
        </div>
      )}

      {/* Step 4: Confirm */}
      {step === 4 && (
        <Card>
          <div className="flex items-center gap-3 mb-6">
            <div className="flex h-10 w-10 items-center justify-center rounded-xl bg-bastion-50">
              <svg className="h-5 w-5 text-bastion-600" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M9 12.75L11.25 15 15 9.75M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
              </svg>
            </div>
            <div>
              <h2 className="text-lg font-semibold text-gray-900">Review & Create</h2>
              <p className="text-sm text-gray-500">Verify your pool parameters</p>
            </div>
          </div>

          <div className="rounded-xl bg-gray-50 p-5 space-y-3 text-sm">
            <div className="flex justify-between">
              <span className="text-gray-500">Token</span>
              <span className="font-mono text-xs text-gray-700">
                {tokenAddress.slice(0, 10)}...{tokenAddress.slice(-8)}
              </span>
            </div>
            <div className="flex justify-between">
              <span className="text-gray-500">ETH Liquidity</span>
              <span className="text-gray-900 font-medium">{ethAmount} ETH</span>
            </div>
            <div className="flex justify-between">
              <span className="text-gray-500">Token Liquidity</span>
              <span className="text-gray-900 font-medium">{tokenAmount}</span>
            </div>
            <hr className="border-gray-200" />
            <div className="flex justify-between">
              <span className="text-gray-500">Vesting Schedule</span>
              <span className="text-gray-900 font-medium capitalize">{vestingMode}</span>
            </div>
            <div className="flex justify-between">
              <span className="text-gray-500">Vesting Duration</span>
              <span className="text-gray-900 font-medium">{activeMilestones[activeMilestones.length - 1]?.days ?? 0} days</span>
            </div>
            <div className="flex justify-between items-center">
              <span className="text-gray-500">Vesting Strictness</span>
              <span className={`text-xs font-medium px-2 py-0.5 rounded-full ${
                strictness === "stricter" ? "bg-emerald-50 text-emerald-700"
                : strictness === "default" ? "bg-gray-100 text-gray-600"
                : strictness === "looser" ? "bg-yellow-50 text-yellow-700"
                : "bg-red-50 text-red-600"
              }`}>
                {strictness === "stricter" ? "Stricter" : strictness === "default" ? "Standard" : strictness === "looser" ? "Below default" : "Invalid"}
              </span>
            </div>
            <hr className="border-gray-200" />
            <div className="flex justify-between">
              <span className="text-gray-500">Daily Withdraw Limit</span>
              <span className="text-gray-900 font-medium">{formatBps(commitment.dailyWithdrawLimit)}</span>
            </div>
            <div className="flex justify-between">
              <span className="text-gray-500">Lock Duration</span>
              <span className="text-gray-900 font-medium">{formatDuration(commitment.lockDuration)}</span>
            </div>
            <div className="flex justify-between">
              <span className="text-gray-500">Max Sell / 24h</span>
              <span className="text-gray-900 font-medium">{formatBps(commitment.maxSellPercent)}</span>
            </div>
            <div className="flex justify-between items-center">
              <span className="text-gray-500">Protection</span>
              <Badge variant="protected">Bastion Protected</Badge>
            </div>
          </div>

          {error && (
            <div className="mt-4 rounded-xl bg-red-50 border border-red-200 px-4 py-3">
              <p className="text-sm text-red-600">
                {error.message.slice(0, 100)}
              </p>
            </div>
          )}
          {isSuccess && hash && (
            <div className="mt-4 rounded-xl bg-emerald-50 border border-emerald-200 p-4 text-center">
              <svg className="h-8 w-8 text-emerald-600 mx-auto mb-2" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M9 12.75L11.25 15 15 9.75M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
              </svg>
              <p className="text-sm font-medium text-emerald-700">Pool initialized!</p>
              <p className="text-xs text-emerald-600/70 mt-1 font-mono">
                {hash.slice(0, 10)}...{hash.slice(-8)}
              </p>
              <p className="mt-2 text-xs text-gray-500">
                Add initial liquidity via CLI to activate escrow protection.
              </p>
            </div>
          )}

          <div className="mt-5 flex gap-3">
            <button
              onClick={() => setStep(3)}
              disabled={isWriting || isConfirming}
              className="btn-secondary flex-1 py-3.5 disabled:opacity-40"
            >
              Back
            </button>
            <button
              onClick={handleCreatePool}
              disabled={isWriting || isConfirming || isSuccess}
              className="btn-primary flex-1 py-3.5 disabled:opacity-40 text-base"
            >
              {isWriting ? (
                <span className="flex items-center justify-center gap-2">
                  <LoadingSpinner size="sm" /> Confirm...
                </span>
              ) : isConfirming ? (
                <span className="flex items-center justify-center gap-2">
                  <LoadingSpinner size="sm" /> Processing...
                </span>
              ) : isSuccess ? (
                "Created!"
              ) : (
                "Create Bastion Pool"
              )}
            </button>
          </div>
        </Card>
      )}
    </div>
  );
}
