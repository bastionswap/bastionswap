"use client";

import { useState } from "react";
import { useAccount, useChainId } from "wagmi";
import { parseUnits, formatUnits } from "viem";
import { Card, CardHeader } from "@/components/ui/Card";
import { parseErrorMessage } from "@/utils/errorMessages";
import { LoadingSpinner } from "@/components/ui/LoadingSpinner";
import { useTokenInfo } from "@/hooks/useTokenInfo";
import { useTokenAllowance, useApprove, useTokenBalance } from "@/hooks/useSwap";
import {
  useUserPositions,
  useAddLiquidity,
  useRemoveLiquidity,
  useCollectFees,
  type SubgraphPosition,
} from "@/hooks/useLiquidity";
import type { SubgraphPool } from "@/hooks/usePools";

const PERMIT2_ADDRESS = "0x000000000022D473030F116dDEE9F6B43aC78BA3" as `0x${string}`;

interface LiquidityPanelProps {
  pool: SubgraphPool;
}

export function LiquidityPanel({ pool }: LiquidityPanelProps) {
  const { address } = useAccount();
  const chainId = useChainId();

  const token0Info = useTokenInfo(pool.token0 as `0x${string}`);
  const token1Info = useTokenInfo(pool.token1 as `0x${string}`);

  const { data: positions, refetch: refetchPositions } = useUserPositions(pool.id, address);

  const poolKey = {
    currency0: pool.token0 as `0x${string}`,
    currency1: pool.token1 as `0x${string}`,
    fee: 3000,
    tickSpacing: 60,
    hooks: pool.hook as `0x${string}`,
  };

  return (
    <Card>
      <CardHeader>
        <h3 className="text-base font-semibold text-gray-900">Liquidity</h3>
      </CardHeader>

      {/* Info banner */}
      <div className="mb-5 flex items-start gap-2.5 rounded-xl bg-blue-50 border border-blue-100 px-4 py-3">
        <svg className="h-4 w-4 text-blue-500 mt-0.5 shrink-0" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
          <path strokeLinecap="round" strokeLinejoin="round" d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
        </svg>
        <p className="text-xs text-blue-700/80">
          Your LP is <span className="font-semibold">not escrowed</span>. You can withdraw anytime. Only the issuer&apos;s LP is subject to vesting.
        </p>
      </div>

      {/* Your Positions */}
      {address && positions && positions.length > 0 && (
        <div className="mb-5">
          <p className="text-xs font-medium text-gray-500 uppercase tracking-wider mb-3">
            Your Positions
          </p>
          <div className="space-y-3">
            {positions.map((pos) => (
              <PositionCard
                key={pos.id}
                position={pos}
                poolKey={poolKey}
                token0Symbol={token0Info.symbol || "T0"}
                token1Symbol={token1Info.symbol || "T1"}
                onAction={refetchPositions}
              />
            ))}
          </div>
        </div>
      )}

      {/* Add Liquidity Form */}
      {address ? (
        <AddLiquidityForm
          poolKey={poolKey}
          token0Info={token0Info}
          token1Info={token1Info}
          pool={pool}
          onSuccess={refetchPositions}
        />
      ) : (
        <p className="text-sm text-gray-400 text-center py-4">
          Connect wallet to manage liquidity
        </p>
      )}
    </Card>
  );
}

// ─── Position Card ──────────────────────────────────

