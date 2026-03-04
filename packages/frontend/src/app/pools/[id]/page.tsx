"use client";

import { useParams } from "next/navigation";
import { useAccount, useWriteContract, useWaitForTransactionReceipt } from "wagmi";
import { baseSepolia } from "wagmi/chains";
import Link from "next/link";
import { usePool } from "@/hooks/usePools";
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
import { InsurancePoolABI } from "@/config/abis";

export default function PoolDetailPage() {
  const params = useParams();
  const poolId = params.id as string;
  const { data: pool, isLoading, error } = usePool(poolId);
  const { address } = useAccount();

  const contracts = getContracts(baseSepolia.id);
  const { writeContract, data: claimHash, isPending: isClaiming } =
    useWriteContract();
  const { isLoading: isClaimConfirming, isSuccess: claimSuccess } =
    useWaitForTransactionReceipt({ hash: claimHash });

  const handleClaim = () => {
    if (!contracts || !address) return;
    writeContract({
      address: contracts.InsurancePool as `0x${string}`,
      abi: InsurancePoolABI,
      functionName: "claimCompensation",
      args: [poolId as `0x${string}`, [] as readonly `0x${string}`[]],
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
            <div className="flex items-center gap-2">
              <h1 className="text-xl font-bold">
                {shortenAddress(pool.token0, 3)} / {shortenAddress(pool.token1, 3)}
              </h1>
              {pool.isBastion ? (
                <Badge variant="protected">Protected</Badge>
              ) : (
                <Badge variant="standard">Standard</Badge>
              )}
            </div>
            <a
              href={explorerUrl(pool.id)}
              target="_blank"
              rel="noopener noreferrer"
              className="text-xs text-gray-500 hover:text-gray-400 transition-colors"
            >
              {shortenAddress(pool.id, 6)} &#8599;
            </a>
          </div>
        </div>
      </div>

      {pool.isBastion ? (
        <>
          {/* Dashboard */}
          <div className="grid gap-6 lg:grid-cols-2">
            {pool.escrow && <EscrowStatus escrow={pool.escrow} />}
            {pool.insurancePool && (
              <InsuranceStatus
                poolId={pool.id}
                insurance={pool.insurancePool}
                onClaim={
                  pool.insurancePool.isTriggered && !alreadyClaimed && address
                    ? handleClaim
                    : undefined
                }
              />
            )}
          </div>

          {/* Claim banners */}
          {alreadyClaimed && (
            <div className="mt-4 flex items-center justify-center gap-2 rounded-xl bg-emerald-500/10 border border-emerald-500/20 px-4 py-3">
              <svg className="h-5 w-5 text-emerald-400" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z" />
              </svg>
              <span className="text-sm text-emerald-400 font-medium">
                You claimed {parseFloat(claimedAmount || "0").toFixed(4)} ETH compensation
              </span>
            </div>
          )}
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
