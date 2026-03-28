"use client";

import { useState } from "react";
import { useAccount, useChainId, useReadContract, useWriteContract, usePublicClient } from "wagmi";
import { parseUnits, formatUnits, maxUint256 } from "viem";
import { Card, CardHeader } from "@/components/ui/Card";
import { parseErrorMessage } from "@/utils/errorMessages";
import { LoadingSpinner } from "@/components/ui/LoadingSpinner";
import { useTokenInfo } from "@/hooks/useTokenInfo";
import { usePoolSqrtPrice } from "@/hooks/usePoolSqrtPrice";
import { computePairedAmount } from "@/utils/price";
import { useTokenAllowance, useTokenBalance } from "@/hooks/useSwap";
import { getContracts } from "@/config/contracts";
import { BastionPositionRouterABI, EscrowVaultABI } from "@/config/abis";
import BastionHookAbi from "@/config/abis/BastionHook.json";
import {
  useUserPositions,
  useAddLiquidity,
  useRemoveLiquidity,
  useRemoveIssuerLiquidity,
  useCollectFees,
  useCollectIssuerFees,
  type SubgraphPosition,
} from "@/hooks/useLiquidity";
import type { SubgraphPool } from "@/hooks/usePools";

const PERMIT2_ADDRESS = "0x000000000022D473030F116dDEE9F6B43aC78BA3" as `0x${string}`;

const ERC20_APPROVE_ABI = [
  {
    type: "function" as const,
    name: "approve" as const,
    inputs: [
      { name: "spender", type: "address" as const },
      { name: "amount", type: "uint256" as const },
    ],
    outputs: [{ type: "bool" as const }],
    stateMutability: "nonpayable" as const,
  },
] as const;

interface LiquidityPanelProps {
  pool: SubgraphPool;
}

