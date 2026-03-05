"use client";

import { useState } from "react";
import { useAccount } from "wagmi";
import { ConnectKitButton } from "connectkit";
import { Card } from "@/components/ui/Card";
import { Badge } from "@/components/ui/Badge";
import { useCreateBastionPool } from "@/hooks/useCreatePool";
import { LoadingSpinner } from "@/components/ui/LoadingSpinner";
import { formatBps, formatDuration } from "@/lib/formatters";
import { getContracts } from "@/config/contracts";
import { PoolManagerABI } from "@/config/abis";
import { baseSepolia } from "wagmi/chains";

type Step = 1 | 2 | 3 | 4;

const SQRT_PRICE_1_1 = 79228162514264337593543950336n;

const DEFAULT_COMMITMENT = {
  dailyWithdrawLimit: 500, // 5% in bps
  lockDuration: 7776000, // 90 days in seconds
  maxSellPercent: 300, // 3% in bps
};

const STEP_LABELS = ["Token", "Liquidity", "Commitment", "Confirm"];

export default function CreatePoolPage() {
  const { isConnected, address } = useAccount();
  const [step, setStep] = useState<Step>(1);
  const [tokenAddress, setTokenAddress] = useState("");
  const [ethAmount, setEthAmount] = useState("");
  const [tokenAmount, setTokenAmount] = useState("");
  const [commitment, setCommitment] = useState(DEFAULT_COMMITMENT);
  const { createPool, isWriting, isConfirming, isSuccess, hash, error } =
    useCreateBastionPool();
  const contracts = getContracts(baseSepolia.id);

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

      {/* Step 3: Commitment */}
      {step === 3 && (
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

          <div className="mt-5 flex gap-3">
            <button
              onClick={() => setStep(2)}
              className="btn-secondary flex-1 py-3.5"
            >
              Back
            </button>
            <button
              onClick={() => setStep(4)}
              className="btn-primary flex-1 py-3.5"
            >
              Review
            </button>
          </div>
        </Card>
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
