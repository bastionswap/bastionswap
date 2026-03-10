"use client";

import { useState, useMemo } from "react";
import { useAccount, useChainId, useReadContract } from "wagmi";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { formatUnits } from "viem";
import { Card } from "@/components/ui/Card";
import { Badge } from "@/components/ui/Badge";
import {
  useCreateBastionPool,
  type CreatePoolStep,
} from "@/hooks/useCreatePool";
import { LoadingSpinner } from "@/components/ui/LoadingSpinner";
import { formatBps } from "@/lib/formatters";
import { parseErrorMessage } from "@/utils/errorMessages";
import { getContracts } from "@/config/contracts";
import { VestingChart } from "@/components/ui/VestingChart";
import { usePoolByToken } from "@/hooks/usePools";
import BastionHookAbi from "@/config/abis/BastionHook.json";
import Link from "next/link";

type Step = 1 | 2 | 3 | 4;

const ZERO_ADDR = "0x0000000000000000000000000000000000000000" as `0x${string}`;

// Base token options per chain
interface BaseTokenOption {
  address: `0x${string}`;
  symbol: string;
  name: string;
  decimals: number;
}

const BASE_TOKENS: Record<number, BaseTokenOption[]> = {
  // Base mainnet fork (Anvil)
  31337: [
    { address: ZERO_ADDR, symbol: "ETH", name: "Native ETH", decimals: 18 },
    { address: "0x4200000000000000000000000000000000000006", symbol: "WETH", name: "Wrapped ETH", decimals: 18 },
    { address: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913", symbol: "USDC", name: "USD Coin", decimals: 6 },
  ],
  // Base Sepolia
  84532: [
    { address: ZERO_ADDR, symbol: "ETH", name: "Native ETH", decimals: 18 },
    { address: "0x4200000000000000000000000000000000000006", symbol: "WETH", name: "Wrapped ETH", decimals: 18 },
    { address: "0x036CbD53842c5426634e7929541eC2318f3dCF7e", symbol: "USDC", name: "USD Coin", decimals: 6 },
  ],
  // Base mainnet
  8453: [
    { address: ZERO_ADDR, symbol: "ETH", name: "Native ETH", decimals: 18 },
    { address: "0x4200000000000000000000000000000000000006", symbol: "WETH", name: "Wrapped ETH", decimals: 18 },
    { address: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913", symbol: "USDC", name: "USD Coin", decimals: 6 },
  ],
};

const DEFAULT_COMMITMENT = {
  dailyWithdrawLimit: 500, // 5% in bps
  maxSellPercent: 300, // 3% in bps
};

// Unified commitment presets: vesting schedule + trigger detection thresholds
type CommitmentMode = "quick" | "standard" | "strict" | "custom";

interface CommitmentPreset {
  lockDays: number;
  vestingDays: number;
  dailyWithdrawLimit: number;
  maxSellPercent: number;
  lpRemoval: number;
  dump: number;
  slowRug: number;
}

const COMMITMENT_PRESETS: Record<Exclude<CommitmentMode, "custom">, CommitmentPreset> = {
  quick:    { lockDays: 7,  vestingDays: 23,  dailyWithdrawLimit: 500, maxSellPercent: 300, lpRemoval: 5000, dump: 3000, slowRug: 8000 },
  standard: { lockDays: 7,  vestingDays: 83,  dailyWithdrawLimit: 500, maxSellPercent: 300, lpRemoval: 5000, dump: 3000, slowRug: 8000 },
  strict:   { lockDays: 30, vestingDays: 150, dailyWithdrawLimit: 300, maxSellPercent: 200, lpRemoval: 3000, dump: 2000, slowRug: 5000 },
};

// Keep backward compatibility alias
type VestingMode = CommitmentMode;
const VESTING_PRESETS = COMMITMENT_PRESETS;

const DEFAULT_TOTAL_DAYS = 90;

function computeStrictnessLevel(
  lockDays: number,
  vestingDays: number
): "stricter" | "default" | "looser" | "invalid" {
  if (lockDays < 7 || vestingDays < 7) return "invalid";
  const totalDays = lockDays + vestingDays;
  if (totalDays < DEFAULT_TOTAL_DAYS) return "looser";
  if (totalDays === DEFAULT_TOTAL_DAYS) return "default";
  return "stricter";
}

const STEP_LABELS = ["Token", "Liquidity", "Commitment", "Confirm"];

function getStepLabel(poolStep: CreatePoolStep, totalSteps: number): string {
  switch (poolStep) {
    case "checking-permit2":
      return "Checking approvals...";
    case "approving-permit2-token":
    case "confirming-permit2-token":
      return `Approve Token → Permit2 (1/${totalSteps})`;
    case "approving-permit2-base":
    case "confirming-permit2-base":
      return `Approve Base → Permit2 (2/${totalSteps})`;
    case "signing":
      return `Sign Permit (${totalSteps - 1}/${totalSteps})`;
    case "creating":
    case "confirming-creation":
      return `Creating Pool (${totalSteps}/${totalSteps})`;
    case "done":
      return "Pool Created!";
    case "error":
      return "Error";
    default:
      return "Create Bastion Pool";
  }
}

function isStepConfirming(poolStep: CreatePoolStep): boolean {
  return [
    "checking-permit2",
    "confirming-permit2-token",
    "confirming-permit2-base",
    "confirming-creation",
  ].includes(poolStep);
}

function formatCompact(n: number): string {
  if (n === 0) return "0";
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`;
  if (n >= 1_000) return `${(n / 1_000).toFixed(1)}K`;
  if (n >= 1) return n.toFixed(2);
  return n.toFixed(4);
}


export default function CreatePoolPage() {
  const { isConnected, address } = useAccount();
  const chainId = useChainId();
  const contracts = getContracts(chainId);
  const baseTokenOptions = BASE_TOKENS[chainId] ?? BASE_TOKENS[31337];

  const [step, setStep] = useState<Step>(1);
  const [tokenAddress, setTokenAddress] = useState("");
  const [selectedBaseToken, setSelectedBaseToken] = useState<BaseTokenOption>(baseTokenOptions[0]);
  const [baseAmount, setBaseAmount] = useState("");
  const [tokenAmount, setTokenAmount] = useState("");
  const [commitment, setCommitment] = useState(DEFAULT_COMMITMENT);
  const [vestingMode, setVestingMode] = useState<CommitmentMode>("standard");
  const [lockDays, setLockDays] = useState(7);
  const [vestingDays, setVestingDays] = useState(83);
  const [triggerThresholds, setTriggerThresholds] = useState({
    lpRemoval: 5000,
    dump: 3000,
    slowRug: 8000,
  });

  const activeLockDays = vestingMode === "custom" ? lockDays : COMMITMENT_PRESETS[vestingMode].lockDays;
  const activeVestingDays = vestingMode === "custom" ? vestingDays : COMMITMENT_PRESETS[vestingMode].vestingDays;
  const totalDays = activeLockDays + activeVestingDays;

  const strictness = useMemo(() => computeStrictnessLevel(activeLockDays, activeVestingDays), [activeLockDays, activeVestingDays]);

  const isVestingValid = activeLockDays >= 7 && activeVestingDays >= 7;

  // Read minBaseAmount from BastionHook contract
  const hookAddress = contracts?.BastionHook as `0x${string}` | undefined;
  const { data: minBaseAmountRaw } = useReadContract({
    address: hookAddress,
    abi: BastionHookAbi,
    functionName: "minBaseAmount",
    args: [selectedBaseToken.address],
    query: { enabled: !!hookAddress },
  });
  const minBaseAmount = minBaseAmountRaw
    ? formatUnits(minBaseAmountRaw as bigint, selectedBaseToken.decimals)
    : undefined;

  const {
    step: poolStep,
    error,
    isPoolAlreadyExists,
    hash,
    startCreation,
    reset: resetPool,
    totalSteps,
    isActive,
  } = useCreateBastionPool();

  // Look up existing pool when PoolAlreadyInitialized error occurs
  const { data: existingPoolId } = usePoolByToken(
    isPoolAlreadyExists ? tokenAddress : undefined
  );

  // Active trigger thresholds (from preset or custom)
  const activeTrigger = vestingMode === "custom"
    ? triggerThresholds
    : { lpRemoval: COMMITMENT_PRESETS[vestingMode].lpRemoval, dump: COMMITMENT_PRESETS[vestingMode].dump, slowRug: COMMITMENT_PRESETS[vestingMode].slowRug };

  const activeCommitment = vestingMode === "custom"
    ? commitment
    : { dailyWithdrawLimit: COMMITMENT_PRESETS[vestingMode].dailyWithdrawLimit, maxSellPercent: COMMITMENT_PRESETS[vestingMode].maxSellPercent };

  const handleCreatePool = () => {
    if (!contracts || !address) return;
    const tokenAddr = tokenAddress as `0x${string}`;

    startCreation({
      tokenAddress: tokenAddr,
      baseToken: selectedBaseToken.address,
      baseAmount,
      baseDecimals: selectedBaseToken.decimals,
      tokenAmount,
      lockDuration: activeLockDays * 86400,
      vestingDuration: activeVestingDays * 86400,
      commitment: {
        dailyWithdrawLimit: activeCommitment.dailyWithdrawLimit,
        maxSellPercent: activeCommitment.maxSellPercent,
      },
      triggerConfig: {
        lpRemovalThreshold: activeTrigger.lpRemoval,
        dumpThresholdPercent: activeTrigger.dump,
        dumpWindowSeconds: 86400,
        taxDeviationThreshold: 500,
        slowRugWindowSeconds: 86400,
        slowRugCumulativeThreshold: activeTrigger.slowRug,
      },
    });
  };

  const trustLevel =
    totalDays >= 90 && commitment.maxSellPercent <= 300
      ? "High"
      : totalDays >= 30
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
        <ConnectButton />
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
                Set the initial token and base amounts for your pool
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

            {/* Base Token Selector */}
            <div>
              <label className="text-sm font-medium text-gray-700 mb-1.5 block">Base Token</label>
              <div className="grid grid-cols-3 gap-2 mb-3">
                {baseTokenOptions.map((bt) => (
                  <button
                    key={bt.address}
                    onClick={() => {
                      setSelectedBaseToken(bt);
                      setBaseAmount("");
                    }}
                    className={`rounded-xl border px-3 py-2.5 text-center transition-all ${
                      selectedBaseToken.address === bt.address
                        ? "border-bastion-600 bg-bastion-50 ring-1 ring-bastion-600"
                        : "border-gray-200 hover:border-gray-300"
                    }`}
                  >
                    <p className={`text-sm font-medium ${
                      selectedBaseToken.address === bt.address ? "text-bastion-700" : "text-gray-700"
                    }`}>{bt.symbol}</p>
                    <p className="text-[11px] text-gray-400">{bt.name}</p>
                  </button>
                ))}
              </div>
            </div>

            <div>
              <label className="text-sm font-medium text-gray-700 mb-1.5 block">
                {selectedBaseToken.symbol} Amount
              </label>
              <input
                type="number"
                value={baseAmount}
                onChange={(e) => setBaseAmount(e.target.value)}
                placeholder="0"
                className="input-base text-lg"
              />
            </div>

            {/* Escrow Protection Info Card */}
            <div className="rounded-xl bg-emerald-50/50 border border-emerald-200 p-4">
              <div className="flex items-start gap-3">
                <div className="flex h-8 w-8 shrink-0 items-center justify-center rounded-lg bg-emerald-100">
                  <svg className="h-4.5 w-4.5 text-emerald-600" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5}>
                    <path strokeLinecap="round" strokeLinejoin="round" d="M9 12.75L11.25 15 15 9.75m-3-7.036A11.959 11.959 0 013.598 6 11.99 11.99 0 003 9.749c0 5.592 3.824 10.29 9 11.623 5.176-1.332 9-6.03 9-11.622 0-1.31-.21-2.571-.598-3.751h-.152c-3.196 0-6.1-1.248-8.25-3.285z" />
                  </svg>
                </div>
                <div className="flex-1 min-w-0">
                  <p className="text-sm font-semibold text-emerald-800">Escrow Protection</p>
                  {tokenAmount && baseAmount && parseFloat(tokenAmount) > 0 && parseFloat(baseAmount) > 0 ? (
                    <p className="text-sm text-emerald-700 mt-1">
                      Your LP position will be locked. You can remove LP according to the vesting schedule below.
                      This protects token buyers and cannot be disabled.
                    </p>
                  ) : (
                    <p className="text-sm text-emerald-600/70 mt-1">
                      Enter token and ETH amounts to see escrow details
                    </p>
                  )}
                </div>
              </div>
            </div>

            {/* Vesting Schedule Preview */}
            {tokenAmount && baseAmount && parseFloat(tokenAmount) > 0 && parseFloat(baseAmount) > 0 && (
              <div className="rounded-xl bg-gray-50 border border-gray-200 p-4">
                <p className="text-xs font-semibold text-gray-500 uppercase tracking-wider mb-3">LP Vesting Schedule</p>
                <div className="space-y-2.5">
                  <div className="flex items-center gap-3">
                    <div className="flex items-center gap-2 flex-1 min-w-0">
                      <div className="h-2 w-2 rounded-full bg-amber-500 shrink-0" />
                      <span className="text-sm text-gray-600">Day 0–{activeLockDays}</span>
                    </div>
                    <span className="text-sm font-medium text-gray-900">Locked (0%)</span>
                  </div>
                  <div className="flex items-center gap-3">
                    <div className="flex items-center gap-2 flex-1 min-w-0">
                      <div className="h-2 w-2 rounded-full bg-bastion-500 shrink-0" />
                      <span className="text-sm text-gray-600">Day {activeLockDays}–{totalDays}</span>
                    </div>
                    <span className="text-sm font-medium text-gray-900">Linear vesting (0%→100%)</span>
                  </div>
                </div>
                <p className="text-xs text-gray-400 mt-3 flex items-center gap-1">
                  <svg className="h-3.5 w-3.5 shrink-0" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                    <path strokeLinecap="round" strokeLinejoin="round" d="M11.25 11.25l.041-.02a.75.75 0 011.063.852l-.708 2.836a.75.75 0 001.063.853l.041-.021M21 12a9 9 0 11-18 0 9 9 0 0118 0zm-9-3.75h.008v.008H12V8.25z" />
                  </svg>
                  You can customize this in the next step. Actual amounts may differ due to AMM price changes.
                </p>
              </div>
            )}

            {/* Minimum liquidity warning */}
            {baseAmount && parseFloat(baseAmount) > 0 && parseFloat(baseAmount) < parseFloat(minBaseAmount ?? "0") && (
              <div className="rounded-xl bg-red-50 border border-red-200 px-4 py-3 flex items-start gap-2.5">
                <svg className="h-5 w-5 text-red-600 shrink-0 mt-0.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                  <path strokeLinecap="round" strokeLinejoin="round" d="M12 9v3.75m-9.303 3.376c-.866 1.5.217 3.374 1.948 3.374h14.71c1.73 0 2.813-1.874 1.948-3.374L13.949 3.378c-.866-1.5-3.032-1.5-3.898 0L2.697 16.126zM12 15.75h.007v.008H12v-.008z" />
                </svg>
                <div>
                  <p className="text-sm font-medium text-red-700">Minimum {minBaseAmount ?? "?"} {selectedBaseToken.symbol} required</p>
                  <p className="text-xs text-red-600/70">Bastion pools require minimum initial liquidity to prevent spam.</p>
                </div>
              </div>
            )}
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
              disabled={!baseAmount || !tokenAmount || parseFloat(baseAmount) < parseFloat(minBaseAmount ?? "0")}
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
                  <p className="text-sm text-gray-500">Define how escrowed LP unlocks over time</p>
                </div>
              </div>
            </div>

            {/* Preset Buttons */}
            <div className="grid grid-cols-4 gap-2 mb-5">
              {([
                { mode: "quick" as const, label: "Quick", desc: "30 days" },
                { mode: "standard" as const, label: "Standard", desc: "90 days" },
                { mode: "strict" as const, label: "Strict", desc: "180 days" },
                { mode: "custom" as const, label: "Custom", desc: "Your rules" },
              ]).map(({ mode, label, desc }) => (
                <button
                  key={mode}
                  onClick={() => {
                    setVestingMode(mode);
                    if (mode !== "custom") {
                      const preset = COMMITMENT_PRESETS[mode];
                      setLockDays(preset.lockDays);
                      setVestingDays(preset.vestingDays);
                      setCommitment({ dailyWithdrawLimit: preset.dailyWithdrawLimit, maxSellPercent: preset.maxSellPercent });
                      setTriggerThresholds({ lpRemoval: preset.lpRemoval, dump: preset.dump, slowRug: preset.slowRug });
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

            {/* Custom Lock/Vesting Duration Editor */}
            {vestingMode === "custom" && (
              <div className="space-y-5 mb-4">
                <div>
                  <div className="flex justify-between text-sm mb-3">
                    <span className="text-gray-600 font-medium">Lock Period</span>
                    <span className="text-gray-900 font-semibold tabular-nums">{lockDays} days</span>
                  </div>
                  <input
                    type="range"
                    min={7}
                    max={90}
                    step={1}
                    value={lockDays}
                    onChange={(e) => setLockDays(parseInt(e.target.value))}
                    className="w-full accent-bastion-600"
                  />
                  <div className="flex justify-between text-[11px] text-gray-400 mt-1">
                    <span>7 days (min)</span>
                    <span>90 days</span>
                  </div>
                </div>
                <div>
                  <div className="flex justify-between text-sm mb-3">
                    <span className="text-gray-600 font-medium">Vesting Period</span>
                    <span className="text-gray-900 font-semibold tabular-nums">{vestingDays} days</span>
                  </div>
                  <input
                    type="range"
                    min={7}
                    max={365}
                    step={1}
                    value={vestingDays}
                    onChange={(e) => setVestingDays(parseInt(e.target.value))}
                    className="w-full accent-bastion-600"
                  />
                  <div className="flex justify-between text-[11px] text-gray-400 mt-1">
                    <span>7 days (min)</span>
                    <span>365 days</span>
                  </div>
                </div>
                <div className="rounded-lg bg-gray-100 px-3 py-2 text-sm text-gray-600 text-center">
                  Total: <span className="font-semibold">{totalDays} days</span>
                </div>

                {/* Trigger Threshold Sliders */}
                <div className="pt-4 border-t border-gray-200">
                  <p className="text-xs font-semibold text-gray-500 uppercase tracking-wider mb-4">Trigger Detection Thresholds</p>
                  <p className="text-xs text-gray-400 mb-4">Lower values = stricter protection for buyers</p>
                  <div className="space-y-5">
                    <div>
                      <div className="flex justify-between text-sm mb-3">
                        <span className="text-gray-600 font-medium">Max LP Removal / tx</span>
                        <span className="text-gray-900 font-semibold tabular-nums">{formatBps(triggerThresholds.lpRemoval)}</span>
                      </div>
                      <input
                        type="range"
                        min={1000}
                        max={5000}
                        step={100}
                        value={triggerThresholds.lpRemoval}
                        onChange={(e) => setTriggerThresholds({ ...triggerThresholds, lpRemoval: parseInt(e.target.value) })}
                        className="w-full accent-bastion-600"
                      />
                      <div className="flex justify-between text-[11px] text-gray-400 mt-1">
                        <span className="text-emerald-500">10% (Strict)</span>
                        <span>50% (Default)</span>
                      </div>
                    </div>
                    <div>
                      <div className="flex justify-between text-sm mb-3">
                        <span className="text-gray-600 font-medium">Max Cumulative LP / 24h</span>
                        <span className="text-gray-900 font-semibold tabular-nums">{formatBps(triggerThresholds.slowRug)}</span>
                      </div>
                      <input
                        type="range"
                        min={3000}
                        max={8000}
                        step={100}
                        value={triggerThresholds.slowRug}
                        onChange={(e) => setTriggerThresholds({ ...triggerThresholds, slowRug: parseInt(e.target.value) })}
                        className="w-full accent-bastion-600"
                      />
                      <div className="flex justify-between text-[11px] text-gray-400 mt-1">
                        <span className="text-emerald-500">30% (Strict)</span>
                        <span>80% (Default)</span>
                      </div>
                    </div>
                    <div>
                      <div className="flex justify-between text-sm mb-3">
                        <span className="text-gray-600 font-medium">Max Daily Issuer Sell</span>
                        <span className="text-gray-900 font-semibold tabular-nums">{formatBps(triggerThresholds.dump)}</span>
                      </div>
                      <input
                        type="range"
                        min={500}
                        max={3000}
                        step={100}
                        value={triggerThresholds.dump}
                        onChange={(e) => setTriggerThresholds({ ...triggerThresholds, dump: parseInt(e.target.value) })}
                        className="w-full accent-bastion-600"
                      />
                      <div className="flex justify-between text-[11px] text-gray-400 mt-1">
                        <span className="text-emerald-500">5% (Strict)</span>
                        <span>30% (Default)</span>
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            )}

            {/* Vesting Chart */}
            <div className="rounded-xl bg-gray-50 p-4 mb-4">
              <VestingChart
                lockDays={activeLockDays}
                vestingDays={activeVestingDays}
                defaultLockDays={vestingMode !== "standard" ? COMMITMENT_PRESETS.standard.lockDays : undefined}
                defaultVestingDays={vestingMode !== "standard" ? COMMITMENT_PRESETS.standard.vestingDays : undefined}
                label={vestingMode === "custom" ? "Custom" : vestingMode.charAt(0).toUpperCase() + vestingMode.slice(1)}
                height={160}
              />
              {/* Summary below chart */}
              <div className="mt-3 pt-3 border-t border-gray-200 space-y-1.5">
                <div className="flex items-center justify-between text-sm">
                  <span className="text-gray-500">Lock period</span>
                  <span className="font-medium text-gray-900 tabular-nums">Day 0–{activeLockDays} (0% removable)</span>
                </div>
                <div className="flex items-center justify-between text-sm">
                  <span className="text-gray-500">Linear vesting</span>
                  <span className="font-medium text-gray-900 tabular-nums">Day {activeLockDays}–{totalDays} (0%→100%)</span>
                </div>
              </div>
            </div>

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

            <div className="mt-5 flex items-center justify-between">
              <button
                onClick={() => {
                  setCommitment(DEFAULT_COMMITMENT);
                  setTriggerThresholds({ lpRemoval: 5000, dump: 3000, slowRug: 8000 });
                }}
                className="text-xs text-bastion-600 hover:text-bastion-700 hover:underline transition-colors"
              >
                Reset to defaults
              </button>
              <button
                onClick={() => {
                  setCommitment(DEFAULT_COMMITMENT);
                  setTriggerThresholds({ lpRemoval: 5000, dump: 3000, slowRug: 8000 });
                  setVestingMode("standard");
                  setStep(4);
                }}
                className="text-xs text-gray-500 hover:text-gray-700 hover:underline transition-colors"
              >
                Skip (use defaults)
              </button>
            </div>
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

          {/* Pool Summary */}
          <div className="rounded-xl bg-gray-50 p-5 space-y-3 text-sm">
            <div className="flex justify-between">
              <span className="text-gray-500">Token</span>
              <span className="font-mono text-xs text-gray-700">
                {tokenAddress.slice(0, 10)}...{tokenAddress.slice(-8)}
              </span>
            </div>
            <div className="flex justify-between">
              <span className="text-gray-500">Liquidity</span>
              <span className="text-gray-900 font-medium">{tokenAmount} tokens + {baseAmount} {selectedBaseToken.symbol}</span>
            </div>
            <div className="flex justify-between">
              <span className="text-gray-500">Escrowed LP</span>
              <span className="text-gray-900 font-medium">100% of initial liquidity</span>
            </div>
            <hr className="border-gray-200" />
            <div className="flex justify-between">
              <span className="text-gray-500">Vesting</span>
              <span className="text-gray-900 font-medium capitalize">
                {vestingMode} ({totalDays}d total)
              </span>
            </div>
            <div className="flex justify-between">
              <span className="text-gray-500">Insurance Fee</span>
              <span className="text-gray-900 font-medium">1% per buy swap</span>
            </div>
            <div className="flex justify-between">
              <span className="text-gray-500">Daily Withdraw</span>
              <span className="text-gray-900 font-medium">{formatBps(activeCommitment.dailyWithdrawLimit)}</span>
            </div>
            <div className="flex justify-between">
              <span className="text-gray-500">Max Sell / 24h</span>
              <span className="text-gray-900 font-medium">{formatBps(activeCommitment.maxSellPercent)}</span>
            </div>
            <hr className="border-gray-200" />
            <div className="flex justify-between">
              <span className="text-gray-500">Max LP Removal / tx</span>
              <span className="text-gray-900 font-medium">{formatBps(activeTrigger.lpRemoval)}</span>
            </div>
            <div className="flex justify-between">
              <span className="text-gray-500">Max Cumulative LP / 24h</span>
              <span className="text-gray-900 font-medium">{formatBps(activeTrigger.slowRug)}</span>
            </div>
            <div className="flex justify-between">
              <span className="text-gray-500">Max Daily Issuer Sell</span>
              <span className="text-gray-900 font-medium">{formatBps(activeTrigger.dump)}</span>
            </div>
            <div className="flex justify-between items-center">
              <span className="text-gray-500">Protection</span>
              <Badge variant="protected">Bastion Protected</Badge>
            </div>
          </div>

          {/* Immutability Warning */}
          <div className="mt-4 rounded-xl bg-amber-50 border border-amber-200 px-4 py-3 flex items-start gap-2.5">
            <svg className="h-5 w-5 text-amber-600 shrink-0 mt-0.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
              <path strokeLinecap="round" strokeLinejoin="round" d="M16.5 10.5V6.75a4.5 4.5 0 10-9 0v3.75m-.75 11.25h10.5a2.25 2.25 0 002.25-2.25v-6.75a2.25 2.25 0 00-2.25-2.25H6.75a2.25 2.25 0 00-2.25 2.25v6.75a2.25 2.25 0 002.25 2.25z" />
            </svg>
            <div>
              <p className="text-sm font-medium text-amber-700">These values are immutable</p>
              <p className="text-xs text-amber-600/70">
                Once the pool is created, commitment parameters are permanently recorded on-chain and cannot be changed.
              </p>
            </div>
          </div>

          {/* Escrow Disclosure */}
          <div className="mt-4 rounded-xl bg-bastion-50 border border-bastion-200 p-4">
            <p className="text-sm text-bastion-800">
              By creating this pool, your LP position will be locked in escrow.
              LP unlocks linearly after the lock period:
            </p>
            <div className="mt-3 space-y-1.5">
              <div className="flex items-center gap-2 text-sm">
                <svg className="h-4 w-4 text-bastion-600 shrink-0" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                  <path strokeLinecap="round" strokeLinejoin="round" d="M5 13l4 4L19 7" />
                </svg>
                <span className="text-bastion-700">
                  Lock period: {activeLockDays} days (no LP removal)
                </span>
              </div>
              <div className="flex items-center gap-2 text-sm">
                <svg className="h-4 w-4 text-bastion-600 shrink-0" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                  <path strokeLinecap="round" strokeLinejoin="round" d="M5 13l4 4L19 7" />
                </svg>
                <span className="text-bastion-700">
                  Vesting: {activeVestingDays} days (linear 0%→100%)
                </span>
              </div>
              <div className="flex items-center gap-2 text-sm">
                <svg className="h-4 w-4 text-bastion-600 shrink-0" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                  <path strokeLinecap="round" strokeLinejoin="round" d="M5 13l4 4L19 7" />
                </svg>
                <span className="text-bastion-700">
                  Full unlock at day {totalDays}
                </span>
              </div>
            </div>
            <p className="mt-3 text-xs text-bastion-600/70">
              If a rug pull is detected, the issuer&apos;s LP will be permanently locked down.
            </p>
          </div>

          {error && (
            <div className="mt-4 rounded-xl bg-red-50 border border-red-200 px-4 py-3">
              {isPoolAlreadyExists ? (
                <div>
                  <p className="text-sm font-medium text-red-700">
                    A Bastion pool already exists for this token pair.
                  </p>
                  {existingPoolId && (
                    <Link
                      href={`/pools/${existingPoolId}`}
                      className="mt-2 inline-flex items-center gap-1.5 text-sm font-medium text-red-600 hover:text-red-700 underline underline-offset-2"
                    >
                      View existing pool
                      <svg className="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                        <path strokeLinecap="round" strokeLinejoin="round" d="M13.5 6H5.25A2.25 2.25 0 003 8.25v10.5A2.25 2.25 0 005.25 21h10.5A2.25 2.25 0 0018 18.75V10.5m-10.5 6L21 3m0 0h-5.25M21 3v5.25" />
                      </svg>
                    </Link>
                  )}
                </div>
              ) : (
                <p className="text-sm text-red-600">
                  {parseErrorMessage(error)}
                </p>
              )}
            </div>
          )}

          {poolStep === "done" && hash && (
            <div className="mt-4 rounded-xl bg-emerald-50 border border-emerald-200 p-4 text-center">
              <svg className="h-8 w-8 text-emerald-600 mx-auto mb-2" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M9 12.75L11.25 15 15 9.75M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
              </svg>
              <p className="text-sm font-medium text-emerald-700">Pool created with full Bastion protection!</p>
              <p className="text-xs text-emerald-600/70 mt-1 font-mono">
                {hash.slice(0, 10)}...{hash.slice(-8)}
              </p>
            </div>
          )}

          {/* Multi-step progress indicator */}
          {isActive && (
            <div className="mt-4 rounded-xl bg-bastion-50 border border-bastion-200 px-4 py-3">
              <div className="flex items-center gap-3 mb-3">
                <LoadingSpinner size="sm" />
                <span className="text-sm font-medium text-bastion-700">
                  {getStepLabel(poolStep, totalSteps)}
                </span>
              </div>
              <div className="flex gap-1.5">
                {Array.from({ length: totalSteps }, (_, i) => i + 1).map((s) => {
                  const stepNum = poolStep.includes("token") ? 1
                    : poolStep.includes("base") ? 2
                    : poolStep === "signing" ? totalSteps - 1
                    : totalSteps;
                  return (
                    <div
                      key={s}
                      className={`h-1.5 flex-1 rounded-full transition-colors ${
                        s < stepNum ? "bg-bastion-600"
                        : s === stepNum ? (isStepConfirming(poolStep) ? "bg-bastion-400 animate-pulse" : "bg-bastion-600")
                        : "bg-bastion-200"
                      }`}
                    />
                  );
                })}
              </div>
            </div>
          )}

          <div className="mt-5 flex gap-3">
            <button
              onClick={() => {
                resetPool();
                setStep(3);
              }}
              disabled={isActive}
              className="btn-secondary flex-1 py-3.5 disabled:opacity-40"
            >
              Back
            </button>
            <button
              onClick={handleCreatePool}
              disabled={isActive || poolStep === "done"}
              className="btn-primary flex-1 py-3.5 disabled:opacity-40 text-base"
            >
              {poolStep === "done" ? (
                "Created!"
              ) : isActive ? (
                <span className="flex items-center justify-center gap-2">
                  <LoadingSpinner size="sm" /> {getStepLabel(poolStep, totalSteps)}
                </span>
              ) : poolStep === "error" ? (
                "Retry"
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
