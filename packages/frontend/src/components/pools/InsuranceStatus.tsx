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
    <Card>
      <CardHeader>
        <h3 className="text-lg font-semibold">Insurance Pool</h3>
        {insurance.isTriggered ? (
          <Badge variant="triggered">Triggered</Badge>
        ) : (
          <Badge variant="info">Active</Badge>
        )}
      </CardHeader>

      <div className="grid grid-cols-2 gap-4 mb-4">
        <div>
          <p className="text-xs text-gray-500">Pool Balance</p>
          <p className="text-lg font-semibold">{balance.toFixed(4)} ETH</p>
        </div>
        <div>
          <p className="text-xs text-gray-500">Fee Rate</p>
          <p className="text-lg font-semibold">
            {formatBps(insurance.feeRate)}
          </p>
        </div>
      </div>

      {insurance.isTriggered && (
        <>
          <div className="rounded-lg bg-red-500/10 border border-red-500/20 px-4 py-3 mb-4">
            <p className="text-sm font-medium text-red-400">
              Trigger:{" "}
              {TRIGGER_NAMES[insurance.triggerType ?? 0] || "Unknown"}
            </p>
            <p className="text-xs text-red-400/70 mt-1">
              Total claimed: {totalClaimed.toFixed(4)} ETH
            </p>
          </div>

          {address && (
            <div className="rounded-lg bg-gray-800 px-4 py-3 mb-4">
              <p className="text-xs text-gray-500">Your Estimated Compensation</p>
              {compLoading ? (
                <LoadingSpinner size="sm" />
              ) : (
                <p className="text-lg font-semibold text-emerald-400">
                  {compensation ? `${compensation} wei` : "—"}
                </p>
              )}
            </div>
          )}

          {onClaim && (
            <button
              onClick={onClaim}
              className="w-full rounded-xl bg-emerald-500 py-3 font-semibold text-white hover:bg-emerald-600 transition-colors"
            >
              Claim Compensation
            </button>
          )}
        </>
      )}

      {!insurance.isTriggered && (
        <p className="text-xs text-gray-500">
          Insurance collects {formatBps(insurance.feeRate)} from each swap to
          protect holders in case of a trigger event.
        </p>
      )}
    </Card>
  );
}
