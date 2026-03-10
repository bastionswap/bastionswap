"use client";

import { useAccount } from "wagmi";
import { formatUnits } from "viem";
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

function PoolBalanceRing({ balance, claimed, size = 120 }: { balance: number; claimed: number; size?: number }) {
  const total = balance + claimed;
  const balPct = total > 0 ? balance / total : 1;
  const r = (size - 16) / 2;
  const c = 2 * Math.PI * r;
  const balOffset = c - balPct * c;

  return (
    <div className="relative" style={{ width: size, height: size }}>
      <svg className="w-full h-full -rotate-90" viewBox={`0 0 ${size} ${size}`}>
        {/* Background */}
        <circle cx={size / 2} cy={size / 2} r={r} fill="none" stroke="#F1F5F9" strokeWidth="10" />
        {/* Claimed portion (if any) */}
        {claimed > 0 && (
          <circle cx={size / 2} cy={size / 2} r={r} fill="none" stroke="#10B981" strokeWidth="10"
            strokeDasharray={c} strokeDashoffset={0} strokeLinecap="round" className="transition-all duration-700" />
        )}
        {/* Balance portion */}
        <circle cx={size / 2} cy={size / 2} r={r} fill="none" stroke="#F59E0B" strokeWidth="10"
          strokeDasharray={c} strokeDashoffset={balOffset} strokeLinecap="round" className="transition-all duration-700" />
      </svg>
      <div className="absolute inset-0 flex flex-col items-center justify-center">
        <span className="text-xl font-bold text-gray-900 tabular-nums">{balance.toFixed(4)}</span>
        <span className="text-[10px] text-gray-400">ETH</span>
      </div>
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
  const holderCount = insurance.holderCount || 0;

  return (
    <div className="glass-card p-0 overflow-hidden">
      {/* Header */}
      <div className="px-6 pt-5 pb-4 flex items-center justify-between">
        <div className="flex items-center gap-3">
          <div className={`flex h-10 w-10 items-center justify-center rounded-xl ${
            insurance.isTriggered ? "bg-red-100" : "bg-bastion-100"
          }`}>
            <svg className={`h-5 w-5 ${insurance.isTriggered ? "text-red-600" : "text-bastion-600"}`} fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5}>
              <path strokeLinecap="round" strokeLinejoin="round" d="M9 12.75L11.25 15 15 9.75m-3-7.036A11.959 11.959 0 013.598 6 11.99 11.99 0 003 9.749c0 5.592 3.824 10.29 9 11.623 5.176-1.332 9-6.03 9-11.622 0-1.31-.21-2.571-.598-3.751h-.152c-3.196 0-6.1-1.248-8.25-3.285z" />
            </svg>
          </div>
          <div>
            <h3 className="text-base font-semibold text-gray-900">Insurance Pool</h3>
            <p className="text-xs text-gray-400">Rug-pull protection fund</p>
          </div>
        </div>
        {insurance.isTriggered ? (
          <Badge variant="triggered">Triggered</Badge>
        ) : (
          <Badge variant="info">Active</Badge>
        )}
      </div>

      {/* Main content */}
      <div className="px-6 pb-5">
        {/* Balance visualization + stats */}
        <div className="flex items-center gap-6">
          <PoolBalanceRing balance={balance} claimed={totalClaimed} />
          <div className="flex-1 space-y-3">
            <div>
              <p className="text-[11px] text-gray-400 mb-0.5">Pool Balance</p>
              <p className="text-2xl font-bold text-gray-900 tabular-nums">{balance.toFixed(4)} <span className="text-sm font-normal text-gray-400">ETH</span></p>
            </div>
            <div className="grid grid-cols-2 gap-3">
              <div className="rounded-lg bg-gray-50 px-3 py-2">
                <p className="text-[10px] text-gray-400">Fee Rate</p>
                <p className="text-sm font-semibold text-gray-900">{formatBps(insurance.feeRate)}</p>
              </div>
              <div className="rounded-lg bg-gray-50 px-3 py-2">
                <p className="text-[10px] text-gray-400">Claimed</p>
                <p className="text-sm font-semibold text-emerald-600">{totalClaimed.toFixed(4)}</p>
              </div>
            </div>
            {holderCount > 0 && (
              <div className="flex items-center gap-1.5 text-xs text-gray-400">
                <svg className="h-3.5 w-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                  <path strokeLinecap="round" strokeLinejoin="round" d="M15 19.128a9.38 9.38 0 002.625.372 9.337 9.337 0 004.121-.952 4.125 4.125 0 00-7.533-2.493M15 19.128v-.003c0-1.113-.285-2.16-.786-3.07M15 19.128H9m6 0a5.972 5.972 0 00-1.13-3.543M9 19.128A5.972 5.972 0 017.786 16.06m0 0a5.972 5.972 0 00-.786-3.07M9 19.128v-.003c0-1.113.285-2.16.786-3.07m0 0A5.973 5.973 0 0112 12.75a5.973 5.973 0 012.214 3.24M12 2.25a2.625 2.625 0 100 5.25 2.625 2.625 0 000-5.25z" />
                </svg>
                {holderCount} token holders protected
              </div>
            )}
          </div>
        </div>

        {/* Fund allocation bar */}
        <div className="mt-5">
          <div className="flex items-center justify-between text-[11px] text-gray-400 mb-1.5">
            <span>Fund Allocation</span>
            <span>{balance > 0 || totalClaimed > 0
              ? `${((balance / (balance + totalClaimed)) * 100).toFixed(0)}% available`
              : "No funds yet"
            }</span>
          </div>
          <div className="flex h-2.5 rounded-full overflow-hidden bg-gray-100">
            <div
              className="bg-bastion-500 transition-all duration-500 rounded-l-full"
              style={{ width: `${balance + totalClaimed > 0 ? (balance / (balance + totalClaimed)) * 100 : 100}%` }}
            />
            {totalClaimed > 0 && (
              <div
                className="bg-emerald-500 transition-all duration-500 rounded-r-full"
                style={{ width: `${(totalClaimed / (balance + totalClaimed)) * 100}%` }}
              />
            )}
          </div>
          <div className="flex items-center gap-4 mt-2">
            <div className="flex items-center gap-1.5">
              <div className="h-2 w-2 rounded-full bg-bastion-500" />
              <span className="text-[10px] text-gray-400">Available ({balance.toFixed(4)})</span>
            </div>
            {totalClaimed > 0 && (
              <div className="flex items-center gap-1.5">
                <div className="h-2 w-2 rounded-full bg-emerald-500" />
                <span className="text-[10px] text-gray-400">Claimed ({totalClaimed.toFixed(4)})</span>
              </div>
            )}
          </div>
        </div>
      </div>

      {/* Your coverage section */}
      {!insurance.isTriggered && (
        <div className="border-t border-subtle px-6 py-4">
          <p className="text-[11px] font-medium text-gray-400 uppercase tracking-wider mb-2">
            Your Coverage
          </p>
          {!address ? (
            <p className="text-xs text-gray-400">Connect wallet to see your coverage</p>
          ) : balanceLoading || compLoading ? (
            <div className="flex items-center gap-2">
              <LoadingSpinner size="sm" />
              <span className="text-xs text-gray-400">Calculating...</span>
            </div>
          ) : holderBalance && holderBalance > 0n ? (
            <div className="flex items-center justify-between">
              <div>
                <p className="text-lg font-bold text-emerald-600 tabular-nums">
                  {compensation
                    ? `${parseFloat(formatUnits(compensation as bigint, 18)).toFixed(6)} ETH`
                    : "—"}
                </p>
                <p className="text-[11px] text-gray-400">
                  Based on {parseFloat(formatUnits(holderBalance, 18)).toFixed(2)} {tokenSymbol || "token"} holdings
                </p>
              </div>
              <div className="flex h-9 w-9 items-center justify-center rounded-lg bg-emerald-50">
                <svg className="h-5 w-5 text-emerald-600" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5}>
                  <path strokeLinecap="round" strokeLinejoin="round" d="M9 12.75L11.25 15 15 9.75m-3-7.036A11.959 11.959 0 013.598 6 11.99 11.99 0 003 9.749c0 5.592 3.824 10.29 9 11.623 5.176-1.332 9-6.03 9-11.622 0-1.31-.21-2.571-.598-3.751h-.152c-3.196 0-6.1-1.248-8.25-3.285z" />
                </svg>
              </div>
            </div>
          ) : (
            <p className="text-xs text-gray-400">
              You don&apos;t hold any {tokenSymbol || "issued tokens"} in this pool
            </p>
          )}
        </div>
      )}

      {/* Triggered state */}
      {insurance.isTriggered && (
        <div className="border-t border-subtle">
          <div className="px-6 py-4">
            <div className="flex items-start gap-3 rounded-xl bg-red-50 border border-red-200 px-4 py-3 mb-4">
              <svg className="h-5 w-5 text-red-500 shrink-0 mt-0.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M12 9v3.75m-9.303 3.376c-.866 1.5.217 3.374 1.948 3.374h14.71c1.73 0 2.813-1.874 1.948-3.374L13.949 3.378c-.866-1.5-3.032-1.5-3.898 0L2.697 16.126zM12 15.75h.007v.008H12v-.008z" />
              </svg>
              <div>
                <p className="text-sm font-medium text-red-700">
                  {TRIGGER_NAMES[insurance.triggerType ?? 0] || "Unknown"} detected
                </p>
                <p className="text-xs text-red-600/70 mt-0.5">
                  Issuer LP force-removed. {totalClaimed.toFixed(4)} ETH distributed so far.
                </p>
              </div>
            </div>

            {address && (
              <div className="rounded-xl bg-emerald-50 border border-emerald-200 px-4 py-3 mb-4">
                <p className="text-[11px] text-gray-500 mb-1">Your Estimated Compensation</p>
                {compLoading || balanceLoading ? (
                  <LoadingSpinner size="sm" />
                ) : holderBalance && holderBalance > 0n && compensation ? (
                  <div>
                    <p className="text-2xl font-bold text-emerald-600 tabular-nums">
                      {parseFloat(formatUnits(compensation as bigint, 18)).toFixed(6)} ETH
                    </p>
                    <p className="text-[10px] text-gray-400 mt-0.5">
                      Based on {parseFloat(formatUnits(holderBalance, 18)).toFixed(2)} {tokenSymbol || "token"} holdings
                    </p>
                  </div>
                ) : (
                  <p className="text-sm text-gray-400">No holdings detected</p>
                )}
              </div>
            )}

            {!address && (
              <div className="rounded-xl bg-gray-50 px-4 py-3 mb-4">
                <p className="text-xs text-gray-400">Connect wallet to see your compensation</p>
              </div>
            )}

            {onClaim && (
              <button onClick={onClaim} className="btn-success w-full py-3.5 text-base">
                Claim Compensation
              </button>
            )}
          </div>
        </div>
      )}

      {/* Info footer */}
      {!insurance.isTriggered && (
        <div className="border-t border-subtle px-6 py-3">
          <p className="text-[11px] text-gray-400 leading-relaxed">
            Each swap contributes {formatBps(insurance.feeRate)} to the insurance pool.
            If a rug pull is detected, funds are distributed pro-rata to token holders.
          </p>
        </div>
      )}
    </div>
  );
}