function PositionCard({
  position,
  poolKey,
  token0Symbol,
  token1Symbol,
  onAction,
}: {
  position: SubgraphPosition;
  poolKey: {
    currency0: `0x${string}`;
    currency1: `0x${string}`;
    fee: number;
    tickSpacing: number;
    hooks: `0x${string}`;
  };
  token0Symbol: string;
  token1Symbol: string;
  onAction: () => void;
}) {
  const [removePercent, setRemovePercent] = useState<number | null>(null);

  const {
    removeLiquidity,
    isWriting: isRemoving,
    isConfirming: isRemoveConfirming,
    isSuccess: removeSuccess,
    reset: resetRemove,
  } = useRemoveLiquidity();

  const {
    collectFees,
    isWriting: isCollecting,
    isConfirming: isCollectConfirming,
    isSuccess: collectSuccess,
    reset: resetCollect,
  } = useCollectFees();

  // Reset on success
  if (removeSuccess || collectSuccess) {
    setTimeout(() => {
      resetRemove();
      resetCollect();
      setRemovePercent(null);
      onAction();
    }, 2000);
  }

  const handleRemove = (pct: number) => {
    setRemovePercent(pct);
    const liquidity = BigInt(position.liquidity);
    const toRemove = (liquidity * BigInt(pct)) / 100n;

    removeLiquidity({
      poolKey,
      tickLower: position.tickLower,
      tickUpper: position.tickUpper,
      liquidityToRemove: toRemove,
      amount0Min: 0n,
      amount1Min: 0n,
      deadline: BigInt(Math.floor(Date.now() / 1000) + 1800),
    });
  };

  const handleCollect = () => {
    collectFees(poolKey, position.tickLower, position.tickUpper);
  };

  const isBusy = isRemoving || isRemoveConfirming || isCollecting || isCollectConfirming;

  return (
    <div className="rounded-xl border border-gray-100 bg-gray-50/50 p-4">
      <div className="flex items-center justify-between mb-3">
        <div>
          <span className="text-sm font-medium text-gray-900">
            {position.isFullRange ? "Full Range" : `${position.tickLower} / ${position.tickUpper}`}
          </span>
          <span className="text-xs text-gray-400 ml-2">
            {token0Symbol}/{token1Symbol}
          </span>
        </div>
        <span className="text-xs font-mono text-gray-500">
          {formatLiquidity(position.liquidity)} LP
        </span>
      </div>

      <div className="flex items-center gap-2 flex-wrap">
        {[25, 50, 75, 100].map((pct) => (
          <button
            key={pct}
            onClick={() => handleRemove(pct)}
            disabled={isBusy}
            className={`text-xs px-3 py-1.5 rounded-lg border transition-colors ${
              removePercent === pct && isBusy
                ? "border-red-300 bg-red-50 text-red-600"
                : "border-gray-200 hover:border-red-200 hover:bg-red-50 hover:text-red-600 text-gray-600"
            } disabled:opacity-50 disabled:cursor-not-allowed`}
          >
            {isBusy && removePercent === pct ? (
              <LoadingSpinner size="xs" />
            ) : (
              `Remove ${pct}%`
            )}
          </button>
        ))}
        <button
          onClick={handleCollect}
          disabled={isBusy}
          className="text-xs px-3 py-1.5 rounded-lg border border-gray-200 hover:border-emerald-200 hover:bg-emerald-50 hover:text-emerald-600 text-gray-600 transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
        >
          {isCollecting || isCollectConfirming ? <LoadingSpinner size="xs" /> : "Collect Fees"}
        </button>
      </div>

      {(removeSuccess || collectSuccess) && (
        <p className="text-xs text-emerald-600 mt-2">
          {removeSuccess ? "Liquidity removed!" : "Fees collected!"}
        </p>
      )}
    </div>
  );
}

// ─── Add Liquidity Form ──────────────────────────────────

