"use client";

import { useParams } from "next/navigation";
import { useEffect, useState } from "react";
import { useAccount, useWriteContract, useWaitForTransactionReceipt, useReadContract, useChainId } from "wagmi";
import Link from "next/link";
import { usePool } from "@/hooks/usePools";
import { useTokenInfo, useTokenBalance } from "@/hooks/useTokenInfo";
import { useEstimatedCompensation } from "@/hooks/useInsurance";
import { useVestingEndTime } from "@/hooks/useEscrow";
import { formatUnits } from "viem";
import { LoadingSpinner, SkeletonCard } from "@/components/ui/LoadingSpinner";
import { Badge } from "@/components/ui/Badge";
import { Card } from "@/components/ui/Card";
import { parseErrorMessage } from "@/utils/errorMessages";
import { EscrowStatus } from "@/components/pools/EscrowStatus";
import { InsuranceStatus } from "@/components/pools/InsuranceStatus";
import { IssuerInfo } from "@/components/pools/IssuerInfo";
import { TriggerHistory } from "@/components/pools/TriggerHistory";
import { LiquidityPanel } from "@/components/pools/LiquidityPanel";
import { PriceChart } from "@/components/pools/PriceChart";
import { RecentTrades } from "@/components/pools/RecentTrades";
import { TokenIcon } from "@/components/ui/TokenIcon";
import { shortenAddress, explorerUrl } from "@/lib/formatters";
import { getContracts } from "@/config/contracts";
import { InsurancePoolABI, TriggerOracleABI } from "@/config/abis";

const TRIGGER_NAMES: Record<number, string> = {
  1: "Rug Pull",
  2: "Issuer Dump",
  3: "Honeypot",
  4: "Hidden Tax",
  5: "Slow Rug",
  6: "Commitment Breach",
};

function timeAgo(ts: number): string {
  const diff = Math.floor(Date.now() / 1000) - ts;
  if (diff < 60) return "just now";
  if (diff < 3600) return `${Math.floor(diff / 60)}m ago`;
  if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`;
  return `${Math.floor(diff / 86400)}d ago`;
}

function formatReserve(n: number): string {
  if (n === 0) return "0";
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(2)}M`;
  if (n >= 1_000) return `${(n / 1_000).toFixed(2)}K`;
  if (n >= 1) return n.toFixed(4);
  return n.toFixed(6);
}

