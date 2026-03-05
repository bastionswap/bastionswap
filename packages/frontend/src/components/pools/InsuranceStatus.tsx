"use client";

import { useAccount } from "wagmi";
import { formatUnits } from "viem";
import { Card, CardHeader } from "@/components/ui/Card";
import { Badge } from "@/components/ui/Badge";
import { LoadingSpinner } from "@/components/ui/LoadingSpinner";
import { useEstimatedCompensation } from "@/hooks/useInsurance";
import { useTokenBalance } from "@/hooks/useTokenInfo";
import { formatBps } from "@/lib/formatters";

interface InsuranceStatusProps {
  poolId: string;
  insurance: {
    balance: string;
    isTriggered: boolean;
    triggerType?: number | null;
    merkleRoot?: string | null;
    useMerkleProof?: boolean;
    totalClaimed?: string;
    feeRate: number;
    holderCount?: number;
  };
  issuedToken?: string | null;
  tokenSymbol?: string;
  onClaim?: () => void;
}

const TRIGGER_NAMES: Record<number, string> = {
  0: "None",
  1: "Rug Pull",
  2: "Issuer Dump",
  3: "Honeypot",
  4: "Hidden Tax",
  5: "Slow Rug",
  6: "Commitment Breach",
};

function BarChart({ balance, claimed }: { balance: number; claimed: number }) {
  const total = balance + claimed;
  const balPct = total > 0 ? (balance / total) * 100 : 100;

  return (
    <div className="space-y-1.5">
      <div className="flex h-3 rounded-full overflow-hidden bg-surface-lighter">
        <div
          className="bg-bastion-400 transition-all duration-500"
          style={{ width: `${balPct}%` }}
        />
        {claimed > 0 && (
          <div
            className="bg-emerald-500 transition-all duration-500"
            style={{ width: `${100 - balPct}%` }}
          />
        )}
      </div>
      <div className="flex justify-between text-[10px] text-gray-600">
        <span>Remaining: {balance.toFixed(4)}</span>
        {claimed > 0 && <span>Claimed: {claimed.toFixed(4)}</span>}
      </div>
    </div>
  );
}

function CoverageRatioIndicator({ ratio }: { ratio: number }) {
  const color =
    ratio >= 5 ? "text-emerald-400" : ratio >= 1 ? "text-amber-400" : "text-red-400";
  const bgColor =
    ratio >= 5
      ? "bg-emerald-500/10 border-emerald-500/20"
      : ratio >= 1
        ? "bg-amber-500/10 border-amber-500/20"
        : "bg-red-500/10 border-red-500/20";
  const label = ratio >= 5 ? "Strong" : ratio >= 1 ? "Moderate" : "Low";

  return (
    <div className={`rounded-xl border px-3 py-2 ${bgColor}`}>
      <div className="flex items-center justify-between">
        <p className="text-xs text-gray-500">Coverage Ratio</p>
        <span className={`text-[10px] font-medium ${color}`}>{label}</span>
      </div>
      <p className={`text-lg font-semibold ${color}`}>{ratio.toFixed(2)}%</p>
      <p className="text-[10px] text-gray-600">Pool Balance / Token Escrow Value</p>
    </div>
  );
}

