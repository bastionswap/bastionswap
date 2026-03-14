"use client";

import { useState } from "react";
import Link from "next/link";
import { useAccount, useBalance, useReadContract, useChainId } from "wagmi";
import { formatUnits } from "viem";
import { Card } from "@/components/ui/Card";
import { TokenIcon } from "@/components/ui/TokenIcon";
import { LoadingSpinner } from "@/components/ui/LoadingSpinner";
import { useTokenInfo, useTokenBalance } from "@/hooks/useTokenInfo";
import { useUserAllPositions, useUserCollectedFees, PortfolioPosition, CollectedFee } from "@/hooks/usePortfolio";
import { useCollectFees, useCollectIssuerFees } from "@/hooks/useLiquidity";
import { useBastionPools } from "@/hooks/usePools";
import { shortenAddress, explorerUrl } from "@/lib/formatters";
import { liquidityToAmounts } from "@/utils/price";
import { BastionPositionRouterABI } from "@/config/abis";
import { getContracts } from "@/config/contracts";

const ZERO_ADDR = "0x0000000000000000000000000000000000000000";

type Tab = "positions" | "tokens" | "fees";

function timeAgo(ts: number): string {
  const diff = Math.floor(Date.now() / 1000) - ts;
  if (diff < 60) return "just now";
  if (diff < 3600) return `${Math.floor(diff / 60)}m ago`;
  if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`;
  return `${Math.floor(diff / 86400)}d ago`;
}

function formatAmount(raw: string | bigint, decimals: number): string {
  const val = typeof raw === "bigint"
    ? Number(formatUnits(raw, decimals))
    : Math.abs(Number(raw)) / 10 ** decimals;
  if (val === 0) return "0";
  if (val < 0.0001) return "<0.0001";
  return val.toLocaleString(undefined, { maximumFractionDigits: 6 });
}

function formatTokenAmount(val: number): string {
  if (val === 0) return "0";
  if (val < 0.0001) return "<0.0001";
  if (val < 1) return val.toLocaleString(undefined, { maximumFractionDigits: 6 });
  if (val < 1000) return val.toLocaleString(undefined, { maximumFractionDigits: 4 });
  return val.toLocaleString(undefined, { maximumFractionDigits: 2 });
}

// ── Token Balance Row ──

function TokenBalanceRow({ tokenAddress, account }: {
  tokenAddress: `0x${string}`;
  account: `0x${string}`;
}) {
  const info = useTokenInfo(tokenAddress);
  const { balance } = useTokenBalance(tokenAddress, account);

  if (!balance || balance === 0n) return null;

  return (
    <tr className="border-b border-gray-50 last:border-0 hover:bg-gray-50/50">
      <td className="px-4 py-3">
        <div className="flex items-center gap-2.5">
          <TokenIcon address={tokenAddress} size={24} />
          <div>
            <p className="text-sm font-medium text-gray-900">{info.displayName}</p>
            <p className="text-[10px] text-gray-400">{info.name}</p>
          </div>
        </div>
      </td>
      <td className="px-4 py-3 text-right">
        <p className="text-sm font-medium text-gray-900 tabular-nums">
          {formatAmount(balance, info.decimals ?? 18)}
        </p>
      </td>
    </tr>
  );
}

// ── Uncollected Fees Display ──

function UnclaimedFees({ position, poolKey }: {
  position: PortfolioPosition;
  poolKey: {
    currency0: `0x${string}`;
    currency1: `0x${string}`;
    fee: number;
    tickSpacing: number;
    hooks: `0x${string}`;
  };
}) {
  const chainId = useChainId();
  const contracts = getContracts(chainId);
  const t0 = useTokenInfo(position.pool.token0 as `0x${string}`);
  const t1 = useTokenInfo(position.pool.token1 as `0x${string}`);
  const isIssuer = position.pool.issuer?.id.toLowerCase() === position.owner.toLowerCase();

  const { data: fees } = useReadContract({
    address: contracts?.BastionPositionRouter as `0x${string}`,
    abi: BastionPositionRouterABI,
    functionName: isIssuer ? "getIssuerUnclaimedFees" : "getUnclaimedFees",
    args: isIssuer
      ? [poolKey]
      : [poolKey, position.owner as `0x${string}`, position.tickLower, position.tickUpper],
    query: {
      enabled: !!contracts,
      refetchInterval: 30_000,
    },
  });

  const feeResult = fees as [bigint, bigint] | undefined;
  if (!feeResult) return null;

  const [fees0, fees1] = feeResult;
  if (fees0 === 0n && fees1 === 0n) return null;

  const f0 = Number(formatUnits(fees0, t0.decimals ?? 18));
  const f1 = Number(formatUnits(fees1, t1.decimals ?? 18));

  return (
    <div className="flex items-center gap-1.5 text-[11px] text-green-600">
      <svg className="h-3 w-3" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
        <path strokeLinecap="round" strokeLinejoin="round" d="M12 6v12m-3-2.818l.879.659c1.171.879 3.07.879 4.242 0 1.172-.879 1.172-2.303 0-3.182C13.536 12.219 12.768 12 12 12c-.725 0-1.45-.22-2.003-.659-1.106-.879-1.106-2.303 0-3.182s2.9-.879 4.006 0l.415.33M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
      </svg>
      <span>
        {f0 > 0 && `${formatTokenAmount(f0)} ${t0.displayName}`}
        {f0 > 0 && f1 > 0 && " + "}
        {f1 > 0 && `${formatTokenAmount(f1)} ${t1.displayName}`}
      </span>
    </div>
  );
}

// ── Collect Fees Button ──

function CollectFeesButton({ position, poolKey }: {
  position: PortfolioPosition;
  poolKey: {
    currency0: `0x${string}`;
    currency1: `0x${string}`;
    fee: number;
    tickSpacing: number;
    hooks: `0x${string}`;
  };
}) {
  const isIssuer = position.pool.issuer?.id.toLowerCase() === position.owner.toLowerCase();
  const {
    collectFees,
    isWriting: isCollecting,
    isConfirming: isCollectConfirming,
    isSuccess: isCollectSuccess,
    reset: resetCollect,
  } = useCollectFees();
  const {
    collectIssuerFees,
    isWriting: isIssuerCollecting,
    isConfirming: isIssuerConfirming,
    isSuccess: isIssuerSuccess,
    reset: resetIssuerCollect,
  } = useCollectIssuerFees();

  const isPending = isIssuer
    ? (isIssuerCollecting || isIssuerConfirming)
    : (isCollecting || isCollectConfirming);
  const isSuccess = isIssuer ? isIssuerSuccess : isCollectSuccess;

  const handleCollect = () => {
    if (isIssuer) {
      collectIssuerFees(poolKey);
    } else {
      collectFees(poolKey, position.tickLower, position.tickUpper);
    }
  };

  if (isSuccess) {
    setTimeout(() => {
      if (isIssuer) resetIssuerCollect();
      else resetCollect();
    }, 3000);
    return (
      <span className="text-[11px] text-green-600 font-medium">Collected!</span>
    );
  }

  return (
    <button
      onClick={handleCollect}
      disabled={isPending}
      className="text-[11px] font-medium text-bastion-600 hover:text-bastion-700 disabled:opacity-50 transition-colors"
    >
      {isPending ? "Collecting..." : "Collect"}
    </button>
  );
}

// ── Position Row ──

function PositionRow({ position }: { position: PortfolioPosition }) {
  const t0 = useTokenInfo(position.pool.token0 as `0x${string}`);
  const t1 = useTokenInfo(position.pool.token1 as `0x${string}`);
  const isIssuer = position.pool.issuer?.id.toLowerCase() === position.owner.toLowerCase();

  // Compute token amounts from liquidity + sqrtPriceX96
  const sqrtPriceX96 = position.pool.sqrtPriceX96 ? BigInt(position.pool.sqrtPriceX96) : 0n;
  const liquidity = BigInt(position.pool.sqrtPriceX96 ? position.liquidity : 0);
  const { amount0, amount1 } = liquidityToAmounts(
    liquidity, sqrtPriceX96, t0.decimals ?? 18, t1.decimals ?? 18
  );

  // Build PoolKey for uncollected fees query & collect action
  const hasPoolKey = position.pool.fee != null && position.pool.tickSpacing != null && position.pool.hook;
  const poolKey = hasPoolKey ? {
    currency0: position.pool.token0 as `0x${string}`,
    currency1: position.pool.token1 as `0x${string}`,
    fee: position.pool.fee!,
    tickSpacing: position.pool.tickSpacing!,
    hooks: position.pool.hook as `0x${string}`,
  } : null;

  return (
    <tr className="border-b border-gray-50 last:border-0 hover:bg-gray-50/50">
      <td className="px-4 py-3">
        <Link href={`/pools/${position.pool.id}`} className="flex items-center gap-2.5 group">
          <div className="flex -space-x-1.5">
            <TokenIcon address={position.pool.token0} size={22} />
            <TokenIcon address={position.pool.token1} size={22} />
          </div>
          <div>
            <p className="text-sm font-medium text-gray-900 group-hover:text-bastion-600 transition-colors">
              {t0.displayName}/{t1.displayName}
            </p>
            <div className="flex items-center gap-1.5">
              {position.pool.isBastion && (
                <span className="text-[10px] px-1.5 py-0.5 rounded bg-bastion-50 text-bastion-700 font-medium">Bastion</span>
              )}
              {isIssuer && (
                <span className="text-[10px] px-1.5 py-0.5 rounded bg-amber-50 text-amber-700 font-medium">Issuer</span>
              )}
              {position.pool.escrow?.isTriggered && (
                <span className="text-[10px] px-1.5 py-0.5 rounded bg-red-50 text-red-600 font-medium">Triggered</span>
              )}
            </div>
          </div>
        </Link>
      </td>
      <td className="px-4 py-3 text-right">
        <p className="text-sm font-medium text-gray-900 tabular-nums">
          {formatTokenAmount(amount0)} {t0.displayName}
        </p>
        <p className="text-sm text-gray-500 tabular-nums">
          {formatTokenAmount(amount1)} {t1.displayName}
        </p>
        <p className="text-[10px] text-gray-400">
          {position.isFullRange ? "Full Range" : `${position.tickLower} — ${position.tickUpper}`}
        </p>
      </td>
      <td className="px-4 py-3 text-right">
        {poolKey && <UnclaimedFees position={position} poolKey={poolKey} />}
        {poolKey && <CollectFeesButton position={position} poolKey={poolKey} />}
      </td>
      <td className="px-4 py-3 text-right text-xs text-gray-400">
        {timeAgo(parseInt(position.lastUpdatedAt))}
      </td>
    </tr>
  );
}

// ── Fee Row ──

function FeeRow({ fee }: { fee: CollectedFee }) {
  const t0 = useTokenInfo(fee.pool.token0 as `0x${string}`);
  const t1 = useTokenInfo(fee.pool.token1 as `0x${string}`);
  const amt0 = Math.abs(Number(fee.amount0)) / 10 ** (t0.decimals ?? 18);
  const amt1 = Math.abs(Number(fee.amount1)) / 10 ** (t1.decimals ?? 18);

  return (
    <tr className="border-b border-gray-50 last:border-0 hover:bg-gray-50/50">
      <td className="px-4 py-3">
        <div className="flex items-center gap-2">
          <div className="flex -space-x-1.5">
            <TokenIcon address={fee.pool.token0} size={20} />
            <TokenIcon address={fee.pool.token1} size={20} />
          </div>
          <span className="text-sm text-gray-700 font-medium">
            {t0.displayName}/{t1.displayName}
          </span>
        </div>
      </td>
      <td className="px-4 py-3 text-right">
        {amt0 > 0 && (
          <p className="text-sm text-gray-900 tabular-nums">
            {amt0 < 0.0001 ? "<0.0001" : amt0.toLocaleString(undefined, { maximumFractionDigits: 6 })} {t0.displayName}
          </p>
        )}
        {amt1 > 0 && (
          <p className="text-sm text-gray-900 tabular-nums">
            {amt1 < 0.0001 ? "<0.0001" : amt1.toLocaleString(undefined, { maximumFractionDigits: 6 })} {t1.displayName}
          </p>
        )}
      </td>
      <td className="px-4 py-3 text-right">
        <a
          href={explorerUrl(fee.transaction, "tx")}
          target="_blank"
          rel="noopener noreferrer"
          className="text-xs text-bastion-600 hover:text-bastion-700"
        >
          {timeAgo(parseInt(fee.timestamp))} &#8599;
        </a>
      </td>
    </tr>
  );
}

// ── Empty State ──

function EmptyState({ message }: { message: string }) {
  return (
    <div className="text-center py-12">
      <svg className="mx-auto h-10 w-10 text-gray-300 mb-3" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1}>
        <path strokeLinecap="round" strokeLinejoin="round" d="M20 7l-8-4-8 4m16 0l-8 4m8-4v10l-8 4m0-10L4 7m8 4v10M4 7v10l8 4" />
      </svg>
      <p className="text-sm text-gray-400">{message}</p>
    </div>
  );
}

// ── Main Page ──

export default function PortfolioPage() {
  const { address, isConnected } = useAccount();
  const [tab, setTab] = useState<Tab>("positions");

  const { data: positions, isLoading: positionsLoading } = useUserAllPositions(address);
  const { data: collectedFees, isLoading: feesLoading } = useUserCollectedFees(address);
  const { data: pools } = useBastionPools();
  const { data: ethBalance } = useBalance({ address });

  // Collect unique issued token addresses from pools user has positions in
  const issuedTokenAddresses = positions
    ? [...new Set(
        positions
          .filter(p => p.pool.issuedToken && p.pool.issuedToken !== ZERO_ADDR)
          .map(p => p.pool.issuedToken as string)
      )]
    : [];

  // Also include issued tokens from all bastion pools for general holders
  const allIssuedTokens = pools
    ? [...new Set([
        ...issuedTokenAddresses,
        ...pools
          .filter(p => p.issuedToken && p.issuedToken !== ZERO_ADDR)
          .map(p => p.issuedToken as string),
      ])]
    : issuedTokenAddresses;

  const tabs: { key: Tab; label: string; count?: number }[] = [
    { key: "positions", label: "LP Positions", count: positions?.length },
    { key: "tokens", label: "Token Holdings" },
    { key: "fees", label: "Collected Fees", count: collectedFees?.length },
  ];

  if (!isConnected) {
    return (
      <div className="mx-auto max-w-4xl px-4 py-20 text-center">
        <svg className="mx-auto h-12 w-12 text-gray-300 mb-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1}>
          <path strokeLinecap="round" strokeLinejoin="round" d="M21 12a2.25 2.25 0 00-2.25-2.25H15a3 3 0 11-6 0H5.25A2.25 2.25 0 003 12m18 0v6a2.25 2.25 0 01-2.25 2.25H5.25A2.25 2.25 0 013 18v-6m18 0V9M3 12V9m18 0a2.25 2.25 0 00-2.25-2.25H5.25A2.25 2.25 0 003 9m18 0V6a2.25 2.25 0 00-2.25-2.25H5.25A2.25 2.25 0 003 6v3" />
        </svg>
        <h2 className="text-lg font-semibold text-gray-900 mb-2">Connect your wallet</h2>
        <p className="text-sm text-gray-400">Connect your wallet to view your portfolio.</p>
      </div>
    );
  }

  return (
    <div className="mx-auto max-w-4xl px-4 py-8 sm:py-12">
      <div className="mb-8">
        <h1 className="text-2xl font-bold text-gray-900">Portfolio</h1>
        <p className="text-sm text-gray-400 mt-1">
          {shortenAddress(address!, 6)}
        </p>
      </div>

      {/* Summary Cards */}
      <div className="grid grid-cols-3 gap-4 mb-8">
        <div className="glass-card px-5 py-4">
          <p className="text-[11px] text-gray-400 uppercase tracking-wider mb-1">ETH Balance</p>
          <p className="text-xl font-bold text-gray-900 tabular-nums">
            {ethBalance ? Number(formatUnits(ethBalance.value, 18)).toLocaleString(undefined, { maximumFractionDigits: 4 }) : "—"}
          </p>
        </div>
        <div className="glass-card px-5 py-4">
          <p className="text-[11px] text-gray-400 uppercase tracking-wider mb-1">Active Positions</p>
          <p className="text-xl font-bold text-gray-900 tabular-nums">
            {positions?.length ?? "—"}
          </p>
        </div>
        <div className="glass-card px-5 py-4">
          <p className="text-[11px] text-gray-400 uppercase tracking-wider mb-1">Fee Collections</p>
          <p className="text-xl font-bold text-gray-900 tabular-nums">
            {collectedFees?.length ?? "—"}
          </p>
        </div>
      </div>

      {/* Tabs */}
      <div className="flex gap-1 border-b border-subtle mb-0">
        {tabs.map(({ key, label, count }) => (
          <button
            key={key}
            onClick={() => setTab(key)}
            className={`px-4 py-2.5 text-sm font-medium border-b-2 transition-colors ${
              tab === key
                ? "border-bastion-600 text-bastion-700"
                : "border-transparent text-gray-400 hover:text-gray-600"
            }`}
          >
            {label}
            {count !== undefined && count > 0 && (
              <span className="ml-1.5 text-xs bg-gray-100 text-gray-500 rounded-full px-1.5 py-0.5">
                {count}
              </span>
            )}
          </button>
        ))}
      </div>

      {/* Tab Content */}
      <Card>
        {tab === "positions" && (
          positionsLoading ? (
            <div className="flex justify-center py-12"><LoadingSpinner /></div>
          ) : !positions?.length ? (
            <EmptyState message="No active LP positions. Add liquidity to a pool to get started." />
          ) : (
            <div className="overflow-x-auto">
              <table className="w-full text-left">
                <thead>
                  <tr className="border-b border-gray-100">
                    <th className="px-4 py-2.5 text-[11px] font-medium text-gray-400 uppercase tracking-wider">Pool</th>
                    <th className="px-4 py-2.5 text-[11px] font-medium text-gray-400 uppercase tracking-wider text-right">Position</th>
                    <th className="px-4 py-2.5 text-[11px] font-medium text-gray-400 uppercase tracking-wider text-right">Uncollected Fees</th>
                    <th className="px-4 py-2.5 text-[11px] font-medium text-gray-400 uppercase tracking-wider text-right">Updated</th>
                  </tr>
                </thead>
                <tbody>
                  {positions.map(pos => (
                    <PositionRow key={pos.id} position={pos} />
                  ))}
                </tbody>
              </table>
            </div>
          )
        )}

        {tab === "tokens" && (
          <div className="overflow-x-auto">
            <table className="w-full text-left">
              <thead>
                <tr className="border-b border-gray-100">
                  <th className="px-4 py-2.5 text-[11px] font-medium text-gray-400 uppercase tracking-wider">Token</th>
                  <th className="px-4 py-2.5 text-[11px] font-medium text-gray-400 uppercase tracking-wider text-right">Balance</th>
                </tr>
              </thead>
              <tbody>
                {address && allIssuedTokens.map(token => (
                  <TokenBalanceRow
                    key={token}
                    tokenAddress={token as `0x${string}`}
                    account={address}
                  />
                ))}
              </tbody>
            </table>
            {allIssuedTokens.length === 0 && (
              <EmptyState message="No token holdings found from Bastion pools." />
            )}
          </div>
        )}

        {tab === "fees" && (
          feesLoading ? (
            <div className="flex justify-center py-12"><LoadingSpinner /></div>
          ) : !collectedFees?.length ? (
            <EmptyState message="No fees collected yet. Provide liquidity and collect fees from your positions." />
          ) : (
            <div className="overflow-x-auto">
              <table className="w-full text-left">
                <thead>
                  <tr className="border-b border-gray-100">
                    <th className="px-4 py-2.5 text-[11px] font-medium text-gray-400 uppercase tracking-wider">Pool</th>
                    <th className="px-4 py-2.5 text-[11px] font-medium text-gray-400 uppercase tracking-wider text-right">Amount</th>
                    <th className="px-4 py-2.5 text-[11px] font-medium text-gray-400 uppercase tracking-wider text-right">Time</th>
                  </tr>
                </thead>
                <tbody>
                  {collectedFees.map(fee => (
                    <FeeRow key={fee.id} fee={fee} />
                  ))}
                </tbody>
              </table>
            </div>
          )
        )}
      </Card>
    </div>
  );
}