export function LiquidityPanel({ pool }: LiquidityPanelProps) {
  const { address } = useAccount();
  const chainId = useChainId();

  const token0Info = useTokenInfo(pool.token0 as `0x${string}`);
  const token1Info = useTokenInfo(pool.token1 as `0x${string}`);

  const { data: positions, refetch: refetchPositions } = useUserPositions(pool.id, address);
  const isIssuer = !!pool.issuer && !!address && pool.issuer.id.toLowerCase() === address.toLowerCase();

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
      {isIssuer ? (
        <div className="mb-5 flex items-start gap-2.5 rounded-xl bg-amber-50 border border-amber-200 px-4 py-3">
          <svg className="h-4 w-4 text-amber-500 mt-0.5 shrink-0" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
            <path strokeLinecap="round" strokeLinejoin="round" d="M12 9v2m0 4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
          </svg>
          <p className="text-xs text-amber-800/80">
            Your LP is <span className="font-semibold">escrowed</span> and subject to vesting. Removal is limited by daily/weekly caps.
          </p>
        </div>
      ) : (
        <div className="mb-5 flex items-start gap-2.5 rounded-xl bg-bastion-50 border border-bastion-100 px-4 py-3">
          <svg className="h-4 w-4 text-bastion-500 mt-0.5 shrink-0" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
            <path strokeLinecap="round" strokeLinejoin="round" d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
          </svg>
          <p className="text-xs text-bastion-800/80">
            Your LP is <span className="font-semibold">not escrowed</span>. You can withdraw anytime.
          </p>
        </div>
      )}

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
                pool={pool}
                token0Symbol={token0Info.symbol || "T0"}
                token1Symbol={token1Info.symbol || "T1"}
                token0Decimals={token0Info.decimals ?? 18}
                token1Decimals={token1Info.decimals ?? 18}
                isIssuer={isIssuer}
                owner={address!}
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
          isIssuer={isIssuer}
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

function formatFeeAmount(raw: bigint, decimals: number): string {
  const val = Number(formatUnits(raw, decimals));
  if (val === 0) return "0";
  if (val < 0.0001) return "<0.0001";
  if (val < 1) return val.toLocaleString(undefined, { maximumFractionDigits: 6 });
  if (val < 1000) return val.toLocaleString(undefined, { maximumFractionDigits: 4 });
  return val.toLocaleString(undefined, { maximumFractionDigits: 2 });
}

function PositionCard({
  position,
  poolKey,
  pool,
  token0Symbol,
  token1Symbol,
  token0Decimals,
  token1Decimals,
  isIssuer,
  owner,
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
  pool: SubgraphPool;
  token0Symbol: string;
  token1Symbol: string;
  token0Decimals: number;
  token1Decimals: number;
  isIssuer: boolean;
  owner: `0x${string}`;
  onAction: () => void;
}) {
  const [removePercent, setRemovePercent] = useState<number | null>(null);
  const [issuerRemoveInput, setIssuerRemoveInput] = useState("");

  const {
    removeLiquidity,
    isWriting: isRemoving,
    isConfirming: isRemoveConfirming,
    isSuccess: removeSuccess,
    error: removeError,
    reset: resetRemove,
  } = useRemoveLiquidity();

  const {
    removeIssuerLiquidity,
    isWriting: isIssuerRemoving,
    isConfirming: isIssuerRemoveConfirming,
    isSuccess: issuerRemoveSuccess,
    error: issuerRemoveError,
    reset: resetIssuerRemove,
  } = useRemoveIssuerLiquidity();

  const {
    collectFees,
    isWriting: isCollecting,
    isConfirming: isCollectConfirming,
    isSuccess: collectSuccess,
    error: collectError,
    reset: resetCollect,
  } = useCollectFees();

  const {
    collectIssuerFees,
    isWriting: isIssuerCollecting,
    isConfirming: isIssuerCollectConfirming,
    isSuccess: issuerCollectSuccess,
    error: issuerCollectError,
    reset: resetIssuerCollect,
  } = useCollectIssuerFees();

  // Reset on success
  if (removeSuccess || collectSuccess || issuerCollectSuccess || issuerRemoveSuccess) {
    setTimeout(() => {
      resetRemove();
      resetCollect();
      resetIssuerCollect();
      resetIssuerRemove();
      setRemovePercent(null);
      setIssuerRemoveInput("");
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

  const handleIssuerRemove = (amount: bigint) => {
    removeIssuerLiquidity({
      poolKey,
      liquidityToRemove: amount,
      amount0Min: 0n,
      amount1Min: 0n,
      deadline: BigInt(Math.floor(Date.now() / 1000) + 1800),
    });
  };

  const handleCollect = () => {
    collectFees(poolKey, position.tickLower, position.tickUpper);
  };

  const handleIssuerCollect = () => {
    collectIssuerFees(poolKey);
  };

  const isBusy = isRemoving || isRemoveConfirming || isCollecting || isCollectConfirming || isIssuerCollecting || isIssuerCollectConfirming || isIssuerRemoving || isIssuerRemoveConfirming;

  // Uncollected fees query
  const chainId = useChainId();
  const contracts = getContracts(chainId);
  const { data: feeResult } = useReadContract({
    address: contracts?.BastionPositionRouter as `0x${string}`,
    abi: BastionPositionRouterABI,
    functionName: isIssuer ? "getIssuerUnclaimedFees" : "getUnclaimedFees",
    args: isIssuer
      ? [poolKey]
      : [poolKey, owner, position.tickLower, position.tickUpper],
    query: {
      enabled: !!contracts,
      refetchInterval: 30_000,
    },
  });
  const fees = feeResult as [bigint, bigint] | undefined;
  const [fees0, fees1] = fees ?? [0n, 0n];
  const hasFees = fees0 > 0n || fees1 > 0n;

  // ── Issuer-specific on-chain data ──
  const escrowId = pool.escrow?.id ? BigInt(pool.escrow.id) : undefined;
  const hookAddress = contracts?.BastionHook as `0x${string}` | undefined;

  // Removable liquidity from EscrowVault (vesting-based)
  const { data: removableLiq } = useReadContract({
    address: contracts?.EscrowVault as `0x${string}`,
    abi: EscrowVaultABI,
    functionName: "getRemovableLiquidity",
    args: escrowId !== undefined ? [escrowId] : undefined,
    query: { enabled: isIssuer && escrowId !== undefined && !!contracts, refetchInterval: 30_000 },
  });

  // Pool commitment (for daily/weekly limits)
  const { data: poolCommitment } = useReadContract({
    address: hookAddress,
    abi: BastionHookAbi,
    functionName: "getPoolCommitment",
    args: [pool.id as `0x${string}`],
    query: { enabled: isIssuer && !!hookAddress, refetchInterval: 60_000 },
  });

  // LP removal tracking
  const poolIdArg = [pool.id as `0x${string}`] as const;
  const trackOpts = { enabled: isIssuer && !!hookAddress, refetchInterval: 15_000 };
  const { data: rawDailyLpRem } = useReadContract({ address: hookAddress, abi: BastionHookAbi, functionName: "dailyLpRemoved", args: poolIdArg, query: trackOpts });
  const { data: rawWeeklyLpRem } = useReadContract({ address: hookAddress, abi: BastionHookAbi, functionName: "weeklyLpRemoved", args: poolIdArg, query: trackOpts });
  const { data: rawDailyLpWin } = useReadContract({ address: hookAddress, abi: BastionHookAbi, functionName: "dailyLpWindowStart", args: poolIdArg, query: trackOpts });
  const { data: rawWeeklyLpWin } = useReadContract({ address: hookAddress, abi: BastionHookAbi, functionName: "weeklyLpWindowStart", args: poolIdArg, query: trackOpts });
  const { data: rawInitLiq } = useReadContract({ address: hookAddress, abi: BastionHookAbi, functionName: "initialLiquidity", args: poolIdArg, query: trackOpts });

  // Compute issuer removal limits
  const pc = poolCommitment as { maxDailyLpRemovalBps?: number | bigint; maxWeeklyLpRemovalBps?: number | bigint } | undefined;
  const initLiq = rawInitLiq ? BigInt(rawInitLiq as bigint) : 0n;
  const maxDailyBps = pc ? Number(pc.maxDailyLpRemovalBps ?? 0) : 0;
  const maxWeeklyBps = pc ? Number(pc.maxWeeklyLpRemovalBps ?? 0) : 0;

  const now = Math.floor(Date.now() / 1000);
  const dailyWindowStart = Number(rawDailyLpWin ?? 0);
  const weeklyWindowStart = Number(rawWeeklyLpWin ?? 0);
  const dailyWindowExpired = dailyWindowStart > 0 && now >= dailyWindowStart + 86400;
  const weeklyWindowExpired = weeklyWindowStart > 0 && now >= weeklyWindowStart + 604800;

  const dailyUsed = dailyWindowExpired ? 0n : BigInt(rawDailyLpRem as bigint ?? 0n);
  const weeklyUsed = weeklyWindowExpired ? 0n : BigInt(rawWeeklyLpRem as bigint ?? 0n);

  const dailyMax = initLiq > 0n && maxDailyBps > 0 ? (initLiq * BigInt(maxDailyBps)) / 10000n : 0n;
  const weeklyMax = initLiq > 0n && maxWeeklyBps > 0 ? (initLiq * BigInt(maxWeeklyBps)) / 10000n : 0n;

  const dailyRemaining = dailyMax > dailyUsed ? dailyMax - dailyUsed : 0n;
  const weeklyRemaining = weeklyMax > weeklyUsed ? weeklyMax - weeklyUsed : 0n;

  // Effective max removable = min(vested removable, daily remaining, weekly remaining)
  const vestedRemovable = removableLiq ? BigInt(removableLiq as bigint) : 0n;
  const effectiveMax = (() => {
    let max = vestedRemovable;
    if (dailyMax > 0n && dailyRemaining < max) max = dailyRemaining;
    if (weeklyMax > 0n && weeklyRemaining < max) max = weeklyRemaining;
    return max;
  })();

  // Vesting phase info
  const escrowCreatedAt = pool.escrow?.createdAt ? parseInt(pool.escrow.createdAt) : 0;
  const lockDuration = pool.escrow?.lockDuration ? parseInt(pool.escrow.lockDuration) : 0;
  const vestingDuration = pool.escrow?.vestingDuration ? parseInt(pool.escrow.vestingDuration) : 0;
  const lockEndTs = escrowCreatedAt + lockDuration;
  const vestEndTs = escrowCreatedAt + lockDuration + vestingDuration;
  const isLocked = escrowCreatedAt > 0 && now < lockEndTs;
  const isVesting = escrowCreatedAt > 0 && now >= lockEndTs && now < vestEndTs;
  const isFullyVested = escrowCreatedAt > 0 && now >= vestEndTs;

  // Parse issuer removal input
  let issuerRemoveAmount = 0n;
  try {
    if (issuerRemoveInput) issuerRemoveAmount = parseUnits(issuerRemoveInput, 18);
  } catch {}
  const canIssuerRemove = issuerRemoveAmount > 0n && issuerRemoveAmount <= effectiveMax;

  return (
    <div className="rounded-xl border border-gray-100 bg-gray-50/50 p-4">
      <div className="flex items-center justify-between mb-2">
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

      {/* Uncollected Fees */}
      <div className={`flex items-center justify-end gap-1.5 text-[11px] mb-3 ${hasFees ? "text-green-600" : "text-gray-400"}`}>
        <svg className="h-3 w-3" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
          <path strokeLinecap="round" strokeLinejoin="round" d="M12 6v12m-3-2.818l.879.659c1.171.879 3.07.879 4.242 0 1.172-.879 1.172-2.303 0-3.182C13.536 12.219 12.768 12 12 12c-.725 0-1.45-.22-2.003-.659-1.106-.879-1.106-2.303 0-3.182s2.9-.879 4.006 0l.415.33M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
        </svg>
        <span className="tabular-nums">
          {hasFees ? (
            <>
              {fees0 > 0n && `${formatFeeAmount(fees0, token0Decimals)} ${token0Symbol}`}
              {fees0 > 0n && fees1 > 0n && " + "}
              {fees1 > 0n && `${formatFeeAmount(fees1, token1Decimals)} ${token1Symbol}`}
            </>
          ) : (
            `0 ${token0Symbol} + 0 ${token1Symbol}`
          )}
        </span>
      </div>

      {isIssuer ? (
        <div className="space-y-3">
          {/* Collect Fees */}
          <button
            onClick={handleIssuerCollect}
            disabled={isBusy || !hasFees}
            className="text-xs px-3 py-1.5 rounded-lg border border-gray-200 hover:border-emerald-200 hover:bg-emerald-50 hover:text-emerald-600 text-gray-600 transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
          >
            {isIssuerCollecting || isIssuerCollectConfirming ? <LoadingSpinner size="sm" /> : "Collect Fees"}
          </button>

          {/* ── Issuer LP Removal Section ── */}
          <div className="border-t border-gray-200 pt-3">
            <p className="text-[11px] font-medium text-gray-500 uppercase tracking-wider mb-2">
              Remove Escrowed LP
            </p>

            {/* Vesting Phase Status */}
            {isLocked && (
              <div className="flex items-center gap-2 rounded-lg bg-amber-50 border border-amber-200 px-3 py-2 mb-2">
                <svg className="h-3.5 w-3.5 text-amber-500 shrink-0" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2}>
                  <path strokeLinecap="round" strokeLinejoin="round" d="M16.5 10.5V6.75a4.5 4.5 0 10-9 0v3.75m-.75 11.25h10.5a2.25 2.25 0 002.25-2.25v-6.75a2.25 2.25 0 00-2.25-2.25H6.75a2.25 2.25 0 00-2.25 2.25v6.75a2.25 2.25 0 002.25 2.25z" />
                </svg>
                <span className="text-[11px] text-amber-700">
                  LP is locked until {new Date(lockEndTs * 1000).toLocaleDateString("en-US", { month: "short", day: "numeric" })} ({Math.ceil((lockEndTs - now) / 86400)}d remaining)
                </span>
              </div>
            )}

            {isVesting && (
              <div className="flex items-center gap-2 rounded-lg bg-emerald-50 border border-emerald-100 px-3 py-2 mb-2">
                <svg className="h-3.5 w-3.5 text-emerald-500 shrink-0" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2}>
                  <path strokeLinecap="round" strokeLinejoin="round" d="M12 6v6h4.5m4.5 0a9 9 0 11-18 0 9 9 0 0118 0z" />
                </svg>
                <span className="text-[11px] text-emerald-700">
                  Linear vesting active — fully vested {new Date(vestEndTs * 1000).toLocaleDateString("en-US", { month: "short", day: "numeric" })}
                </span>
              </div>
            )}

            {isFullyVested && (
              <div className="flex items-center gap-2 rounded-lg bg-gray-50 border border-gray-200 px-3 py-2 mb-2">
                <svg className="h-3.5 w-3.5 text-emerald-500 shrink-0" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2}>
                  <path strokeLinecap="round" strokeLinejoin="round" d="M9 12.75L11.25 15 15 9.75M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
                </svg>
                <span className="text-[11px] text-gray-600">Fully vested</span>
              </div>
            )}

            {/* Removable amount info */}
            {!isLocked && (
              <>
                <div className="grid grid-cols-2 gap-2 mb-2">
                  <div className="rounded-lg bg-white border border-gray-100 px-2.5 py-2">
                    <p className="text-[10px] text-gray-400">Vested Removable</p>
                    <p className="text-xs font-semibold text-gray-900 tabular-nums">{formatLiquidity(vestedRemovable.toString())} LP</p>
                  </div>
                  <div className="rounded-lg bg-white border border-gray-100 px-2.5 py-2">
                    <p className="text-[10px] text-gray-400">Available Now</p>
                    <p className="text-xs font-semibold text-bastion-600 tabular-nums">{formatLiquidity(effectiveMax.toString())} LP</p>
                  </div>
                </div>

                {/* Daily/Weekly Usage Bars */}
                {(maxDailyBps > 0 || maxWeeklyBps > 0) && initLiq > 0n && (
                  <div className="space-y-1.5 mb-3">
                    {maxDailyBps > 0 && (
                      <LpUsageBar
                        used={dailyUsed}
                        max={dailyMax}
                        label="Daily"
                        windowStart={dailyWindowStart}
                        windowDuration={86400}
                      />
                    )}
                    {maxWeeklyBps > 0 && (
                      <LpUsageBar
                        used={weeklyUsed}
                        max={weeklyMax}
                        label="Weekly"
                        windowStart={weeklyWindowStart}
                        windowDuration={604800}
                      />
                    )}
                  </div>
                )}

                {/* Removal Input */}
                <div className="space-y-2">
                  <div className="flex items-center gap-2">
                    <input
                      type="text"
                      inputMode="decimal"
                      placeholder="0.0"
                      value={issuerRemoveInput}
                      onChange={(e) => setIssuerRemoveInput(e.target.value)}
                      className="flex-1 rounded-lg border border-gray-200 px-2.5 py-1.5 text-xs tabular-nums"
                    />
                    <span className="text-[10px] text-gray-400">LP</span>
                  </div>

                  {/* Quick-fill buttons */}
                  <div className="flex gap-1.5">
                    {[25, 50, 75, 100].map((pct) => {
                      const amt = (effectiveMax * BigInt(pct)) / 100n;
                      return (
                        <button
                          key={pct}
                          onClick={() => setIssuerRemoveInput(amt > 0n ? formatUnits(amt, 18) : "0")}
                          disabled={effectiveMax === 0n}
                          className="flex-1 text-[10px] py-1 rounded-md border border-gray-200 text-gray-500 hover:border-bastion-200 hover:text-bastion-600 hover:bg-bastion-50 transition-colors disabled:opacity-40 disabled:cursor-not-allowed"
                        >
                          {pct}%
                        </button>
                      );
                    })}
                  </div>

                  {/* Remove button */}
                  <button
                    onClick={() => handleIssuerRemove(issuerRemoveAmount)}
                    disabled={isBusy || !canIssuerRemove}
                    className="w-full text-xs py-2 rounded-lg border border-red-200 bg-red-50 text-red-600 font-medium hover:bg-red-100 transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
                  >
                    {isIssuerRemoving || isIssuerRemoveConfirming ? (
                      <span className="flex items-center justify-center gap-1.5">
                        <LoadingSpinner size="sm" />
                        {isIssuerRemoving ? "Confirm in wallet..." : "Removing..."}
                      </span>
                    ) : effectiveMax === 0n ? (
                      isLocked ? "LP is locked" : "No removable LP"
                    ) : !canIssuerRemove ? (
                      "Enter amount"
                    ) : (
                      "Remove LP"
                    )}
                  </button>

                  {issuerRemoveAmount > effectiveMax && effectiveMax > 0n && (
                    <p className="text-[10px] text-red-500">
                      Exceeds available amount ({formatLiquidity(effectiveMax.toString())} LP)
                    </p>
                  )}
                </div>
              </>
            )}
          </div>
        </div>
      ) : (
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
                <LoadingSpinner size="sm" />
              ) : (
                `Remove ${pct}%`
              )}
            </button>
          ))}
          <button
            onClick={handleCollect}
            disabled={isBusy || !hasFees}
            className="text-xs px-3 py-1.5 rounded-lg border border-gray-200 hover:border-emerald-200 hover:bg-emerald-50 hover:text-emerald-600 text-gray-600 transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
          >
            {isCollecting || isCollectConfirming ? <LoadingSpinner size="sm" /> : "Collect Fees"}
          </button>
        </div>
      )}

      {(removeSuccess || collectSuccess || issuerCollectSuccess || issuerRemoveSuccess) && (
        <p className="text-xs text-emerald-600 mt-2">
          {removeSuccess || issuerRemoveSuccess ? "Liquidity removed!" : "Fees collected!"}
        </p>
      )}

      {(removeError || collectError || issuerCollectError || issuerRemoveError) && (
        <p className="text-xs text-red-500 mt-2">
          {parseErrorMessage((removeError || collectError || issuerCollectError || issuerRemoveError) as Error)}
        </p>
      )}
    </div>
  );
}

