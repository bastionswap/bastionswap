"use client";

import { useParams } from "next/navigation";
import { useEffect, useState } from "react";
import { useAccount, useWriteContract, useWaitForTransactionReceipt, useReadContract } from "wagmi";
import { baseSepolia } from "wagmi/chains";
import Link from "next/link";
import { usePool } from "@/hooks/usePools";
import { useTokenInfo, useTokenBalance } from "@/hooks/useTokenInfo";
import { useEstimatedCompensation } from "@/hooks/useInsurance";
import { usePoolInfo } from "@/hooks/usePoolInfo";
import { useVestingEndTime } from "@/hooks/useEscrow";
import { formatUnits } from "viem";
import { LoadingSpinner, SkeletonCard } from "@/components/ui/LoadingSpinner";
import { Badge } from "@/components/ui/Badge";
import { Card } from "@/components/ui/Card";
import { EscrowStatus } from "@/components/pools/EscrowStatus";
import { InsuranceStatus } from "@/components/pools/InsuranceStatus";
import { IssuerInfo } from "@/components/pools/IssuerInfo";
import { TriggerHistory } from "@/components/pools/TriggerHistory";
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
  const contracts = getContracts(baseSepolia.id);

  // Check for pending trigger
  const { data: pendingTrigger } = useReadContract({
    address: contracts?.TriggerOracle as `0x${string}`,
    abi: TriggerOracleABI,
    functionName: "getPendingTrigger",
    args: [poolId as `0x${string}`],
    query: { enabled: !!contracts },
  });

  // Get trigger timestamp for claim deadline calculation
  const { data: poolStatus } = useReadContract({
    address: contracts?.InsurancePool as `0x${string}`,
    abi: InsurancePoolABI,
    functionName: "getPoolStatus",
    args: [poolId as `0x${string}`],
    query: { enabled: !!contracts && pool.insurancePool?.isTriggered },
  });

  const [now, setNow] = useState(Math.floor(Date.now() / 1000));

  // Compute claim deadline
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

  // Parse pending trigger: (bool exists, uint8 triggerType, uint256 executeAfter)
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

  // Already claimed
  if (alreadyClaimed) {
    return (
      <div className="mb-6 flex items-center gap-3 rounded-xl bg-emerald-500/10 border border-emerald-500/20 px-4 py-3">
        <svg className="h-5 w-5 text-emerald-400 shrink-0" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2}>
          <path strokeLinecap="round" strokeLinejoin="round" d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z" />
        </svg>
        <span className="text-sm text-emerald-400 font-medium">
          You claimed {parseFloat(claimedAmount || "0").toFixed(4)} ETH compensation
        </span>
      </div>
    );
  }

  // Triggered + claim available
  if (isTriggered) {
    const isFallback = !useMerkleProof;
    return (
      <div className={`mb-6 rounded-xl border px-4 py-3 ${isFallback ? "bg-amber-500/10 border-amber-500/20" : "bg-red-500/10 border-red-500/20"}`}>
        <div className="flex items-start gap-3">
          <span className="text-lg shrink-0">{isFallback ? "&#9888;" : "&#128680;"}</span>
          <div className="flex-1">
            {isFallback ? (
              <>
                <p className="text-sm font-medium text-amber-400">
                  Trigger executed in fallback mode (no Merkle proof)
                </p>
                <p className="text-xs text-amber-400/70 mt-0.5">
                  Claim period active. Connect wallet and claim your compensation.
                </p>
              </>
            ) : (
              <>
                <p className="text-sm font-medium text-red-400">
                  {TRIGGER_NAMES[pool.insurancePool?.triggerType ?? 0] || "Rug Pull"} confirmed. Insurance payout activated.
                </p>
                <p className="text-xs text-red-400/70 mt-0.5">
                  {hasMerkleRoot ? "Merkle proof verified. " : ""}
                  Connect wallet to claim compensation.
                </p>
              </>
            )}
            {address && estimatedCompensation && estimatedCompensation > 0n && (
              <p className="text-xs text-emerald-400 mt-1">
                Your estimated compensation: {parseFloat(formatUnits(estimatedCompensation, 18)).toFixed(4)} ETH
              </p>
            )}
            {/* Claim deadline */}
            {claimDeadline > 0 && !alreadyClaimed && (
              <p className={`text-xs mt-1 ${isClaimExpired ? "text-gray-500" : isClaimUrgent ? "text-red-400 font-medium" : "text-gray-400"}`}>
                {isClaimExpired
                  ? "Claim period has expired."
                  : isClaimUrgent
                    ? `Claim expires in ${formatDeadline(claimRemaining)}! Claim now.`
                    : `Claim deadline: ${formatDeadline(claimRemaining)} remaining`}
              </p>
            )}
            {address && !alreadyClaimed && !isClaimExpired && (
              <button onClick={onClaim} className="btn-success mt-2 text-sm px-4 py-1.5">
                Claim Compensation
              </button>
            )}
            {address && !alreadyClaimed && isClaimExpired && (
              <button disabled className="btn-success mt-2 text-sm px-4 py-1.5 opacity-50 cursor-not-allowed">
                Claim Expired
              </button>
            )}
            {!address && (
              <p className="text-xs text-gray-500 mt-2">Connect wallet to claim</p>
            )}
          </div>
        </div>
      </div>
    );
  }

  // Pending trigger with merkle root submitted
  if (hasPending && hasMerkleRoot && !canExecute) {
    return (
      <div className="mb-6 flex items-start gap-3 rounded-xl bg-amber-500/10 border border-amber-500/20 px-4 py-3">
        <span className="text-lg shrink-0">&#9888;</span>
        <div>
          <p className="text-sm font-medium text-amber-400">
            Trigger confirmed. Merkle root submitted. Execution available in {formatCountdown(graceRemaining)}.
          </p>
        </div>
      </div>
    );
  }

  // Pending trigger (grace period)
  if (hasPending && !canExecute) {
    return (
      <div className="mb-6 flex items-start gap-3 rounded-xl bg-amber-500/10 border border-amber-500/20 px-4 py-3">
        <span className="text-lg shrink-0">&#9888;</span>
        <div>
          <p className="text-sm font-medium text-amber-400">
            {TRIGGER_NAMES[pendingType] || "Rug Pull"} trigger detected. Grace period ends in {formatCountdown(graceRemaining)}.
          </p>
          <p className="text-xs text-amber-400/70 mt-0.5">
            If confirmed, insurance compensation will be distributed to holders.
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

  // Token info
  const token0Info = useTokenInfo(pool?.token0 as `0x${string}` | undefined);
  const token1Info = useTokenInfo(pool?.token1 as `0x${string}` | undefined);
  const issuedTokenInfo = useTokenInfo(pool?.issuedToken as `0x${string}` | undefined);

  // On-chain pool info (liquidity)
  const { totalLiquidity } = usePoolInfo(pool?.isBastion ? poolId as `0x${string}` : undefined);

  // Vesting end time (on-chain fallback when subgraph data is missing)
  const { data: vestingEndTime } = useVestingEndTime(pool?.isBastion ? poolId as `0x${string}` : undefined);

  // Holder balance & estimated compensation for claim
  const { balance: holderBalance } = useTokenBalance(
    pool?.issuedToken as `0x${string}` | undefined,
    address
  );
  const { data: estimatedCompensation } = useEstimatedCompensation(
    poolId as `0x${string}`,
    holderBalance
  );

  const contracts = getContracts(baseSepolia.id);
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
      <div className="space-y-6">
        <div className="skeleton h-10 w-48 rounded-lg" />
        <div className="grid gap-6 lg:grid-cols-2">
          <SkeletonCard />
          <SkeletonCard />
        </div>
      </div>
    );
  }

  if (error || !pool) {
    return (
      <div className="glass-card p-10 text-center">
        <p className="text-base text-gray-400 mb-2">
          {error ? "Something went wrong" : "Pool not found"}
        </p>
        {error && (
          <p className="text-xs text-gray-600 mb-4">{error.message}</p>
        )}
        <Link href="/pools" className="btn-secondary text-sm px-4 py-2">
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
    <div>
      {/* Header */}
      <div className="mb-6 flex flex-col gap-4 sm:flex-row sm:items-center sm:gap-4">
        <Link
          href="/pools"
          className="flex items-center gap-1 text-sm text-gray-500 hover:text-white transition-colors"
        >
          <svg className="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
            <path strokeLinecap="round" strokeLinejoin="round" d="M15 19l-7-7 7-7" />
          </svg>
          Pools
        </Link>
        <div className="flex items-center gap-3">
          <div className="flex -space-x-2">
            <TokenIcon address={pool.token0} size={40} />
            <TokenIcon address={pool.token1} size={40} />
          </div>
          <div>
            <div className="flex items-center gap-2 flex-wrap">
              <h1 className="text-xl font-bold">
                {token0Label} / {token1Label}
              </h1>
              {pool.isBastion ? (
                <Badge variant="protected">Protected</Badge>
              ) : (
                <Badge variant="standard">Standard</Badge>
              )}
              {poolAge && (
                <span className="text-xs text-gray-500">Created {poolAge}</span>
              )}
            </div>
            {/* Token full name if available */}
            {issuedTokenInfo.name && (
              <p className="text-xs text-gray-400">{issuedTokenInfo.name}</p>
            )}
            <div className="flex items-center gap-3 mt-0.5">
              <a
                href={explorerUrl(pool.id)}
                target="_blank"
                rel="noopener noreferrer"
                className="text-xs text-gray-500 hover:text-gray-400 transition-colors"
              >
                {shortenAddress(pool.id, 6)} &#8599;
              </a>
              {pool.issuedToken && (
                <a
                  href={explorerUrl(pool.issuedToken)}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="text-xs text-gray-500 hover:text-gray-400 transition-colors"
                >
                  Token: {shortenAddress(pool.issuedToken, 4)} &#8599;
                </a>
              )}
            </div>
          </div>
        </div>
      </div>

      {/* Liquidity stat */}
      {pool.isBastion && totalLiquidity !== undefined && (
        <div className="mb-6 rounded-xl bg-surface-light px-4 py-3 flex items-center justify-between">
          <span className="text-sm text-gray-400">Pool Liquidity</span>
          <span className="text-sm font-semibold">
            {parseFloat(formatUnits(totalLiquidity, 18)).toFixed(4)}{" "}
            <span className="text-xs text-gray-500 font-normal">LP</span>
          </span>
        </div>
      )}

      {pool.isBastion ? (
        <>
          {/* Trigger status banner */}
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

          {/* Dashboard */}
          <div className="grid gap-6 lg:grid-cols-2">
            {pool.escrow && (
              <EscrowStatus
                escrow={pool.escrow}
                tokenLabel={issuedTokenLabel}
                vestingEndTime={vestingEndTime ? Number(vestingEndTime) : undefined}
              />
            )}
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
          </div>

          {/* Claim status banners */}
          {(isClaiming || isClaimConfirming) && (
            <div className="mt-4 flex items-center justify-center gap-2 rounded-xl bg-surface-light px-4 py-3">
              <LoadingSpinner size="sm" />
              <span className="text-sm text-gray-400">
                {isClaiming ? "Confirm in wallet..." : "Processing claim..."}
              </span>
            </div>
          )}
          {claimSuccess && !alreadyClaimed && (
            <div className="mt-4 flex items-center justify-center gap-2 rounded-xl bg-emerald-500/10 border border-emerald-500/20 px-4 py-3">
              <svg className="h-5 w-5 text-emerald-400" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z" />
              </svg>
              <span className="text-sm text-emerald-400">
                Compensation claimed successfully!
              </span>
            </div>
          )}

          <div className="mt-6 grid gap-6 lg:grid-cols-2">
            {pool.issuer && (
              <IssuerInfo
                issuer={pool.issuer}
                commitment={pool.escrow?.commitment}
              />
            )}
            {pool.triggerEvents && pool.triggerEvents.length > 0 && (
              <TriggerHistory events={pool.triggerEvents} />
            )}
          </div>
        </>
      ) : (
        <Card className="py-14 text-center">
          <div className="mx-auto mb-4 flex h-16 w-16 items-center justify-center rounded-full bg-surface-light">
            <svg className="h-8 w-8 text-gray-600" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.5}>
              <path strokeLinecap="round" strokeLinejoin="round" d="M12 9v3.75m-9.303 3.376c-.866 1.5.217 3.374 1.948 3.374h14.71c1.73 0 2.813-1.874 1.948-3.374L13.949 3.378c-.866-1.5-3.032-1.5-3.898 0L2.697 16.126zM12 15.75h.007v.008H12v-.008z" />
            </svg>
          </div>
          <p className="text-lg font-semibold text-gray-400 mb-2">
            This pool is not protected by BastionSwap
          </p>
          <p className="text-sm text-gray-600 mb-6">
            Standard Uniswap V4 pool — no escrow, insurance, or trigger protection.
          </p>
          <Link href="/create" className="btn-primary text-sm">
            Create a Bastion Pool
          </Link>
        </Card>
      )}
    </div>
  );
}