function AddLiquidityForm({
  poolKey,
  token0Info,
  token1Info,
  pool,
  onSuccess,
}: {
  poolKey: {
    currency0: `0x${string}`;
    currency1: `0x${string}`;
    fee: number;
    tickSpacing: number;
    hooks: `0x${string}`;
  };
  token0Info: ReturnType<typeof useTokenInfo>;
  token1Info: ReturnType<typeof useTokenInfo>;
  pool: SubgraphPool;
  onSuccess: () => void;
}) {
  const { address } = useAccount();
  const [amount0, setAmount0] = useState("");
  const [amount1, setAmount1] = useState("");
  const [rangeMode, setRangeMode] = useState<"full" | "custom">("full");

  const isNative0 = poolKey.currency0 === "0x0000000000000000000000000000000000000000";
  const isNative1 = poolKey.currency1 === "0x0000000000000000000000000000000000000000";

  // Check Permit2 allowances for ERC20 tokens
  const { allowance: allowance0, refetch: refetchAllowance0 } = useTokenAllowance(
    isNative0 ? undefined : poolKey.currency0,
    address,
    PERMIT2_ADDRESS
  );
  const { allowance: allowance1, refetch: refetchAllowance1 } = useTokenAllowance(
    isNative1 ? undefined : poolKey.currency1,
    address,
    PERMIT2_ADDRESS
  );

  const { balance: balance0 } = useTokenBalance(poolKey.currency0, address);
  const { balance: balance1 } = useTokenBalance(poolKey.currency1, address);

  const { approve, isPending: isApproving, isConfirming: isApproveConfirming, isSuccess: approveSuccess, reset: resetApprove } = useApprove();
  const { addLiquidity, isWriting, isConfirming, isSuccess, error, reset: resetAdd } = useAddLiquidity();

  if (approveSuccess) {
    setTimeout(() => {
      resetApprove();
      refetchAllowance0();
      refetchAllowance1();
    }, 2000);
  }

  if (isSuccess) {
    setTimeout(() => {
      resetAdd();
      setAmount0("");
      setAmount1("");
      onSuccess();
    }, 2000);
  }

  const decimals0 = token0Info.decimals ?? 18;
  const decimals1 = token1Info.decimals ?? 18;

  const parsed0 = amount0 ? parseUnits(amount0, decimals0) : 0n;
  const parsed1 = amount1 ? parseUnits(amount1, decimals1) : 0n;

  const needsApproval0 = !isNative0 && parsed0 > 0n && (allowance0 === undefined || allowance0 < parsed0);
  const needsApproval1 = !isNative1 && parsed1 > 0n && (allowance1 === undefined || allowance1 < parsed1);

  const insufficientBalance0 = balance0 !== undefined && parsed0 > balance0;
  const insufficientBalance1 = balance1 !== undefined && parsed1 > balance1;

  const canSubmit = (parsed0 > 0n || parsed1 > 0n) && !insufficientBalance0 && !insufficientBalance1;

  const handleAdd = () => {
    if (!canSubmit) return;

    addLiquidity({
      poolKey,
      tickLower: 0, // full range
      tickUpper: 0,
      amount0Max: parsed0,
      amount1Max: parsed1,
      deadline: BigInt(Math.floor(Date.now() / 1000) + 1800),
      value: isNative0 ? parsed0 : isNative1 ? parsed1 : undefined,
    });
  };

  const isBusy = isWriting || isConfirming || isApproving || isApproveConfirming;

  return (
    <div>
      <p className="text-xs font-medium text-gray-500 uppercase tracking-wider mb-3">
        Add Liquidity
      </p>

      {/* Range selector */}
      <div className="flex gap-2 mb-4">
        <button
          onClick={() => setRangeMode("full")}
          className={`text-xs px-3 py-1.5 rounded-lg border transition-colors ${
            rangeMode === "full"
              ? "border-bastion-300 bg-bastion-50 text-bastion-700 font-medium"
              : "border-gray-200 text-gray-500 hover:border-gray-300"
          }`}
        >
          Full Range
        </button>
        <button
          disabled
          className="text-xs px-3 py-1.5 rounded-lg border border-gray-100 text-gray-300 cursor-not-allowed"
          title="Coming soon"
        >
          Custom Range
        </button>
      </div>

      {/* Amount inputs */}
      <div className="space-y-3 mb-4">
        <div>
          <div className="flex items-center justify-between mb-1">
            <label className="text-xs text-gray-500">{token0Info.symbol || "Token 0"}</label>
            {balance0 !== undefined && (
              <button
                onClick={() => setAmount0(formatUnits(balance0, decimals0))}
                className="text-xs text-gray-400 hover:text-gray-600"
              >
                Balance: {parseFloat(formatUnits(balance0, decimals0)).toFixed(4)}
              </button>
            )}
          </div>
          <input
            type="text"
            inputMode="decimal"
            placeholder="0.0"
            value={amount0}
            onChange={(e) => setAmount0(e.target.value)}
            className={`w-full rounded-lg border px-3 py-2 text-sm tabular-nums ${
              insufficientBalance0 ? "border-red-300 bg-red-50" : "border-gray-200"
            }`}
          />
        </div>
        <div>
          <div className="flex items-center justify-between mb-1">
            <label className="text-xs text-gray-500">{token1Info.symbol || "Token 1"}</label>
            {balance1 !== undefined && (
              <button
                onClick={() => setAmount1(formatUnits(balance1, decimals1))}
                className="text-xs text-gray-400 hover:text-gray-600"
              >
                Balance: {parseFloat(formatUnits(balance1, decimals1)).toFixed(4)}
              </button>
            )}
          </div>
          <input
            type="text"
            inputMode="decimal"
            placeholder="0.0"
            value={amount1}
            onChange={(e) => setAmount1(e.target.value)}
            className={`w-full rounded-lg border px-3 py-2 text-sm tabular-nums ${
              insufficientBalance1 ? "border-red-300 bg-red-50" : "border-gray-200"
            }`}
          />
        </div>
      </div>

      {/* Action buttons */}
      {needsApproval0 && (
        <button
          onClick={() => approve(poolKey.currency0, PERMIT2_ADDRESS, parsed0)}
          disabled={isBusy}
          className="w-full btn-secondary text-sm py-2.5 mb-2"
        >
          {isApproving || isApproveConfirming ? (
            <span className="flex items-center justify-center gap-2">
              <LoadingSpinner size="sm" /> Approving {token0Info.symbol}...
            </span>
          ) : (
            `Approve ${token0Info.symbol}`
          )}
        </button>
      )}
      {needsApproval1 && (
        <button
          onClick={() => approve(poolKey.currency1, PERMIT2_ADDRESS, parsed1)}
          disabled={isBusy}
          className="w-full btn-secondary text-sm py-2.5 mb-2"
        >
          {isApproving || isApproveConfirming ? (
            <span className="flex items-center justify-center gap-2">
              <LoadingSpinner size="sm" /> Approving {token1Info.symbol}...
            </span>
          ) : (
            `Approve ${token1Info.symbol}`
          )}
        </button>
      )}

      <button
        onClick={handleAdd}
        disabled={!canSubmit || needsApproval0 || needsApproval1 || isBusy}
        className="w-full btn-primary text-sm py-2.5"
      >
        {isWriting || isConfirming ? (
          <span className="flex items-center justify-center gap-2">
            <LoadingSpinner size="sm" /> {isWriting ? "Confirm in wallet..." : "Adding liquidity..."}
          </span>
        ) : insufficientBalance0 || insufficientBalance1 ? (
          "Insufficient balance"
        ) : !canSubmit ? (
          "Enter amounts"
        ) : (
          "Add Liquidity"
        )}
      </button>

      {isSuccess && (
        <p className="text-xs text-emerald-600 mt-2 text-center">Liquidity added successfully!</p>
      )}
      {error && (
        <p className="text-xs text-red-500 mt-2 text-center">
          {parseErrorMessage(error)}
        </p>
      )}
    </div>
  );
}

function formatLiquidity(liq: string): string {
  const n = parseFloat(formatUnits(BigInt(liq), 18));
  if (n >= 1_000_000) return (n / 1_000_000).toFixed(2) + "M";
  if (n >= 1_000) return (n / 1_000).toFixed(2) + "K";
  return n.toFixed(4);
}
