"use client";

import { useState } from "react";
import { useAccount } from "wagmi";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { Card } from "@/components/ui/Card";
import { LoadingSpinner } from "@/components/ui/LoadingSpinner";
import { useDeployToken, type DeployTokenResult } from "@/hooks/useDeployToken";
import { parseErrorMessage } from "@/utils/errorMessages";
import { formatWithCommas, sanitizeNumericInput } from "@/lib/formatters";
import Link from "next/link";

const DECIMALS_OPTIONS = [18, 8, 6];


export default function CreateTokenPage() {
  const { isConnected } = useAccount();
  const { step, error, result, deploy, reset, isActive } = useDeployToken();

  const [name, setName] = useState("");
  const [symbol, setSymbol] = useState("");
  const [decimals, setDecimals] = useState(18);
  const [supply, setSupply] = useState("1000000");
  const [history, setHistory] = useState<DeployTokenResult[]>([]);
  const [copied, setCopied] = useState(false);

  const canSubmit = isConnected && name.trim() && symbol.trim() && supply.trim() && !isActive;

  async function handleDeploy() {
    await deploy({ name: name.trim(), symbol: symbol.trim().toUpperCase(), decimals, initialSupply: supply.trim() });
  }

  // Move deployed result to history when done
  if (step === "done" && result && !history.find((h) => h.txHash === result.txHash)) {
    setHistory((prev) => [result, ...prev]);
  }

  function handleDeployAnother() {
    reset();
    setName("");
    setSymbol("");
    setDecimals(18);
    setSupply("1000000");
  }

  return (
    <div className="mx-auto max-w-lg space-y-6">
      <div>
        <h1 className="text-2xl font-bold text-gray-900">Deploy Token</h1>
        <p className="mt-1 text-sm text-gray-500">
          Deploy a standard ERC-20 token and launch it on BastionSwap.
        </p>
      </div>

      {/* Deploy form */}
      {step !== "done" ? (
        <Card>
          <div className="space-y-4">
            {/* Token Name */}
            <div>
              <label className="mb-1 block text-sm font-medium text-gray-700">Token Name</label>
              <input
                type="text"
                value={name}
                onChange={(e) => setName(e.target.value)}
                placeholder="e.g. My Token"
                disabled={isActive}
                maxLength={32}
                className="w-full rounded-lg border border-gray-200 bg-gray-50 px-3 py-2.5 text-sm text-gray-900 outline-none transition-colors focus:border-bastion-400 focus:bg-white disabled:opacity-50"
              />
            </div>

            {/* Symbol */}
            <div>
              <label className="mb-1 block text-sm font-medium text-gray-700">Symbol</label>
              <input
                type="text"
                value={symbol}
                onChange={(e) => setSymbol(e.target.value.toUpperCase())}
                placeholder="e.g. MTT"
                disabled={isActive}
                maxLength={10}
                className="w-full rounded-lg border border-gray-200 bg-gray-50 px-3 py-2.5 text-sm text-gray-900 uppercase outline-none transition-colors focus:border-bastion-400 focus:bg-white disabled:opacity-50"
              />
            </div>

            {/* Decimals */}
            <div>
              <label className="mb-1 block text-sm font-medium text-gray-700">Decimals</label>
              <div className="flex gap-2">
                {DECIMALS_OPTIONS.map((d) => (
                  <button
                    key={d}
                    onClick={() => setDecimals(d)}
                    disabled={isActive}
                    className={`flex-1 rounded-lg border px-3 py-2 text-sm font-medium transition-colors ${
                      decimals === d
                        ? "border-bastion-400 bg-bastion-50 text-bastion-700"
                        : "border-gray-200 bg-white text-gray-600 hover:border-gray-300"
                    } disabled:opacity-50`}
                  >
                    {d}
                  </button>
                ))}
              </div>
            </div>

            {/* Initial Supply */}
            <div>
              <label className="mb-1 block text-sm font-medium text-gray-700">Initial Supply</label>
              <input
                type="text"
                inputMode="decimal"
                value={formatWithCommas(supply)}
                onChange={(e) => { const v = sanitizeNumericInput(e.target.value); if (v !== null) setSupply(v); }}
                placeholder="1,000,000"
                disabled={isActive}
                className="w-full rounded-lg border border-gray-200 bg-gray-50 px-3 py-2.5 text-sm text-gray-900 outline-none transition-colors focus:border-bastion-400 focus:bg-white disabled:opacity-50"
              />
              <p className="mt-1 text-xs text-gray-400">
                All tokens will be minted to your wallet.
              </p>
            </div>

            {/* Error */}
            {step === "error" && error && (
              <div className="rounded-lg border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-600">
                {parseErrorMessage(error)}
              </div>
            )}

            {/* Submit */}
            {!isConnected ? (
              <div className="flex justify-center">
                <ConnectButton />
              </div>
            ) : (
              <button
                onClick={handleDeploy}
                disabled={!canSubmit}
                className="btn-primary w-full py-3 text-sm font-semibold disabled:opacity-50"
              >
                {isActive ? (
                  <span className="flex items-center justify-center gap-2">
                    <LoadingSpinner size="sm" />
                    {step === "deploying" ? "Deploying..." : "Confirming..."}
                  </span>
                ) : step === "error" ? (
                  "Try Again"
                ) : (
                  "Deploy Token"
                )}
              </button>
            )}
          </div>
        </Card>
      ) : (
        /* Success state */
        <Card glow="emerald">
          <div className="space-y-4">
            <div className="flex items-center gap-2">
              <div className="flex h-8 w-8 items-center justify-center rounded-full bg-emerald-100 text-emerald-600">
                <svg className="h-5 w-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                  <path strokeLinecap="round" strokeLinejoin="round" d="M5 13l4 4L19 7" />
                </svg>
              </div>
              <h2 className="text-lg font-semibold text-gray-900">Token Deployed</h2>
            </div>

            {result && (
              <div className="space-y-3 rounded-lg border border-gray-100 bg-gray-50 p-4">
                <div className="flex items-center justify-between">
                  <span className="text-sm text-gray-500">Name</span>
                  <span className="text-sm font-medium text-gray-900">{result.name}</span>
                </div>
                <div className="flex items-center justify-between">
                  <span className="text-sm text-gray-500">Symbol</span>
                  <span className="text-sm font-medium text-gray-900">{result.symbol}</span>
                </div>
                <div className="flex items-center justify-between">
                  <span className="text-sm text-gray-500">Decimals</span>
                  <span className="text-sm font-medium text-gray-900">{result.decimals}</span>
                </div>
                <div className="flex items-center justify-between">
                  <span className="text-sm text-gray-500">Supply</span>
                  <span className="text-sm font-medium text-gray-900">
                    {Number(result.initialSupply).toLocaleString()}
                  </span>
                </div>
                <div className="border-t border-gray-200 pt-3">
                  <span className="block text-sm text-gray-500">Contract Address</span>
                  <button
                    onClick={() => {
                      navigator.clipboard.writeText(result.address);
                      setCopied(true);
                      setTimeout(() => setCopied(false), 2000);
                    }}
                    className="mt-1 flex items-center gap-1.5 text-sm font-mono text-bastion-600 hover:text-bastion-700 transition-colors"
                    title="Copy address"
                  >
                    {result.address}
                    {copied ? (
                      <span className="shrink-0 text-xs font-sans text-emerald-600">Copied!</span>
                    ) : (
                      <svg className="h-3.5 w-3.5 shrink-0" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                        <path strokeLinecap="round" strokeLinejoin="round" d="M8 16H6a2 2 0 01-2-2V6a2 2 0 012-2h8a2 2 0 012 2v2m-6 12h8a2 2 0 002-2v-8a2 2 0 00-2-2h-8a2 2 0 00-2 2v8a2 2 0 002 2z" />
                      </svg>
                    )}
                  </button>
                </div>
              </div>
            )}

            <div className="flex gap-3">
              <Link
                href={`/create?token=${result?.address}`}
                className="btn-primary flex-1 py-2.5 text-center text-sm font-semibold"
              >
                Create Pool
              </Link>
              <button
                onClick={handleDeployAnother}
                className="flex-1 rounded-xl border border-gray-200 bg-white py-2.5 text-sm font-semibold text-gray-700 transition-colors hover:bg-gray-50"
              >
                Deploy Another
              </button>
            </div>
          </div>
        </Card>
      )}

      {/* Deployment History */}
      {history.length > 0 && step !== "done" && (
        <div>
          <h3 className="mb-3 text-sm font-semibold text-gray-900">Recently Deployed</h3>
          <div className="space-y-2">
            {history.map((item) => (
              <div
                key={item.txHash}
                className="flex items-center justify-between rounded-lg border border-gray-100 bg-white px-4 py-3"
              >
                <div className="min-w-0">
                  <p className="text-sm font-medium text-gray-900">
                    {item.name} ({item.symbol})
                  </p>
                  <p className="truncate font-mono text-xs text-gray-400">{item.address}</p>
                </div>
                <div className="flex shrink-0 gap-2 ml-3">
                  <button
                    onClick={() => navigator.clipboard.writeText(item.address)}
                    className="rounded-lg border border-gray-200 px-2.5 py-1.5 text-xs text-gray-500 hover:bg-gray-50 transition-colors"
                    title="Copy address"
                  >
                    Copy
                  </button>
                  <Link
                    href={`/create?token=${item.address}`}
                    className="rounded-lg border border-bastion-200 bg-bastion-50 px-2.5 py-1.5 text-xs font-medium text-bastion-700 hover:bg-bastion-100 transition-colors"
                  >
                    Create Pool
                  </Link>
                </div>
              </div>
            ))}
          </div>
        </div>
      )}
    </div>
  );
}