// ─── LP Usage Bar (compact) ──────────────────────────────────

function LpUsageBar({ used, max, label, windowStart, windowDuration }: {
  used: bigint;
  max: bigint;
  label: string;
  windowStart: number;
  windowDuration: number;
}) {
  const pct = max > 0n ? Number((used * 10000n) / max) / 100 : 0;
  const isNearLimit = pct >= 80;
  const isAtLimit = pct >= 100;

  const now = Math.floor(Date.now() / 1000);
  const resetTime = windowStart > 0 ? windowStart + windowDuration : 0;
  const timeLeft = resetTime > now ? resetTime - now : 0;
  const isDaily = windowDuration <= 86400;

  const resetLabel = timeLeft > 0
    ? isDaily
      ? `${Math.floor(timeLeft / 3600)}h ${Math.floor((timeLeft % 3600) / 60)}m`
      : `${Math.floor(timeLeft / 86400)}d ${Math.floor((timeLeft % 86400) / 3600)}h`
    : "";

  return (
    <div>
      <div className="flex items-center justify-between text-[10px] mb-0.5">
        <span className="text-gray-400">{label}</span>
        <span className={`tabular-nums ${isAtLimit ? "text-red-500" : isNearLimit ? "text-amber-500" : "text-gray-500"}`}>
          {formatLiquidity(used.toString())} / {formatLiquidity(max.toString())}
        </span>
      </div>
      <div className="h-1 rounded-full bg-gray-100 overflow-hidden">
        <div
          className={`h-full rounded-full transition-all duration-500 ${
            isAtLimit ? "bg-red-500" : isNearLimit ? "bg-amber-400" : "bg-bastion-400"
          }`}
          style={{ width: `${Math.min(pct, 100)}%` }}
        />
      </div>
      {resetLabel && (
        <p className="text-[9px] text-gray-400 mt-0.5">Resets in {resetLabel}</p>
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
  isIssuer,
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
  isIssuer: boolean;
  onSuccess: () => void;
}) {
  const { address } = useAccount();
  const chainId = useChainId();
  const contracts = getContracts(chainId);
  const [amount0, setAmount0] = useState("");
  const [amount1, setAmount1] = useState("");
  const [rangeMode, setRangeMode] = useState<"full" | "custom">("full");
  const { sqrtPriceX96 } = usePoolSqrtPrice(pool.id);

  const isNative0 = poolKey.currency0 === "0x0000000000000000000000000000000000000000";
  const isNative1 = poolKey.currency1 === "0x0000000000000000000000000000000000000000";

  // Issuer approves the router directly; non-issuer approves Permit2
  const approvalTarget = isIssuer
    ? (contracts?.BastionPositionRouter as `0x${string}`)
    : PERMIT2_ADDRESS;

  // Check allowances for ERC20 tokens
  const { allowance: allowance0, refetch: refetchAllowance0 } = useTokenAllowance(
    isNative0 ? undefined : poolKey.currency0,
    address,
    approvalTarget
  );
  const { allowance: allowance1, refetch: refetchAllowance1 } = useTokenAllowance(
    isNative1 ? undefined : poolKey.currency1,
    address,
    approvalTarget
  );

  const { balance: balance0 } = useTokenBalance(poolKey.currency0, address);
  const { balance: balance1 } = useTokenBalance(poolKey.currency1, address);

  // Fetch uncollected fees to show auto-collection notice
  const { data: feeResult } = useReadContract({
    address: contracts?.BastionPositionRouter as `0x${string}`,
    abi: BastionPositionRouterABI,
    functionName: isIssuer ? "getIssuerUnclaimedFees" : "getUnclaimedFees",
    args: isIssuer
      ? [poolKey]
      : [poolKey, address, 0, 0],
    query: { enabled: !!contracts && !!address, refetchInterval: 30_000 },
  });
  const pendingFees = feeResult as [bigint, bigint] | undefined;
  const [pendingFees0, pendingFees1] = pendingFees ?? [0n, 0n];
  const hasPendingFees = pendingFees0 > 0n || pendingFees1 > 0n;

  const { addLiquidity, isWriting, isConfirming, isSuccess, error, reset: resetAdd } = useAddLiquidity();
  const { writeContractAsync } = useWriteContract();
  const publicClient = usePublicClient();
  const [autoApprovePhase, setAutoApprovePhase] = useState<"idle" | "approving" | "adding">("idle");
  const [autoApproveError, setAutoApproveError] = useState<Error | null>(null);

  if (isSuccess) {
    setTimeout(() => {
      resetAdd();
      setAmount0("");
      setAmount1("");
      setAutoApprovePhase("idle");
      onSuccess();
    }, 2000);
  }

  const decimals0 = token0Info.decimals ?? 18;
  const decimals1 = token1Info.decimals ?? 18;

  // Auto-calculate paired amount given an input value string
  const calcPaired = (value: string, isToken0: boolean): string => {
    if (!sqrtPriceX96 || !value || parseFloat(value) === 0) return "";
    try {
      const parsed = parseUnits(value, isToken0 ? decimals0 : decimals1);
      const paired = computePairedAmount(sqrtPriceX96, parsed, isToken0, decimals0, decimals1);
      if (paired === 0n) return "";
      const formatted = formatUnits(paired, isToken0 ? decimals1 : decimals0);
      // Trim trailing zeros for clean display
      const num = parseFloat(formatted);
      if (num === 0) return "";
      // Avoid scientific notation (e.g. "1e-9") which parseUnits can't handle
      return num.toFixed(isToken0 ? decimals1 : decimals0).replace(/\.?0+$/, "");
    } catch {
      return "";
    }
  };

  const handleAmount0Change = (value: string) => {
    setAmount0(value);
    setAmount1(calcPaired(value, true));
  };

  const handleAmount1Change = (value: string) => {
    setAmount1(value);
    setAmount0(calcPaired(value, false));
  };

  let parsed0 = 0n;
  let parsed1 = 0n;
  try { if (amount0) parsed0 = parseUnits(amount0, decimals0); } catch {}
  try { if (amount1) parsed1 = parseUnits(amount1, decimals1); } catch {}

  const needsApproval0 = !isNative0 && parsed0 > 0n && (allowance0 === undefined || allowance0 < parsed0);
  const needsApproval1 = !isNative1 && parsed1 > 0n && (allowance1 === undefined || allowance1 < parsed1);

  const insufficientBalance0 = balance0 !== undefined && parsed0 > balance0;
  const insufficientBalance1 = balance1 !== undefined && parsed1 > balance1;

  const canSubmit = (parsed0 > 0n || parsed1 > 0n) && !insufficientBalance0 && !insufficientBalance1;

  const handleAdd = async () => {
    if (!canSubmit || !contracts) return;
    setAutoApproveError(null);

    try {
      // Auto-approve ERC20s if needed
      // Issuer: approve to router; Non-issuer: approve to Permit2
      let didApprove = false;

      if (needsApproval0) {
        setAutoApprovePhase("approving");
        const hash = await writeContractAsync({
          address: poolKey.currency0,
          abi: ERC20_APPROVE_ABI,
          functionName: "approve",
          args: [approvalTarget, maxUint256],
        });
        await publicClient!.waitForTransactionReceipt({ hash });
        refetchAllowance0();
        didApprove = true;
      }

      if (needsApproval1) {
        setAutoApprovePhase("approving");
        const hash = await writeContractAsync({
          address: poolKey.currency1,
          abi: ERC20_APPROVE_ABI,
          functionName: "approve",
          args: [approvalTarget, maxUint256],
        });
        await publicClient!.waitForTransactionReceipt({ hash });
        refetchAllowance1();
        didApprove = true;
      }

      // Wait for RPC state to reflect the approval before simulating next tx
      if (didApprove) {
        await new Promise((r) => setTimeout(r, 2000));
      }

      setAutoApprovePhase("adding");
      addLiquidity({
        poolKey,
        tickLower: 0, // full range
        tickUpper: 0,
        amount0Max: parsed0,
        amount1Max: parsed1,
        deadline: BigInt(Math.floor(Date.now() / 1000) + 1800),
        value: isNative0 ? parsed0 : isNative1 ? parsed1 : undefined,
        isIssuer,
      });
    } catch (err) {
      setAutoApproveError(err as Error);
      setAutoApprovePhase("idle");
    }
  };

  const isBusy = isWriting || isConfirming || autoApprovePhase !== "idle";

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
                onClick={() => handleAmount0Change(formatUnits(balance0, decimals0))}
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
            onChange={(e) => handleAmount0Change(e.target.value)}
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
                onClick={() => handleAmount1Change(formatUnits(balance1, decimals1))}
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
            onChange={(e) => handleAmount1Change(e.target.value)}
            className={`w-full rounded-lg border px-3 py-2 text-sm tabular-nums ${
              insufficientBalance1 ? "border-red-300 bg-red-50" : "border-gray-200"
            }`}
          />
        </div>
      </div>

      {/* Estimated summary */}
      {parsed0 > 0n && parsed1 > 0n && (
        <div className="text-xs text-gray-500 bg-gray-50 rounded-lg px-3 py-2 mb-4">
          Estimated: {parseFloat(amount0).toFixed(6)} {token0Info.symbol || "T0"} + {parseFloat(amount1).toFixed(6)} {token1Info.symbol || "T1"}
        </div>
      )}

      {/* Pending fees auto-collection notice */}
      {hasPendingFees && canSubmit && (
        <div className="text-xs text-amber-700 bg-amber-50 border border-amber-200 rounded-lg px-3 py-2 mb-4">
          Uncollected fees of{" "}
          {pendingFees0 > 0n && (
            <span className="font-medium">{formatFeeAmount(pendingFees0, token0Info.decimals ?? 18)} {token0Info.symbol}</span>
          )}
          {pendingFees0 > 0n && pendingFees1 > 0n && " + "}
          {pendingFees1 > 0n && (
            <span className="font-medium">{formatFeeAmount(pendingFees1, token1Info.decimals ?? 18)} {token1Info.symbol}</span>
          )}
          {" "}will be automatically deducted from the deposit cost.
        </div>
      )}

      {/* Action button */}
      <button
        onClick={handleAdd}
        disabled={!canSubmit || isBusy}
        className="w-full btn-primary text-sm py-2.5"
      >
        {autoApprovePhase === "approving" ? (
          <span className="flex items-center justify-center gap-2">
            <LoadingSpinner size="sm" /> Approving token...
          </span>
        ) : isWriting || isConfirming || autoApprovePhase === "adding" ? (
          <span className="flex items-center justify-center gap-2">
            <LoadingSpinner size="sm" /> {isWriting ? "Confirm in wallet..." : "Adding liquidity..."}
          </span>
        ) : insufficientBalance0 || insufficientBalance1 ? (
          "Insufficient balance"
        ) : !canSubmit ? (
          "Enter amounts"
        ) : isIssuer ? (
          "Add Issuer Liquidity (Escrowed)"
        ) : (
          "Add Liquidity"
        )}
      </button>

      {isSuccess && (
        <p className="text-xs text-emerald-600 mt-2 text-center">Liquidity added successfully!</p>
      )}
      {(error || autoApproveError) && (
        <p className="text-xs text-red-500 mt-2 text-center">
          {parseErrorMessage(error || autoApproveError!)}
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
