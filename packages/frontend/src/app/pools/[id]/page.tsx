"use client";

import { useParams } from "next/navigation";
import { useAccount, useWriteContract, useWaitForTransactionReceipt } from "wagmi";
import { baseSepolia } from "wagmi/chains";
import Link from "next/link";
import { usePool } from "@/hooks/usePools";
import { LoadingSpinner } from "@/components/ui/LoadingSpinner";
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
      <div className="flex justify-center py-20">
        <LoadingSpinner size="lg" />
      </div>
    );
  }

  if (error || !pool) {
    return (
      <div className="rounded-2xl border border-gray-800 bg-gray-900 p-8 text-center">
        <p className="text-gray-400">
          {error ? "Unable to load pool data" : "Pool not found"}
        </p>
        {error && (
          <p className="mt-2 text-xs text-gray-600">{error.message}</p>
        )}
        <Link
          href="/pools"
          className="mt-4 inline-block text-bastion-400 hover:underline"
        >
          Back to pools
        </Link>
      </div>
    );
  }

  // Already claimed?
  const alreadyClaimed = pool.claims?.some(
    (c) => c.holder.toLowerCase() === address?.toLowerCase()
  );
  const claimedAmount = pool.claims?.find(
    (c) => c.holder.toLowerCase() === address?.toLowerCase()
  )?.amount;

  return (
    <div>
      {/* Header */}
      <div className="mb-6 flex items-center gap-4">
        <Link
          href="/pools"
          className="text-gray-400 hover:text-white transition-colors"
        >
          &larr; Pools
        </Link>
        <div className="flex items-center gap-3">
          <div className="flex -space-x-2">
            <TokenIcon address={pool.token0} size={40} />
            <TokenIcon address={pool.token1} size={40} />
          </div>
          <div>
            <div className="flex items-center gap-2">
              <h1 className="text-xl font-bold">
                {shortenAddress(pool.token0, 3)} /{" "}
                {shortenAddress(pool.token1, 3)}
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
              className="text-xs text-gray-500 hover:text-gray-400"
            >
              Pool: {shortenAddress(pool.id, 6)}
            </a>
          </div>
        </div>
      </div>

      {pool.isBastion ? (
        <>
          {/* Bastion Dashboard */}
          <div className="grid gap-6 lg:grid-cols-2">
            {pool.escrow && <EscrowStatus escrow={pool.escrow} />}
            {pool.insurancePool && (
              <InsuranceStatus
                poolId={pool.id}
                insurance={pool.insurancePool}
                onClaim={
                  pool.insurancePool.isTriggered &&
                  !alreadyClaimed &&
                  address
                    ? handleClaim
                    : undefined
                }
              />
            )}
          </div>

          {/* Claim Status */}
          {alreadyClaimed && (
            <div className="mt-4 rounded-xl border border-emerald-500/20 bg-emerald-500/5 p-4 text-center">
              <p className="text-emerald-400 font-medium">
                Claimed: {parseFloat(claimedAmount || "0").toFixed(4)} ETH
              </p>
            </div>
          )}
          {(isClaiming || isClaimConfirming) && (
            <div className="mt-4 flex items-center justify-center gap-2">
              <LoadingSpinner size="sm" />
              <span className="text-sm text-gray-400">
                {isClaiming ? "Confirm in wallet..." : "Processing claim..."}
              </span>
            </div>
          )}
          {claimSuccess && !alreadyClaimed && (
            <div className="mt-4 rounded-xl bg-emerald-500/10 p-4 text-center text-emerald-400">
              Compensation claimed successfully!
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
        /* Standard Pool */
        <Card className="text-center py-12">
          <p className="text-xl font-semibold text-gray-400 mb-2">
            This pool is not protected by BastionSwap
          </p>
          <p className="text-sm text-gray-600 mb-6">
            Standard Uniswap V4 pool — no escrow, insurance, or trigger
            protection.
          </p>
          <Link
            href="/create"
            className="inline-block rounded-xl bg-bastion-500 px-6 py-3 font-semibold text-white hover:bg-bastion-600 transition-colors"
          >
            Create a Bastion Pool
          </Link>
        </Card>
      )}
    </div>
  );
}
