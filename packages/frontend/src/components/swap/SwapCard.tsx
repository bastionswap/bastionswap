"use client";

import { useState, useMemo, useEffect } from "react";
import { useAccount, useChainId } from "wagmi";
import { parseUnits, formatUnits } from "viem";
import { useConnectModal } from "@rainbow-me/rainbowkit";
import { Card } from "@/components/ui/Card";
import { Badge } from "@/components/ui/Badge";
import { TokenIcon } from "@/components/ui/TokenIcon";
import { LoadingSpinner } from "@/components/ui/LoadingSpinner";
import { parseErrorMessage } from "@/utils/errorMessages";
import { TokenSelectModal } from "./TokenSelectModal";
import {
  useExecuteSwap,
  useExecuteMultiHopSwap,
  useTokenAllowance,
  useTokenBalance,
  useSwapWithAutoApprove,
  useFaucet,
  useSwapQuote,
  useMultiHopQuote,
  FAUCETS,
} from "@/hooks/useSwap";
import { useSwapRoute } from "@/hooks/useSwapRoute";
import { usePoolReserves, useAllPools } from "@/hooks/usePools";
import { getContracts } from "@/config/contracts";
import { explorerUrl } from "@/lib/formatters";

interface Token {
  address: string;
  symbol: string;
  name: string;
}

// Insurance fee rate from the protocol (1%)
const INSURANCE_FEE_BPS = 100;

