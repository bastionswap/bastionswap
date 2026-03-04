"use client";

import { useState } from "react";
import { useAccount } from "wagmi";
import { ConnectKitButton } from "connectkit";
import { Card } from "@/components/ui/Card";
import { Badge } from "@/components/ui/Badge";
import { TokenIcon } from "@/components/ui/TokenIcon";
import { TokenSelectModal } from "./TokenSelectModal";
import { useExecuteSwap } from "@/hooks/useSwap";

interface Token {
  address: string;
  symbol: string;
  name: string;
}

export function SwapCard() {
  const { isConnected } = useAccount();
  const [tokenIn, setTokenIn] = useState<Token | null>(null);
  const [tokenOut, setTokenOut] = useState<Token | null>(null);
  const [amountIn, setAmountIn] = useState("");
  const [slippage, setSlippage] = useState("0.5");
  const [showTokenSelect, setShowTokenSelect] = useState<"in" | "out" | null>(null);
  const [showSlippage, setShowSlippage] = useState(false);
  const { isWriting, isConfirming, isSuccess, error } = useExecuteSwap();

  const swapDirection = () => {
    setTokenIn(tokenOut);
    setTokenOut(tokenIn);
    setAmountIn("");
  };

  return (
    <>
      <Card className="mx-auto max-w-[440px]">
        <div className="mb-4 flex items-center justify-between">
          <h2 className="text-lg font-semibold">Swap</h2>
          <button
            onClick={() => setShowSlippage(!showSlippage)}
            className="rounded-lg p-2 text-gray-500 hover:bg-surface-light hover:text-white transition-colors"
            title="Settings"
          >
            <svg className="h-5 w-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={1.5} d="M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 002.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 001.066 2.573c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 00-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 00-2.573 1.066c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 00-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 00-1.066-2.573c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 001.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z" />
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={1.5} d="M15 12a3 3 0 11-6 0 3 3 0 016 0z" />
            </svg>
          </button>
        </div>

        {showSlippage && (
          <div className="mb-4 rounded-xl bg-surface-light p-3">
            <p className="mb-2 text-xs text-gray-500">Slippage Tolerance</p>
            <div className="flex gap-2">
              {["0.5", "1.0", "2.0"].map((val) => (
                <button
                  key={val}
                  onClick={() => setSlippage(val)}
                  className={`rounded-lg px-3 py-1.5 text-sm transition-colors ${
                    slippage === val
                      ? "bg-bastion-500 text-white"
                      : "bg-surface-lighter text-gray-300 hover:bg-surface-lighter/80"
                  }`}
                >
                  {val}%
                </button>
              ))}
              <input
                type="number"
                value={!["0.5", "1.0", "2.0"].includes(slippage) ? slippage : ""}
                onChange={(e) => setSlippage(e.target.value)}
                placeholder="Custom"
                className="w-20 rounded-lg bg-surface-lighter px-2 py-1.5 text-sm text-white placeholder-gray-500 focus:outline-none"
              />
            </div>
          </div>
        )}

        {/* Token In */}
        <div className="rounded-xl bg-surface-light p-4">
          <div className="mb-2">
            <span className="text-sm text-gray-500">You pay</span>
          </div>
          <div className="flex items-center gap-3">
            <input
              type="number"
              value={amountIn}
              onChange={(e) => setAmountIn(e.target.value)}
              placeholder="0"
              className="flex-1 bg-transparent text-2xl font-medium text-white placeholder-gray-600 focus:outline-none [appearance:textfield] [&::-webkit-inner-spin-button]:appearance-none [&::-webkit-outer-spin-button]:appearance-none"
            />
            <button
              onClick={() => setShowTokenSelect("in")}
              className={`flex items-center gap-2 rounded-full px-3 py-2 text-sm font-medium transition-colors ${
                tokenIn
                  ? "bg-surface-lighter hover:bg-surface-lighter/80"
                  : "bg-bastion-500 text-white hover:bg-bastion-400"
              }`}
            >
              {tokenIn ? (
                <>
                  <TokenIcon address={tokenIn.address} size={20} />
                  {tokenIn.symbol}
                </>
              ) : (
                "Select token"
              )}
              <svg className="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M19 9l-7 7-7-7" />
              </svg>
            </button>
          </div>
        </div>

        {/* Swap Direction */}
        <div className="flex justify-center -my-2 relative z-10">
          <button
            onClick={swapDirection}
            className="rounded-xl border-4 border-body bg-surface-light p-2 hover:bg-surface-lighter transition-colors"
          >
            <svg className="h-4 w-4 text-gray-400" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M7 16V4m0 0L3 8m4-4l4 4m6 0v12m0 0l4-4m-4 4l-4-4" />
            </svg>
          </button>
        </div>

        {/* Token Out */}
        <div className="rounded-xl bg-surface-light p-4">
          <div className="mb-2">
            <span className="text-sm text-gray-500">You receive</span>
          </div>
          <div className="flex items-center gap-3">
            <input
              type="number"
              placeholder="0"
              readOnly
              className="flex-1 bg-transparent text-2xl font-medium text-white placeholder-gray-600 focus:outline-none"
            />
            <button
              onClick={() => setShowTokenSelect("out")}
              className={`flex items-center gap-2 rounded-full px-3 py-2 text-sm font-medium transition-colors ${
                tokenOut
                  ? "bg-surface-lighter hover:bg-surface-lighter/80"
                  : "bg-bastion-500 text-white hover:bg-bastion-400"
              }`}
            >
              {tokenOut ? (
                <>
                  <TokenIcon address={tokenOut.address} size={20} />
                  {tokenOut.symbol}
                </>
              ) : (
                "Select token"
              )}
              <svg className="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M19 9l-7 7-7-7" />
              </svg>
            </button>
          </div>
        </div>

        {/* Pool Info */}
        {tokenIn && tokenOut && (
          <div className="mt-3 flex items-center gap-2 px-1">
            <Badge variant="protected">Protected</Badge>
            <span className="text-xs text-gray-500">
              Bastion pool available for this pair
            </span>
          </div>
        )}

        {/* Swap Button */}
        <div className="mt-4">
          {!isConnected ? (
            <ConnectKitButton.Custom>
              {({ show }) => (
                <button onClick={show} className="btn-primary w-full py-4 text-base">
                  Connect Wallet
                </button>
              )}
            </ConnectKitButton.Custom>
          ) : !tokenIn || !tokenOut ? (
            <button disabled className="w-full rounded-xl bg-surface-light py-4 text-base font-semibold text-gray-500 cursor-not-allowed">
              Select Tokens
            </button>
          ) : !amountIn || parseFloat(amountIn) <= 0 ? (
            <button disabled className="w-full rounded-xl bg-surface-light py-4 text-base font-semibold text-gray-500 cursor-not-allowed">
              Enter Amount
            </button>
          ) : (
            <button
              disabled={isWriting || isConfirming}
              className="btn-primary w-full py-4 text-base"
            >
              {isWriting
                ? "Confirming..."
                : isConfirming
                  ? "Processing..."
                  : isSuccess
                    ? "Swapped!"
                    : "Swap"}
            </button>
          )}
        </div>

        {error && (
          <p className="mt-2 text-center text-sm text-red-400">
            {error.message.slice(0, 100)}
          </p>
        )}
      </Card>

      <TokenSelectModal
        isOpen={showTokenSelect !== null}
        onClose={() => setShowTokenSelect(null)}
        onSelect={(token) => {
          if (showTokenSelect === "in") setTokenIn(token);
          else setTokenOut(token);
        }}
      />
    </>
  );
}