function TriggerBanner({
  poolId,
  pool,
  address,
  alreadyClaimed,
  claimedAmount,
  estimatedCompensation,
  holderBalance,
  onClaim,
}: {
  poolId: string;
  pool: NonNullable<ReturnType<typeof usePool>["data"]>;
  address: string | undefined;
  alreadyClaimed: boolean;
  claimedAmount: string | undefined;
  estimatedCompensation: bigint | undefined;
  holderBalance: bigint | undefined;
  onClaim: () => void;
}) {
  const chainId = useChainId();
  const contracts = getContracts(chainId);

  const { data: pendingTrigger } = useReadContract({
    address: contracts?.TriggerOracle as `0x${string}`,
    abi: TriggerOracleABI,
    functionName: "getPendingTrigger",
    args: [poolId as `0x${string}`],
    query: { enabled: !!contracts },
  });

  const { data: poolStatus } = useReadContract({
    address: contracts?.InsurancePool as `0x${string}`,
    abi: InsurancePoolABI,
    functionName: "getPoolStatus",
    args: [poolId as `0x${string}`],
    query: { enabled: !!contracts && pool.insurancePool?.isTriggered },
  });

  const [now, setNow] = useState(Math.floor(Date.now() / 1000));

  const isTriggeredFlag = pool.insurancePool?.isTriggered;
  const useMerkleProofFlag = pool.insurancePool?.useMerkleProof;
  const triggerTimestamp = (poolStatus as { triggerTimestamp?: number })?.triggerTimestamp ?? 0;
  const claimDeadline = triggerTimestamp > 0
    ? triggerTimestamp + (useMerkleProofFlag ? 30 * 86400 : 7 * 86400)
    : 0;
  const claimRemaining = claimDeadline > 0 ? Math.max(claimDeadline - now, 0) : 0;
  const isClaimExpired = claimDeadline > 0 && claimRemaining === 0;
  const isClaimUrgent = claimRemaining > 0 && claimRemaining < 3 * 86400;

  useEffect(() => {
    const interval = isClaimUrgent ? 1000 : 60_000;
    const id = setInterval(() => setNow(Math.floor(Date.now() / 1000)), interval);
    return () => clearInterval(id);
  }, [isClaimUrgent]);

  const isTriggered = isTriggeredFlag;
  const hasMerkleRoot = pool.insurancePool?.merkleRoot && pool.insurancePool.merkleRoot !== "0x0000000000000000000000000000000000000000000000000000000000000000";
  const useMerkleProof = useMerkleProofFlag;

  const formatDeadline = (secs: number) => {
    const d = Math.floor(secs / 86400);
    const h = Math.floor((secs % 86400) / 3600);
    if (d > 0) return `${d}d ${h}h`;
    const m = Math.floor((secs % 3600) / 60);
    return `${h}h ${m}m`;
  };

  const pending = pendingTrigger as [boolean, number, bigint] | undefined;
  const hasPending = pending?.[0] ?? false;
  const pendingType = pending?.[1] ?? 0;
  const executeAfter = pending ? Number(pending[2]) : 0;
  const canExecute = executeAfter > 0 && now >= executeAfter;
  const graceRemaining = executeAfter > now ? executeAfter - now : 0;

  const formatCountdown = (secs: number) => {
    const h = Math.floor(secs / 3600);
    const m = Math.floor((secs % 3600) / 60);
    return `${h}h ${m}m`;
  };

  if (alreadyClaimed) {
    return (
      <div className="mb-6 flex items-center gap-3 rounded-2xl bg-emerald-50 border border-emerald-200 px-5 py-4">
        <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-xl bg-emerald-100">
          <svg className="h-5 w-5 text-emerald-600" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2}>
            <path strokeLinecap="round" strokeLinejoin="round" d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z" />
          </svg>
        </div>
        <div>
          <p className="text-sm font-medium text-emerald-700">Compensation Claimed</p>
          <p className="text-xs text-emerald-600/70">{parseFloat(claimedAmount || "0").toFixed(4)} ETH received</p>
        </div>
      </div>
    );
  }

  if (isTriggered) {
    const isFallback = !useMerkleProof;
    return (
      <div className={`mb-6 rounded-2xl border px-5 py-4 ${isFallback ? "bg-amber-50 border-amber-200" : "bg-red-50 border-red-200"}`}>
        <div className="flex items-start gap-4">
          <div className={`flex h-11 w-11 shrink-0 items-center justify-center rounded-xl ${isFallback ? "bg-amber-100" : "bg-red-100"}`}>
            <svg className={`h-6 w-6 ${isFallback ? "text-amber-600" : "text-red-600"}`} fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
              <path strokeLinecap="round" strokeLinejoin="round" d="M12 9v3.75m-9.303 3.376c-.866 1.5.217 3.374 1.948 3.374h14.71c1.73 0 2.813-1.874 1.948-3.374L13.949 3.378c-.866-1.5-3.032-1.5-3.898 0L2.697 16.126zM12 15.75h.007v.008H12v-.008z" />
            </svg>
          </div>
          <div className="flex-1">
            {isFallback ? (
              <>
                <p className="text-sm font-semibold text-amber-700">Fallback mode — no Merkle proof</p>
                <p className="text-xs text-amber-600/70 mt-0.5">Claim period active. Connect wallet and claim your compensation.</p>
              </>
            ) : (
              <>
                <p className="text-sm font-semibold text-red-700">
                  {TRIGGER_NAMES[pool.insurancePool?.triggerType ?? 0] || "Rug Pull"} confirmed
                </p>
                <p className="text-xs text-red-600/70 mt-0.5">
                  {hasMerkleRoot ? "Merkle proof verified. " : ""}Insurance payout activated.
                </p>
              </>
            )}
            {address && estimatedCompensation && estimatedCompensation > 0n && (
              <p className="text-sm text-emerald-600 mt-2 font-medium">
                Your compensation: {parseFloat(formatUnits(estimatedCompensation, 18)).toFixed(4)} ETH
              </p>
            )}
            {claimDeadline > 0 && !alreadyClaimed && (
              <p className={`text-xs mt-1 ${isClaimExpired ? "text-gray-400" : isClaimUrgent ? "text-red-600 font-medium" : "text-gray-500"}`}>
                {isClaimExpired
                  ? "Claim period has expired."
                  : isClaimUrgent
                    ? `Claim expires in ${formatDeadline(claimRemaining)}!`
                    : `Claim deadline: ${formatDeadline(claimRemaining)} remaining`}
              </p>
            )}
            <div className="mt-3 flex gap-3">
              {address && !alreadyClaimed && !isClaimExpired && (
                <button onClick={onClaim} className="btn-success text-sm px-5 py-2">
                  Claim Compensation
                </button>
              )}
              {address && !alreadyClaimed && isClaimExpired && (
                <button disabled className="btn-success text-sm px-5 py-2 opacity-50 cursor-not-allowed">
                  Claim Expired
                </button>
              )}
            </div>
            {!address && (
              <p className="text-xs text-gray-400 mt-2">Connect wallet to claim</p>
            )}
          </div>
        </div>
      </div>
    );
  }

  if (hasPending && hasMerkleRoot && !canExecute) {
    return (
      <div className="mb-6 flex items-start gap-4 rounded-2xl bg-amber-50 border border-amber-200 px-5 py-4">
        <div className="flex h-11 w-11 shrink-0 items-center justify-center rounded-xl bg-amber-100">
          <svg className="h-6 w-6 text-amber-600" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
            <path strokeLinecap="round" strokeLinejoin="round" d="M12 6v6h4.5m4.5 0a9 9 0 11-18 0 9 9 0 0118 0z" />
          </svg>
        </div>
        <div>
          <p className="text-sm font-semibold text-amber-700">Trigger confirmed — Merkle root submitted</p>
          <p className="text-xs text-amber-600/70 mt-0.5">Execution available in {formatCountdown(graceRemaining)}</p>
        </div>
      </div>
    );
  }

  if (hasPending && !canExecute) {
    return (
      <div className="mb-6 flex items-start gap-4 rounded-2xl bg-amber-50 border border-amber-200 px-5 py-4">
        <div className="flex h-11 w-11 shrink-0 items-center justify-center rounded-xl bg-amber-100">
          <svg className="h-6 w-6 text-amber-600" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
            <path strokeLinecap="round" strokeLinejoin="round" d="M12 9v3.75m-9.303 3.376c-.866 1.5.217 3.374 1.948 3.374h14.71c1.73 0 2.813-1.874 1.948-3.374L13.949 3.378c-.866-1.5-3.032-1.5-3.898 0L2.697 16.126zM12 15.75h.007v.008H12v-.008z" />
            </svg>
        </div>
        <div>
          <p className="text-sm font-semibold text-amber-700">
            {TRIGGER_NAMES[pendingType] || "Rug Pull"} trigger detected
          </p>
          <p className="text-xs text-amber-600/70 mt-0.5">
            Grace period ends in {formatCountdown(graceRemaining)}. If confirmed, insurance will compensate holders.
          </p>
        </div>
      </div>
    );
  }

  return null;
}