export function SwapCard() {
  const { address, isConnected } = useAccount();
  const chainId = useChainId();
  const { openConnectModal } = useConnectModal();
  const contracts = getContracts(chainId);
  const [tokenIn, setTokenIn] = useState<Token | null>(null);
  const [tokenOut, setTokenOut] = useState<Token | null>(null);
  const [amountIn, setAmountIn] = useState("");
  const [slippage, setSlippage] = useState("1.0");
  const [showTokenSelect, setShowTokenSelect] = useState<"in" | "out" | null>(null);
  const [showSlippage, setShowSlippage] = useState(false);
  const [showDetails, setShowDetails] = useState(false);

  // All pools (for multi-hop price impact)
  const { data: pools } = useAllPools();

  // Route finding
  const route = useSwapRoute(
    tokenIn?.address,
    tokenOut?.address,
    tokenIn?.symbol,
    tokenOut?.symbol
  );
  const isMultiHop = route?.type === "multi-hop";

  // Swap execution
  const { swap: swapDirect, hash: swapDirectHash, isWriting: isWritingDirect, isConfirming: isConfirmingDirect, isSuccess: isSuccessDirect, error: swapDirectError, reset: resetSwapDirect } = useExecuteSwap();
  const { swap: swapMultiHop, hash: swapMultiHopHash, isWriting: isWritingMultiHop, isConfirming: isConfirmingMultiHop, isSuccess: isSuccessMultiHop, error: swapMultiHopError, reset: resetSwapMultiHop } = useExecuteMultiHopSwap();

  // Unified swap state
  const swapHash = isMultiHop ? swapMultiHopHash : swapDirectHash;
  const isWriting = isMultiHop ? isWritingMultiHop : isWritingDirect;
  const isConfirming = isMultiHop ? isConfirmingMultiHop : isConfirmingDirect;
  const isSuccess = isMultiHop ? isSuccessMultiHop : isSuccessDirect;
  const swapError = isMultiHop ? swapMultiHopError : swapDirectError;
  const resetSwap = () => { resetSwapDirect(); resetSwapMultiHop(); };

  // Auto-approve + swap
  const {
    execute: executeWithAutoApprove,
    phase: autoApprovePhase,
    approveError,
    reset: resetAutoApprove,
  } = useSwapWithAutoApprove();

  // Allowance check
  const routerAddr = contracts?.BastionSwapRouter as `0x${string}` | undefined;
  const { allowance, isNative: tokenInIsNative, refetch: refetchAllowance } = useTokenAllowance(
    tokenIn?.address as `0x${string}` | undefined,
    address,
    routerAddr
  );

  // Token balances
  const { balance: tokenInBalance, refetch: refetchTokenIn } = useTokenBalance(
    tokenIn?.address as `0x${string}` | undefined,
    address
  );
  const { balance: tokenOutBalance, refetch: refetchTokenOut } = useTokenBalance(
    tokenOut?.address as `0x${string}` | undefined,
    address
  );

  // Faucet
  const faucetAddr = tokenIn ? FAUCETS[tokenIn.address] as `0x${string}` | undefined : undefined;
  const faucetOutAddr = tokenOut ? FAUCETS[tokenOut.address] as `0x${string}` | undefined : undefined;
  const {
    canClaim: canClaimIn,
    claim: claimIn,
    isPending: isFaucetPending,
    isConfirming: isFaucetConfirming,
    isSuccess: isFaucetSuccess,
  } = useFaucet(faucetAddr, address);

  // Refetch balances and reset auto-approve phase after swap succeeds
  useEffect(() => {
    if (isSuccess) {
      refetchTokenIn();
      refetchTokenOut();
      resetAutoApprove();
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isSuccess, refetchTokenIn, refetchTokenOut]);

  // Reset states when token selection changes
  useEffect(() => {
    resetSwap();
    resetAutoApprove();
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [tokenIn?.address, tokenOut?.address]);

  const swapDirection = () => {
    setTokenIn(tokenOut);
    setTokenOut(tokenIn);
    setAmountIn("");
  };

  // Compute PoolKey parameters (for direct routes)
  const poolKey = useMemo(() => {
    if (!route || route.type !== "direct" || route.steps.length !== 1) return null;

    const step = route.steps[0];
    return {
      currency0: step.poolKey.currency0,
      currency1: step.poolKey.currency1,
      fee: step.poolKey.fee,
      tickSpacing: step.poolKey.tickSpacing,
      hooks: step.poolKey.hooks,
      zeroForOne: step.zeroForOne,
    };
  }, [route]);

  const parsedAmountIn = useMemo(() => {
    if (!amountIn || parseFloat(amountIn) <= 0) return 0n;
    try {
      return parseUnits(amountIn, 18);
    } catch {
      return 0n;
    }
  }, [amountIn]);

  // On-chain swap quote (direct)
  const directQuoteParams = useMemo(() => {
    if (!poolKey || parsedAmountIn <= 0n || isMultiHop) return null;
    return { ...poolKey, amountIn: parsedAmountIn };
  }, [poolKey, parsedAmountIn, isMultiHop]);

  const { data: directQuotedOut, isLoading: isDirectQuoteLoading } = useSwapQuote(directQuoteParams);

  // Multi-hop quote
  const multiHopQuoteParams = useMemo(() => {
    if (!route || !isMultiHop || parsedAmountIn <= 0n || !tokenIn) return null;
    return {
      steps: route.steps,
      amountIn: parsedAmountIn,
      inputToken: tokenIn.address as `0x${string}`,
    };
  }, [route, isMultiHop, parsedAmountIn, tokenIn]);

  const { data: multiHopQuotedOut, isLoading: isMultiHopQuoteLoading } = useMultiHopQuote(multiHopQuoteParams);

  const quotedOut = isMultiHop ? multiHopQuotedOut : directQuotedOut;
  const isQuoteLoading = isMultiHop ? isMultiHopQuoteLoading : isDirectQuoteLoading;

  // Pool reserves for spot price calculation (direct route)
  const { data: poolReserves } = usePoolReserves(tokenIn?.address, tokenOut?.address);

  // Queries must be loaded before allowing swap
  const queriesLoading = !tokenInIsNative && tokenIn && address && (allowance === undefined || tokenInBalance === undefined);
  const insufficientBalance = tokenInBalance !== undefined && parsedAmountIn > 0n && parsedAmountIn > tokenInBalance;
  const needsApproval = !tokenInIsNative && parsedAmountIn > 0n
    && allowance !== undefined && allowance < parsedAmountIn;

  const slippageBps = Math.floor(parseFloat(slippage || "1") * 100);
  // Use real on-chain quote for minAmountOut
  const minAmountOut = quotedOut && quotedOut > 0n
    ? (quotedOut * BigInt(10000 - slippageBps)) / 10000n
    : 0n;

  // Price impact: compare actual output vs fee-adjusted ideal output (spot × fee discount)
  // Uniswap takes fee from input, so ideal output = amountIn × (1 - fee)^hops × spotRate
  // Price impact = only the slippage from trade size, excluding fees
  const POOL_FEE_RATE = 0.003; // 0.3%

  const priceImpact = useMemo(() => {
    if (!quotedOut || parsedAmountIn <= 0n || !route) return 0;

    const numHops = route.numHops;
    const feeMultiplier = (1 - POOL_FEE_RATE) ** numHops;
    const actualOut = Number(quotedOut);
    if (actualOut <= 0) return 0;

    if (route.type === "direct") {
      if (!poolReserves) return 0;
      const r0 = parseFloat(poolReserves.reserve0 || "0");
      const r1 = parseFloat(poolReserves.reserve1 || "0");
      if (r0 <= 0 || r1 <= 0) return 0;

      const tokenInAddr = tokenIn?.address.toLowerCase() ?? "";
      const tokenOutAddr = tokenOut?.address.toLowerCase() ?? "";
      const token0Addr = tokenInAddr < tokenOutAddr ? tokenInAddr : tokenOutAddr;
      const isZeroForOne = tokenInAddr === token0Addr;

      const reserveIn = isZeroForOne ? r0 : r1;
      const reserveOut = isZeroForOne ? r1 : r0;
      const spotRate = reserveOut / reserveIn;

      // Ideal output after fee but before slippage
      const idealOut = Number(parsedAmountIn) * feeMultiplier * spotRate;
      if (idealOut <= 0) return 0;

      const impact = (1 - actualOut / idealOut) * 100;
      return Math.max(impact, 0);
    }

    // Multi-hop: composite spot rate from each hop's pool reserves
    if (!pools || pools.length === 0) return 0;

    let compositeSpotRate = 1;
    for (const step of route.steps) {
      const c0 = step.poolKey.currency0.toLowerCase();
      const c1 = step.poolKey.currency1.toLowerCase();

      const pool = pools.find(
        (p) => p.token0.toLowerCase() === c0 && p.token1.toLowerCase() === c1
      );
      if (!pool) return 0;

      const r0 = parseFloat(pool.reserve0 || "0");
      const r1 = parseFloat(pool.reserve1 || "0");
      if (r0 <= 0 || r1 <= 0) return 0;

      const hopSpotRate = step.zeroForOne ? r1 / r0 : r0 / r1;
      compositeSpotRate *= hopSpotRate;
    }

    if (compositeSpotRate <= 0) return 0;

    // Ideal output = amountIn × (1 - fee)^hops × compositeSpotRate
    const idealOut = Number(parsedAmountIn) * feeMultiplier * compositeSpotRate;
    if (idealOut <= 0) return 0;

    const impact = (1 - actualOut / idealOut) * 100;
    return Math.max(impact, 0);
  }, [quotedOut, poolReserves, parsedAmountIn, tokenIn?.address, tokenOut?.address, route, pools]);

  const handleSwap = () => {
    if (!route || parsedAmountIn <= 0n || !quotedOut || !tokenIn) return;

    const deadline = BigInt(Math.floor(Date.now() / 1000) + 1200); // 20 min

    const doSwap = () => {
      if (isMultiHop) {
        swapMultiHop({
          steps: route.steps,
          amountIn: parsedAmountIn,
          minAmountOut,
          deadline,
          inputToken: tokenIn.address as `0x${string}`,
          value: tokenInIsNative ? parsedAmountIn : 0n,
        });
      } else if (poolKey) {
        swapDirect({
          ...poolKey,
          amountIn: parsedAmountIn,
          minAmountOut,
          deadline,
          value: tokenInIsNative ? parsedAmountIn : 0n,
        });
      }
    };

    executeWithAutoApprove({
      needsApproval,
      tokenAddress: tokenIn.address as `0x${string}`,
      swapFn: doSwap,
      refetchAllowance,
    });
  };

  const formatBalance = (bal: bigint | undefined) => {
    if (bal === undefined) return "—";
    const num = parseFloat(formatUnits(bal, 18));
    if (num === 0) return "0";
    if (num < 0.0001) return "<0.0001";
    return num.toLocaleString("en-US", { maximumFractionDigits: 4 });
  };

  // Real estimated output from on-chain quote
  const estimatedOut = quotedOut && quotedOut > 0n
    ? parseFloat(formatUnits(quotedOut, 18))
    : 0;

  return (
    <>
      <Card className="mx-auto w-full max-w-[480px]">
        <div className="mb-5 flex items-center justify-between">
          <h2 className="text-lg font-semibold text-gray-900">Swap</h2>
          <button
            onClick={() => setShowSlippage(!showSlippage)}
            className="rounded-lg p-2 text-gray-400 hover:bg-gray-50 hover:text-gray-600 transition-colors"
            title="Settings"
          >
            <svg className="h-5 w-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={1.5} d="M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 002.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 001.066 2.573c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 00-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 00-2.573 1.066c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 00-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 00-1.066-2.573c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 001.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z" />
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={1.5} d="M15 12a3 3 0 11-6 0 3 3 0 016 0z" />
            </svg>
          </button>
        </div>

        {showSlippage && (
          <div className="mb-4 rounded-xl bg-gray-50 p-3">
            <p className="mb-2 text-xs text-gray-500">Slippage Tolerance</p>
            <div className="flex gap-2">
              {["0.5", "1.0", "2.0"].map((val) => (
                <button
                  key={val}
                  onClick={() => setSlippage(val)}
                  className={`rounded-lg px-3 py-1.5 text-sm transition-colors ${
                    slippage === val
                      ? "bg-bastion-600 text-white"
                      : "bg-white text-gray-600 border border-gray-200 hover:border-gray-300"
                  }`}
                >
                  {val}%
                </button>
              ))}
              <input
                type="number"
                value={!["0.5", "1.0", "2.0"].includes(slippage) ? slippage : ""}
                onChange={(e) => setSlippage(e.target.value)}
                placeholder="Custom"
                className="w-20 rounded-lg border border-gray-200 bg-white px-2 py-1.5 text-sm text-gray-900 placeholder-gray-400 focus:outline-none focus:border-bastion-500"
              />
            </div>
          </div>
        )}

        {/* Token In */}
        <div className="rounded-2xl bg-gray-50 p-5">
          <div className="mb-3 flex items-center justify-between">
            <span className="text-sm font-medium text-gray-500">You pay</span>
            {tokenIn && isConnected && (
              <span className="text-xs text-gray-400">
                Balance: {formatBalance(tokenInBalance)}
                {tokenInBalance !== undefined && tokenInBalance > 0n && (
                  <button
                    onClick={() => setAmountIn(formatUnits(tokenInBalance, 18))}
                    className="ml-1 text-bastion-600 hover:text-bastion-700 font-medium"
                  >
                    MAX
                  </button>
                )}
              </span>
            )}
          </div>
          <div className="flex items-center gap-3">
            <div className="flex-1 min-w-0">
              <input
                type="number"
                value={amountIn}
                onChange={(e) => setAmountIn(e.target.value)}
                placeholder="0"
                className="w-full bg-transparent text-3xl font-semibold text-gray-900 placeholder-gray-300 focus:outline-none [appearance:textfield] [&::-webkit-inner-spin-button]:appearance-none [&::-webkit-outer-spin-button]:appearance-none"
              />
            </div>
            <button
              onClick={() => setShowTokenSelect("in")}
              className={`shrink-0 flex items-center gap-2 rounded-full px-3 py-2 text-sm font-medium transition-colors ${
                tokenIn
                  ? "bg-white border border-gray-200 text-gray-700 hover:border-gray-300 shadow-sm"
                  : "bg-bastion-600 text-white hover:bg-bastion-700"
              }`}
            >
              {tokenIn ? (
                <>
                  <TokenIcon address={tokenIn.address} size={20} />
                  {tokenIn.symbol}
                </>
              ) : (
                "Select token"
              )}
              <svg className="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M19 9l-7 7-7-7" />
              </svg>
            </button>
          </div>
        </div>

        {/* Swap Direction */}
        <div className="flex justify-center -my-3 relative z-10">
          <button
            onClick={swapDirection}
            className="rounded-xl border-4 border-white bg-gray-100 p-2.5 hover:bg-bastion-50 hover:text-bastion-600 transition-all shadow-sm group"
          >
            <svg className="h-5 w-5 text-gray-400 group-hover:text-bastion-600 transition-colors" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M7 16V4m0 0L3 8m4-4l4 4m6 0v12m0 0l4-4m-4 4l-4-4" />
            </svg>
          </button>
        </div>

        {/* Token Out */}
        <div className="rounded-2xl bg-gray-50 p-5">
          <div className="mb-3">
            <span className="text-sm font-medium text-gray-500">You receive</span>
          </div>
          <div className="flex items-center gap-3">
            <div className="flex-1 min-w-0 relative">
              <input
                type="number"
                placeholder="0"
                value={estimatedOut > 0 ? estimatedOut.toFixed(4) : ""}
                readOnly
                className="w-full bg-transparent text-3xl font-semibold text-gray-900 placeholder-gray-300 focus:outline-none"
              />
              {isQuoteLoading && parsedAmountIn > 0n && tokenIn && tokenOut && (
                <div className="absolute right-0 top-1/2 -translate-y-1/2">
                  <LoadingSpinner size="sm" />
                </div>
              )}
            </div>
            <button
              onClick={() => setShowTokenSelect("out")}
              className={`shrink-0 flex items-center gap-2 rounded-full px-3 py-2 text-sm font-medium transition-colors ${
                tokenOut
                  ? "bg-white border border-gray-200 text-gray-700 hover:border-gray-300 shadow-sm"
                  : "bg-bastion-600 text-white hover:bg-bastion-700"
              }`}
            >
              {tokenOut ? (
                <>
                  <TokenIcon address={tokenOut.address} size={20} />
                  {tokenOut.symbol}
                </>
              ) : (
                "Select token"
              )}
              <svg className="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M19 9l-7 7-7-7" />
              </svg>
            </button>
          </div>
        </div>

        {/* Bastion Protected Pool info */}
        {tokenIn && tokenOut && route && (
          <div className="mt-3 rounded-xl bg-bastion-50 border border-bastion-100 px-3 py-2">
            <div className="flex items-center gap-2">
              <Badge variant="protected">Protected</Badge>
              <span className="text-xs text-gray-500">
                Insurance fee ({(INSURANCE_FEE_BPS / 100).toFixed(0)}%) protects you against rug pulls
              </span>
            </div>
          </div>
        )}

        {/* Route display */}
        {tokenIn && tokenOut && route && route.type === "multi-hop" && (
          <div className="mt-3 rounded-xl bg-bastion-50 border border-bastion-100 px-3 py-2">
            <div className="flex items-center gap-2">
              <svg className="h-4 w-4 text-bastion-500 shrink-0" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M13 7l5 5m0 0l-5 5m5-5H6" />
              </svg>
              <span className="text-xs text-bastion-800">
                Route: {route.pathSymbols.join(" → ")} ({route.numHops} hops)
              </span>
            </div>
          </div>
        )}

        {/* No route found */}
        {tokenIn && tokenOut && !route && (
          <div className="mt-3 rounded-xl bg-amber-50 border border-amber-100 px-3 py-2">
            <span className="text-xs text-amber-700">
              No route found for this pair
            </span>
          </div>
        )}

        {/* Price impact warning */}
        {tokenIn && tokenOut && priceImpact > 5 && (
          <div className={`mt-3 rounded-xl px-3 py-2 border ${
            priceImpact > 15
              ? "bg-red-50 border-red-200"
              : "bg-amber-50 border-amber-200"
          }`}>
            <span className={`text-xs font-medium ${priceImpact > 15 ? "text-red-600" : "text-amber-600"}`}>
              Price Impact: {priceImpact.toFixed(2)}%
              {priceImpact > 15 && " — Consider reducing swap amount"}
            </span>
          </div>
        )}

        {/* Swap Details (collapsible) */}
        {tokenIn && tokenOut && parsedAmountIn > 0n && quotedOut && quotedOut > 0n && (
          <button
            onClick={() => setShowDetails(!showDetails)}
            className="mt-3 flex w-full items-center justify-between px-1 text-xs text-gray-400 hover:text-gray-600 transition-colors"
          >
            <span>
              1 {tokenIn.symbol} ≈ {(Number(quotedOut) / Number(parsedAmountIn)).toFixed(4)} {tokenOut.symbol}
            </span>
            <svg
              className={`h-4 w-4 transition-transform ${showDetails ? "rotate-180" : ""}`}
              fill="none" viewBox="0 0 24 24" stroke="currentColor"
            >
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M19 9l-7 7-7-7" />
            </svg>
          </button>
        )}

        {showDetails && tokenIn && tokenOut && parsedAmountIn > 0n && (
          <div className="mt-2 rounded-xl bg-gray-50 p-3 space-y-2 text-xs">
            <div className="flex justify-between">
              <span className="text-gray-500">Expected Output</span>
              <span className="text-gray-700">
                {quotedOut ? parseFloat(formatUnits(quotedOut, 18)).toFixed(4) : "—"} {tokenOut.symbol}
              </span>
            </div>
            <div className="flex justify-between">
              <span className="text-gray-500">Minimum Received</span>
              <span className="text-gray-700">
                {minAmountOut > 0n ? parseFloat(formatUnits(minAmountOut, 18)).toFixed(4) : "—"} {tokenOut.symbol}
              </span>
            </div>
            <div className="flex justify-between">
              <span className="text-gray-500">Price Impact</span>
              <span className={priceImpact > 5 ? "text-amber-600" : "text-gray-700"}>
                {priceImpact > 0.01 ? `${priceImpact.toFixed(2)}%` : "<0.01%"}
              </span>
            </div>
            <div className="flex justify-between">
              <span className="text-gray-500">Slippage Tolerance</span>
              <span className="text-gray-700">{slippage}%</span>
            </div>
            <div className="flex justify-between">
              <span className="text-gray-500">Pool Fee</span>
              <span className="text-gray-700">
                {route && route.numHops > 1
                  ? `0.30% × ${route.numHops} hops`
                  : "0.30%"}
              </span>
            </div>
          </div>
        )}

        {/* Action Buttons */}
        <div className="mt-4">
          {!isConnected ? (
            <button onClick={openConnectModal} className="btn-primary w-full py-4 text-base">
              Connect Wallet
            </button>
          ) : !tokenIn || !tokenOut ? (
            <button disabled className="w-full rounded-xl bg-gray-100 py-4 text-base font-semibold text-gray-400 cursor-not-allowed">
              Select Tokens
            </button>
          ) : !amountIn || parseFloat(amountIn) <= 0 ? (
            <button disabled className="w-full rounded-xl bg-gray-100 py-4 text-base font-semibold text-gray-400 cursor-not-allowed">
              Enter Amount
            </button>
          ) : queriesLoading ? (
            <button disabled className="btn-primary w-full py-4 text-base flex items-center justify-center gap-2 opacity-60">
              <LoadingSpinner size="sm" />
              Loading...
            </button>
          ) : insufficientBalance ? (
            <button disabled className="w-full rounded-xl bg-red-50 border border-red-200 py-4 text-base font-semibold text-red-600 cursor-not-allowed">
              Insufficient {tokenIn.symbol} Balance
            </button>
          ) : autoApprovePhase === "approving" || autoApprovePhase === "waitingApproval" ? (
            <button disabled className="btn-primary w-full py-4 text-base flex items-center justify-center gap-2">
              <LoadingSpinner size="sm" />
              {autoApprovePhase === "approving" ? "Confirm approval..." : "Approving..."}
            </button>
          ) : isQuoteLoading ? (
            <button disabled className="btn-primary w-full py-4 text-base flex items-center justify-center gap-2 opacity-60">
              <LoadingSpinner size="sm" />
              Fetching price...
            </button>
          ) : !route ? (
            <button disabled className="w-full rounded-xl bg-amber-50 border border-amber-200 py-4 text-base font-semibold text-amber-600 cursor-not-allowed">
              No Route Found
            </button>
          ) : !quotedOut || quotedOut <= 0n ? (
            <button disabled className="w-full rounded-xl bg-red-50 border border-red-200 py-4 text-base font-semibold text-red-600 cursor-not-allowed">
              Insufficient Liquidity
            </button>
          ) : isWriting || isConfirming ? (
            <button disabled className="btn-primary w-full py-4 text-base flex items-center justify-center gap-2">
              <LoadingSpinner size="sm" />
              {isWriting ? "Confirm in wallet..." : "Swapping..."}
            </button>
          ) : (
            <button
              onClick={handleSwap}
              className="btn-primary w-full py-4 text-base"
            >
              Swap
            </button>
          )}
        </div>

        {/* Success */}
        {isSuccess && swapHash && (
          <div className="mt-3 rounded-xl bg-emerald-50 border border-emerald-200 px-4 py-3">
            <div className="flex items-center gap-2 mb-1">
              <svg className="h-4 w-4 text-emerald-600" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z" />
              </svg>
              <span className="text-sm text-emerald-700 font-medium">Swap successful!</span>
            </div>
            <p className="text-xs text-gray-500">
              Your swap contributed to the Insurance Pool.
            </p>
            <a
              href={explorerUrl(swapHash, "tx")}
              target="_blank"
              rel="noopener noreferrer"
              className="text-xs text-bastion-600 hover:text-bastion-700 mt-1 inline-block"
            >
              View on BaseScan &#8599;
            </a>
          </div>
        )}

        {/* Error */}
        {(swapError || approveError) && (
          <div className="mt-3 rounded-xl bg-red-50 border border-red-200 px-4 py-3">
            <p className="text-sm text-red-600">
              {parseErrorMessage(swapError || approveError!)}
            </p>
            <button
              onClick={() => { resetSwap(); resetAutoApprove(); }}
              className="text-xs text-gray-400 hover:text-gray-600 mt-1"
            >
              Try again
            </button>
          </div>
        )}

        {/* Faucet */}
        {isConnected && tokenIn && faucetAddr && (
          <div className="mt-3 border-t border-subtle pt-3">
            <div className="flex items-center justify-between">
              <span className="text-xs text-gray-400">
                Need test tokens?
              </span>
              <button
                onClick={claimIn}
                disabled={isFaucetPending || isFaucetConfirming || canClaimIn === false}
                className={`text-xs font-medium px-3 py-1 rounded-lg transition-colors ${
                  canClaimIn === false
                    ? "text-gray-300 cursor-not-allowed"
                    : "text-bastion-600 hover:bg-bastion-50"
                }`}
              >
                {isFaucetPending || isFaucetConfirming ? (
                  <span className="flex items-center gap-1">
                    <LoadingSpinner size="sm" /> Claiming...
                  </span>
                ) : isFaucetSuccess ? (
                  "1,000 tokens sent!"
                ) : canClaimIn === false ? (
                  "Already claimed (24h cooldown)"
                ) : (
                  `Get 1,000 ${tokenIn.symbol}`
                )}
              </button>
            </div>
          </div>
        )}
      </Card>

      <TokenSelectModal
        isOpen={showTokenSelect !== null}
        onClose={() => setShowTokenSelect(null)}
        onSelect={(token) => {
          if (showTokenSelect === "in") setTokenIn(token);
          else setTokenOut(token);
        }}
      />
    </>
  );
}
