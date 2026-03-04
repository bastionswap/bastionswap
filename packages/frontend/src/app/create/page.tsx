"use client";

import { useState } from "react";
import { useAccount } from "wagmi";
import { ConnectKitButton } from "connectkit";
import { Card } from "@/components/ui/Card";
import { Badge } from "@/components/ui/Badge";
import { useCreateBastionPool } from "@/hooks/useCreatePool";
import { LoadingSpinner } from "@/components/ui/LoadingSpinner";
import { formatBps, formatDuration } from "@/lib/formatters";

type Step = 1 | 2 | 3 | 4;

const DEFAULT_COMMITMENT = {
  dailyWithdrawLimit: 500, // 5% in bps
  lockDuration: 7776000, // 90 days in seconds
  maxSellPercent: 300, // 3% in bps
};

export default function CreatePoolPage() {
  const { isConnected } = useAccount();
  const [step, setStep] = useState<Step>(1);
  const [tokenAddress, setTokenAddress] = useState("");
  const [ethAmount, setEthAmount] = useState("");
  const [tokenAmount, setTokenAmount] = useState("");
  const [commitment, setCommitment] = useState(DEFAULT_COMMITMENT);
  const { isWriting, isConfirming, isSuccess, hash, error } =
    useCreateBastionPool();

  const trustLevel =
    commitment.lockDuration >= 7776000 && commitment.maxSellPercent <= 300
      ? "High"
      : commitment.lockDuration >= 2592000
        ? "Medium"
        : "Low";
  const trustColor =
    trustLevel === "High"
      ? "text-emerald-400"
      : trustLevel === "Medium"
        ? "text-yellow-400"
        : "text-red-400";

  if (!isConnected) {
    return (
      <div className="mx-auto max-w-lg py-12 text-center">
        <h1 className="text-2xl font-bold mb-4">Create Bastion Pool</h1>
        <p className="text-gray-400 mb-6">
          Connect your wallet to create a protected pool.
        </p>
        <ConnectKitButton />
      </div>
    );
  }

  return (
    <div className="mx-auto max-w-lg">
      <h1 className="text-2xl font-bold mb-6">Create Bastion Pool</h1>

      {/* Step Indicators */}
      <div className="mb-8 flex items-center gap-2">
        {[1, 2, 3, 4].map((s) => (
          <div key={s} className="flex items-center gap-2">
            <div
              className={`flex h-8 w-8 items-center justify-center rounded-full text-sm font-medium ${
                step >= s
                  ? "bg-bastion-500 text-white"
                  : "bg-gray-800 text-gray-500"
              }`}
            >
              {s}
            </div>
            {s < 4 && (
              <div
                className={`h-0.5 w-8 ${
                  step > s ? "bg-bastion-500" : "bg-gray-800"
                }`}
              />
            )}
          </div>
        ))}
      </div>

      {/* Step 1: Token Selection */}
      {step === 1 && (
        <Card>
          <h2 className="text-lg font-semibold mb-4">Select Token</h2>
          <p className="text-sm text-gray-400 mb-4">
            Enter the address of the token you want to create a protected pool
            for.
          </p>
          <input
            type="text"
            value={tokenAddress}
            onChange={(e) => setTokenAddress(e.target.value)}
            placeholder="0x..."
            className="w-full rounded-xl border border-gray-700 bg-gray-800 px-4 py-3 text-white placeholder-gray-500 focus:border-bastion-500 focus:outline-none"
          />
          <button
            onClick={() => setStep(2)}
            disabled={!/^0x[a-fA-F0-9]{40}$/.test(tokenAddress)}
            className="mt-4 w-full rounded-xl bg-bastion-500 py-3 font-semibold text-white hover:bg-bastion-600 disabled:opacity-40 transition-colors"
          >
            Continue
          </button>
        </Card>
      )}

      {/* Step 2: Liquidity */}
      {step === 2 && (
        <Card>
          <h2 className="text-lg font-semibold mb-4">Initial Liquidity</h2>
          <div className="space-y-4">
            <div>
              <label className="text-sm text-gray-400">Token Amount</label>
              <input
                type="number"
                value={tokenAmount}
                onChange={(e) => setTokenAmount(e.target.value)}
                placeholder="0"
                className="mt-1 w-full rounded-xl border border-gray-700 bg-gray-800 px-4 py-3 text-white placeholder-gray-500 focus:border-bastion-500 focus:outline-none"
              />
            </div>
            <div>
              <label className="text-sm text-gray-400">ETH Amount</label>
              <input
                type="number"
                value={ethAmount}
                onChange={(e) => setEthAmount(e.target.value)}
                placeholder="0"
                className="mt-1 w-full rounded-xl border border-gray-700 bg-gray-800 px-4 py-3 text-white placeholder-gray-500 focus:border-bastion-500 focus:outline-none"
              />
            </div>
          </div>
          <div className="mt-4 flex gap-3">
            <button
              onClick={() => setStep(1)}
              className="flex-1 rounded-xl border border-gray-700 py-3 font-semibold text-gray-300 hover:border-gray-600 transition-colors"
            >
              Back
            </button>
            <button
              onClick={() => setStep(3)}
              disabled={!ethAmount || !tokenAmount}
              className="flex-1 rounded-xl bg-bastion-500 py-3 font-semibold text-white hover:bg-bastion-600 disabled:opacity-40 transition-colors"
            >
              Continue
            </button>
          </div>
        </Card>
      )}

      {/* Step 3: Commitment */}
      {step === 3 && (
        <Card>
          <div className="flex items-center justify-between mb-4">
            <h2 className="text-lg font-semibold">Commitment Parameters</h2>
            <span className={`text-sm font-medium ${trustColor}`}>
              Trust Signal: {trustLevel}
            </span>
          </div>

          <div className="space-y-6">
            <div>
              <div className="flex justify-between text-sm mb-2">
                <span className="text-gray-400">Daily Withdraw Limit</span>
                <span>{formatBps(commitment.dailyWithdrawLimit)}</span>
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
                className="w-full accent-bastion-500"
              />
            </div>
            <div>
              <div className="flex justify-between text-sm mb-2">
                <span className="text-gray-400">Lock Duration</span>
                <span>{formatDuration(commitment.lockDuration)}</span>
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
                className="w-full accent-bastion-500"
              />
            </div>
            <div>
              <div className="flex justify-between text-sm mb-2">
                <span className="text-gray-400">Max Sell per 24h</span>
                <span>{formatBps(commitment.maxSellPercent)}</span>
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
                className="w-full accent-bastion-500"
              />
            </div>
          </div>

          <button
            onClick={() => setCommitment(DEFAULT_COMMITMENT)}
            className="mt-3 text-xs text-bastion-400 hover:underline"
          >
            Reset to defaults
          </button>

          <div className="mt-4 flex gap-3">
            <button
              onClick={() => setStep(2)}
              className="flex-1 rounded-xl border border-gray-700 py-3 font-semibold text-gray-300 hover:border-gray-600 transition-colors"
            >
              Back
            </button>
            <button
              onClick={() => setStep(4)}
              className="flex-1 rounded-xl bg-bastion-500 py-3 font-semibold text-white hover:bg-bastion-600 transition-colors"
            >
              Review
            </button>
          </div>
        </Card>
      )}

      {/* Step 4: Confirm */}
      {step === 4 && (
        <Card>
          <h2 className="text-lg font-semibold mb-4">Confirm Pool Creation</h2>

          <div className="space-y-3 text-sm">
            <div className="flex justify-between">
              <span className="text-gray-400">Token</span>
              <span className="font-mono text-xs">
                {tokenAddress.slice(0, 10)}...{tokenAddress.slice(-8)}
              </span>
            </div>
            <div className="flex justify-between">
              <span className="text-gray-400">ETH Liquidity</span>
              <span>{ethAmount} ETH</span>
            </div>
            <div className="flex justify-between">
              <span className="text-gray-400">Token Liquidity</span>
              <span>{tokenAmount}</span>
            </div>
            <hr className="border-gray-800" />
            <div className="flex justify-between">
              <span className="text-gray-400">Daily Withdraw Limit</span>
              <span>{formatBps(commitment.dailyWithdrawLimit)}</span>
            </div>
            <div className="flex justify-between">
              <span className="text-gray-400">Lock Duration</span>
              <span>{formatDuration(commitment.lockDuration)}</span>
            </div>
            <div className="flex justify-between">
              <span className="text-gray-400">Max Sell / 24h</span>
              <span>{formatBps(commitment.maxSellPercent)}</span>
            </div>
            <div className="flex justify-between">
              <span className="text-gray-400">Protection</span>
              <Badge variant="protected">Bastion Protected</Badge>
            </div>
          </div>

          {error && (
            <p className="mt-3 text-sm text-red-400">
              {error.message.slice(0, 100)}
            </p>
          )}
          {isSuccess && hash && (
            <div className="mt-3 rounded-lg bg-emerald-500/10 p-3 text-center text-sm text-emerald-400">
              Pool created! Tx: {hash.slice(0, 10)}...
            </div>
          )}

          <div className="mt-4 flex gap-3">
            <button
              onClick={() => setStep(3)}
              disabled={isWriting || isConfirming}
              className="flex-1 rounded-xl border border-gray-700 py-3 font-semibold text-gray-300 hover:border-gray-600 disabled:opacity-40 transition-colors"
            >
              Back
            </button>
            <button
              disabled={isWriting || isConfirming || isSuccess}
              className="flex-1 rounded-xl bg-bastion-500 py-3 font-semibold text-white hover:bg-bastion-600 disabled:opacity-40 transition-colors"
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