export default function PoolDetailPage() {
  const params = useParams();
  const poolId = params.id as string;
  const { data: pool, isLoading, error } = usePool(poolId);
  const { address } = useAccount();

  const token0Info = useTokenInfo(pool?.token0 as `0x${string}` | undefined);
  const token1Info = useTokenInfo(pool?.token1 as `0x${string}` | undefined);
  const issuedTokenInfo = useTokenInfo(pool?.issuedToken as `0x${string}` | undefined);

  const { data: vestingEndTime } = useVestingEndTime(pool?.isBastion ? poolId as `0x${string}` : undefined);

  const { balance: holderBalance } = useTokenBalance(
    pool?.issuedToken as `0x${string}` | undefined,
    address
  );
  const { data: estimatedCompensation } = useEstimatedCompensation(
    poolId as `0x${string}`,
    holderBalance
  );

  const chainId = useChainId();
  const contracts = getContracts(chainId);
  const { writeContract, data: claimHash, isPending: isClaiming } =
    useWriteContract();
  const { isLoading: isClaimConfirming, isSuccess: claimSuccess } =
    useWaitForTransactionReceipt({ hash: claimHash });

  const handleClaim = () => {
    if (!contracts || !address || !holderBalance) return;
    writeContract({
      address: contracts.InsurancePool as `0x${string}`,
      abi: InsurancePoolABI,
      functionName: "claimCompensation",
      args: [poolId as `0x${string}`, holderBalance, [] as readonly `0x${string}`[]],
    });
  };

  if (isLoading) {
    return (
      <div className="max-w-6xl mx-auto space-y-6">
        <div className="skeleton h-10 w-48 rounded-lg" />
        <div className="skeleton h-32 w-full rounded-2xl" />
        <div className="grid gap-6 lg:grid-cols-2">
          <SkeletonCard />
          <SkeletonCard />
        </div>
      </div>
    );
  }

  if (error || !pool) {
    return (
      <div className="max-w-lg mx-auto py-20 text-center">
        <div className="mx-auto mb-5 flex h-16 w-16 items-center justify-center rounded-full bg-gray-50">
          <svg className="h-8 w-8 text-gray-300" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.5}>
            <path strokeLinecap="round" strokeLinejoin="round" d="M12 9v3.75m-9.303 3.376c-.866 1.5.217 3.374 1.948 3.374h14.71c1.73 0 2.813-1.874 1.948-3.374L13.949 3.378c-.866-1.5-3.032-1.5-3.898 0L2.697 16.126zM12 15.75h.007v.008H12v-.008z" />
          </svg>
        </div>
        <p className="text-lg font-semibold text-gray-600 mb-2">
          {error ? "Something went wrong" : "Pool not found"}
        </p>
        {error && (
          <p className="text-sm text-gray-400 mb-6">{parseErrorMessage(error)}</p>
        )}
        <Link href="/pools" className="btn-secondary text-sm px-5 py-2.5">
          Back to Pools
        </Link>
      </div>
    );
  }

  const alreadyClaimed = pool.claims?.some(
    (c) => c.holder.toLowerCase() === address?.toLowerCase()
  );
  const claimedAmount = pool.claims?.find(
    (c) => c.holder.toLowerCase() === address?.toLowerCase()
  )?.amount;

  const token0Label = token0Info.displayName;
  const token1Label = token1Info.displayName;
  const issuedTokenLabel = issuedTokenInfo.symbol || (pool.issuedToken ? shortenAddress(pool.issuedToken, 3) : "tokens");
  const poolAge = pool.createdAt ? timeAgo(parseInt(pool.createdAt)) : null;

  return (
    <div className="max-w-6xl mx-auto">
      {/* Breadcrumb */}
      <Link
        href="/pools"
        className="inline-flex items-center gap-1.5 text-sm text-gray-400 hover:text-gray-700 transition-colors mb-5"
      >
        <svg className="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
          <path strokeLinecap="round" strokeLinejoin="round" d="M15 19l-7-7 7-7" />
        </svg>
        Back to Pools
      </Link>

      {/* Hero Header Card */}
      <div className="glass-card p-0 overflow-hidden mb-6">
        <div className="bg-gradient-to-r from-bastion-50/80 via-white to-emerald-50/50 px-6 py-6 sm:px-8 sm:py-7">
          <div className="flex flex-col gap-5 sm:flex-row sm:items-center sm:justify-between">
            {/* Left: Pool info */}
            <div className="flex items-center gap-5">
              <div className="relative">
                <div className="flex -space-x-3">
                  <TokenIcon address={pool.token0} size={52} />
                  <TokenIcon address={pool.token1} size={52} />
                </div>
              </div>
              <div>
                <div className="flex items-center gap-3 flex-wrap">
                  <h1 className="text-2xl font-bold text-gray-900 sm:text-3xl">
                    {token0Label} / {token1Label}
                  </h1>
                  {pool.isBastion ? (
                    <Badge variant="protected">Protected</Badge>
                  ) : (
                    <Badge variant="standard">Standard</Badge>
                  )}
                </div>
                {issuedTokenInfo.name && (
                  <p className="text-sm text-gray-500 mt-1">{issuedTokenInfo.name}</p>
                )}
                <div className="flex items-center gap-4 mt-2 flex-wrap">
                  <a
                    href={explorerUrl(pool.id)}
                    target="_blank"
                    rel="noopener noreferrer"
                    className="inline-flex items-center gap-1 text-xs text-gray-400 hover:text-gray-600 transition-colors"
                  >
                    <svg className="h-3 w-3" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                      <path strokeLinecap="round" strokeLinejoin="round" d="M13.5 6H5.25A2.25 2.25 0 003 8.25v10.5A2.25 2.25 0 005.25 21h10.5A2.25 2.25 0 0018 18.75V10.5m-10.5 6L21 3m0 0h-5.25M21 3v5.25" />
                    </svg>
                    {shortenAddress(pool.id, 6)}
                  </a>
                  {pool.issuedToken && (
                    <a
                      href={explorerUrl(pool.issuedToken)}
                      target="_blank"
                      rel="noopener noreferrer"
                      className="inline-flex items-center gap-1 text-xs text-gray-400 hover:text-gray-600 transition-colors"
                    >
                      Token: {shortenAddress(pool.issuedToken, 4)}
                    </a>
                  )}
                  {poolAge && (
                    <span className="text-xs text-gray-400">Created {poolAge}</span>
                  )}
                </div>
              </div>
            </div>

            {/* Right: Key Metrics */}
            {pool.isBastion && (
              <div className="flex gap-4 sm:gap-6">
                {(pool.reserve0 || pool.reserve1) && (
                  <div className="text-right">
                    <p className="text-[11px] text-gray-400 uppercase tracking-wider mb-1">Reserves</p>
                    <p className="text-sm font-semibold text-gray-900 tabular-nums">
                      {formatReserve(parseFloat(pool.reserve0 || "0") / Math.pow(10, token0Info.decimals ?? 18))}
                      <span className="text-xs text-gray-400 font-normal ml-1">{token0Info.symbol || "T0"}</span>
                    </p>
                    <p className="text-sm font-semibold text-gray-900 tabular-nums">
                      {formatReserve(parseFloat(pool.reserve1 || "0") / Math.pow(10, token1Info.decimals ?? 18))}
                      <span className="text-xs text-gray-400 font-normal ml-1">{token1Info.symbol || "T1"}</span>
                    </p>
                  </div>
                )}
                {pool.escrow && (
                  <div className="text-right">
                    <p className="text-[11px] text-gray-400 uppercase tracking-wider mb-1">Escrowed LP</p>
                    <p className="text-sm font-semibold text-gray-900 tabular-nums">
                      {formatReserve(parseFloat(pool.escrow.totalLiquidity))}
                      <span className="text-xs text-gray-400 font-normal ml-1">LP</span>
                    </p>
                    <p className="text-xs text-emerald-600 font-medium">
                      {vestingPct(pool.escrow)}% removed
                    </p>
                  </div>
                )}
                {pool.insurancePool && (
                  <div className="text-right">
                    <p className="text-[11px] text-gray-400 uppercase tracking-wider mb-1">Insurance</p>
                    <p className="text-sm font-semibold text-gray-900 tabular-nums">
                      {parseFloat(pool.insurancePool.balance).toFixed(4)}
                      <span className="text-xs text-gray-400 font-normal ml-1">ETH</span>
                    </p>
                  </div>
                )}
              </div>
            )}
          </div>
        </div>
      </div>

      {/* Price Chart & Recent Trades — shown for all pools */}
      <div className="mb-6">
        <PriceChart poolId={pool.id} />
      </div>
      <div className="mb-6">
        <RecentTrades
          poolId={pool.id}
          token0={pool.token0}
          token1={pool.token1}
          issuedToken={pool.issuedToken ?? undefined}
        />
      </div>

      {pool.isBastion ? (
        <>
          {/* Trigger banner */}
          <TriggerBanner
            poolId={pool.id}
            pool={pool}
            address={address}
            alreadyClaimed={!!alreadyClaimed}
            claimedAmount={claimedAmount}
            estimatedCompensation={estimatedCompensation as bigint | undefined}
            holderBalance={holderBalance}
            onClaim={handleClaim}
          />

          {/* Claim status */}
          {(isClaiming || isClaimConfirming) && (
            <div className="mb-6 flex items-center justify-center gap-2 rounded-2xl bg-gray-50 px-4 py-4">
              <LoadingSpinner size="sm" />
              <span className="text-sm text-gray-500">
                {isClaiming ? "Confirm in wallet..." : "Processing claim..."}
              </span>
            </div>
          )}
          {claimSuccess && !alreadyClaimed && (
            <div className="mb-6 flex items-center justify-center gap-2 rounded-2xl bg-emerald-50 border border-emerald-200 px-4 py-4">
              <svg className="h-5 w-5 text-emerald-600" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z" />
              </svg>
              <span className="text-sm text-emerald-700 font-medium">
                Compensation claimed successfully!
              </span>
            </div>
          )}

          {/* Escrow — full width for the timeline */}
          {pool.escrow && (
            <div className="mb-6">
              <EscrowStatus
                escrow={pool.escrow}
                vestingEndTime={vestingEndTime ? Number(vestingEndTime) : undefined}
              />
            </div>
          )}

          {/* Insurance + Issuer side by side */}
          <div className="grid gap-6 lg:grid-cols-2 mb-6">
            {pool.insurancePool && (
              <InsuranceStatus
                poolId={pool.id}
                insurance={pool.insurancePool}
                issuedToken={pool.issuedToken}
                tokenSymbol={issuedTokenLabel}
                onClaim={
                  pool.insurancePool.isTriggered && !alreadyClaimed && address
                    ? handleClaim
                    : undefined
                }
              />
            )}
            {pool.issuer && (
              <IssuerInfo
                issuer={pool.issuer}
                commitment={pool.escrow?.commitment}
                lockDuration={pool.escrow?.lockDuration ? parseInt(pool.escrow.lockDuration) : undefined}
                vestingDuration={pool.escrow?.vestingDuration ? parseInt(pool.escrow.vestingDuration) : undefined}
                vestingStrictness={(() => {
                  const lock = pool.escrow?.lockDuration ? parseInt(pool.escrow.lockDuration) : 0;
                  const vesting = pool.escrow?.vestingDuration ? parseInt(pool.escrow.vestingDuration) : 0;
                  const total = lock + vesting;
                  if (total === 0) return null;
                  const defaultTotal = 90 * 86400;
                  if (total < defaultTotal) return "looser" as const;
                  if (total === defaultTotal) return "default" as const;
                  return "stricter" as const;
                })()}
              />
            )}
          </div>

          {/* Trigger history */}
          {pool.triggerEvents && pool.triggerEvents.length > 0 && (
            <TriggerHistory events={pool.triggerEvents} />
          )}

          {/* General LP management */}
          <div className="mt-6">
            <LiquidityPanel pool={pool} />
          </div>
        </>
      ) : (
        <div className="space-y-6">
          <Card className="py-8 text-center">
            <p className="text-sm font-medium text-gray-500 mb-1">
              This pool is not protected by BastionSwap
            </p>
            <p className="text-xs text-gray-400">
              Standard Uniswap V4 pool — no escrow, insurance, or trigger protection.
            </p>
          </Card>
          <LiquidityPanel pool={pool} />
        </div>
      )}
    </div>
  );
}

// Helper to compute LP removal % from escrow data
function vestingPct(escrow: { totalLiquidity: string; removedLiquidity: string }): string {
  const t = parseFloat(escrow.totalLiquidity);
  const r = parseFloat(escrow.removedLiquidity);
  return t > 0 ? ((r / t) * 100).toFixed(1) : "0";
}
