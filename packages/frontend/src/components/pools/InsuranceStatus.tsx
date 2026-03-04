"use client";

import { useAccount } from "wagmi";
import { Card, CardHeader } from "@/components/ui/Card";
import { Badge } from "@/components/ui/Badge";
import { LoadingSpinner } from "@/components/ui/LoadingSpinner";
import { useEstimatedCompensation } from "@/hooks/useInsurance";
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

export function InsuranceStatus({
  poolId,
  insurance,
  onClaim,
}: InsuranceStatusProps) {
  const { address } = useAccount();
  const { data: compensation, isLoading: compLoading } =
    useEstimatedCompensation(
      poolId as `0x${string}`,
      address
    );

  const balance = parseFloat(insurance.balance);
  const totalClaimed = parseFloat(insurance.totalClaimed || "0");

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
              {compLoading ? (
                <LoadingSpinner size="sm" />
              ) : (
                <p className="text-xl font-bold text-emerald-400">
                  {compensation ? `${compensation} wei` : "—"}
                </p>
              )}
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
          Insurance collects {formatBps(insurance.feeRate)} from each swap.
          If a rug pull is detected, funds are distributed to holders as compensation.
        </p>
      )}
    </Card>
  );
}