export function InsuranceStatus({
  poolId,
  insurance,
  issuedToken,
  tokenSymbol,
  onClaim,
}: InsuranceStatusProps) {
  const { address } = useAccount();

  // Read holder's token balance for compensation calculation
  const { balance: holderBalance, isLoading: balanceLoading } = useTokenBalance(
    issuedToken as `0x${string}` | undefined,
    address
  );

  const { data: compensation, isLoading: compLoading } =
    useEstimatedCompensation(
      poolId as `0x${string}`,
      holderBalance
    );

  const balance = parseFloat(insurance.balance);
  const totalClaimed = parseFloat(insurance.totalClaimed || "0");

  // Coverage ratio: pool balance / total escrowed value (approximation)
  // Since we don't have market cap, use holderCount as a rough metric
  const holderCount = insurance.holderCount || 0;

  return (
    <Card glow={insurance.isTriggered ? "red" : "none"}>
      <CardHeader>
        <h3 className="text-lg font-semibold">Insurance Pool</h3>
        {insurance.isTriggered ? (
          <Badge variant="triggered">Triggered</Badge>
        ) : (
          <Badge variant="info">Active</Badge>
        )}
      </CardHeader>

      <div className="grid grid-cols-2 gap-3 mb-4">
        <div className="rounded-xl bg-surface-light p-3">
          <p className="text-xs text-gray-500">Pool Balance</p>
          <p className="text-lg font-semibold">{balance.toFixed(4)}</p>
          <p className="text-[10px] text-gray-600">ETH</p>
        </div>
        <div className="rounded-xl bg-surface-light p-3">
          <p className="text-xs text-gray-500">Swap Fee Rate</p>
          <p className="text-lg font-semibold">{formatBps(insurance.feeRate)}</p>
          <p className="text-[10px] text-gray-600">per swap</p>
        </div>
      </div>

      <BarChart balance={balance} claimed={totalClaimed} />

      {/* Your Estimated Coverage (always shown, not just when triggered) */}
      {!insurance.isTriggered && (
        <div className="mt-4 rounded-xl bg-surface-light p-3">
          <p className="text-xs text-gray-500 mb-1">Your Estimated Coverage</p>
          {!address ? (
            <p className="text-xs text-gray-600">Connect wallet to see your coverage</p>
          ) : balanceLoading || compLoading ? (
            <div className="flex items-center gap-2">
              <LoadingSpinner size="sm" />
              <span className="text-xs text-gray-500">Calculating...</span>
            </div>
          ) : holderBalance && holderBalance > 0n ? (
            <div>
              <p className="text-base font-semibold text-emerald-400">
                {compensation
                  ? `${parseFloat(formatUnits(compensation as bigint, 18)).toFixed(6)} ETH`
                  : "—"}
              </p>
              <p className="text-[10px] text-gray-600">
                Based on your {parseFloat(formatUnits(holderBalance, 18)).toFixed(2)} {tokenSymbol || "token"} holdings
              </p>
            </div>
          ) : (
            <p className="text-xs text-gray-600">
              You don&apos;t hold any {tokenSymbol || "issued tokens"} in this pool
            </p>
          )}
        </div>
      )}

      {/* Holder count */}
      {holderCount > 0 && (
        <div className="mt-3 flex justify-between text-xs px-1">
          <span className="text-gray-500">Token Holders</span>
          <span className="text-gray-400">{holderCount}</span>
        </div>
      )}

      {insurance.isTriggered && (
        <div className="mt-4 space-y-3">
          <div className="flex items-start gap-3 rounded-xl bg-red-500/10 border border-red-500/20 px-4 py-3">
            <span className="text-lg">&#128680;</span>
            <div>
              <p className="text-sm font-medium text-red-400">
                {TRIGGER_NAMES[insurance.triggerType ?? 0] || "Unknown"} detected
              </p>
              <p className="text-xs text-red-400/70 mt-0.5">
                {totalClaimed.toFixed(4)} ETH claimed so far
              </p>
            </div>
          </div>

          {address && (
            <div className="rounded-xl bg-emerald-500/5 border border-emerald-500/15 px-4 py-3">
              <p className="text-xs text-gray-500">Your Estimated Compensation</p>
              {compLoading || balanceLoading ? (
                <LoadingSpinner size="sm" />
              ) : holderBalance && holderBalance > 0n && compensation ? (
                <div>
                  <p className="text-xl font-bold text-emerald-400">
                    {parseFloat(formatUnits(compensation as bigint, 18)).toFixed(6)} ETH
                  </p>
                  <p className="text-[10px] text-gray-600">
                    Based on your {parseFloat(formatUnits(holderBalance, 18)).toFixed(2)} {tokenSymbol || "token"} holdings
                  </p>
                </div>
              ) : (
                <p className="text-sm text-gray-500">No holdings detected</p>
              )}
            </div>
          )}

          {!address && (
            <div className="rounded-xl bg-surface-light px-4 py-3">
              <p className="text-xs text-gray-500">Connect wallet to see your compensation</p>
            </div>
          )}

          {onClaim && (
            <button onClick={onClaim} className="btn-success w-full py-3">
              Claim Compensation
            </button>
          )}
        </div>
      )}

      {!insurance.isTriggered && (
        <p className="mt-4 text-xs text-gray-500 leading-relaxed">
          Insurance collects {formatBps(insurance.feeRate)} from each swap as protection premium.
          If a rug pull is detected, funds are distributed to holders.
          If no incident occurs, premiums support the protocol treasury after a 30-day grace period.
        </p>
      )}
    </Card>
  );
}
