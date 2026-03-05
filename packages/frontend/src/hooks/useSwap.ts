"use client";

import { useEffect, useState } from "react";
import {
  useWriteContract,
  useWaitForTransactionReceipt,
  useReadContract,
  useBalance,
} from "wagmi";
import { baseSepolia } from "wagmi/chains";
import { parseUnits, formatUnits } from "viem";
import { getContracts } from "@/config/contracts";
import { BastionRouterABI } from "@/config/abis";

const contracts = getContracts(baseSepolia.id);

const ERC20_ABI = [
  {
    type: "function",
    name: "allowance",
    inputs: [
      { name: "owner", type: "address" },
      { name: "spender", type: "address" },
    ],
    outputs: [{ type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "approve",
    inputs: [
      { name: "spender", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [{ type: "bool" }],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "balanceOf",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ type: "uint256" }],
    stateMutability: "view",
  },
] as const;

const FAUCET_ABI = [
  {
    type: "function",
    name: "claim",
    inputs: [],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "canClaim",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ type: "bool" }],
    stateMutability: "view",
  },
] as const;

// ─── Token Allowance ──────────────────────────────────

export function useTokenAllowance(
  token: `0x${string}` | undefined,
  owner: `0x${string}` | undefined,
  spender: `0x${string}` | undefined
) {
  const isNative = token === "0x0000000000000000000000000000000000000000";
  const { data, refetch } = useReadContract({
    address: token,
    abi: ERC20_ABI,
    functionName: "allowance",
    args: owner && spender ? [owner, spender] : undefined,
    query: { enabled: !!token && !!owner && !!spender && !isNative },
  });

  return {
    allowance: isNative ? undefined : (data as bigint | undefined),
    isNative,
    refetch,
  };
}

// ─── Token Balance ──────────────────────────────────

export function useTokenBalance(
  token: `0x${string}` | undefined,
  account: `0x${string}` | undefined
) {
  const isNative = token === "0x0000000000000000000000000000000000000000";

  const { data: ethBalance } = useBalance({
    address: account,
    query: { enabled: !!account && isNative },
  });

  const { data: erc20Balance, refetch } = useReadContract({
    address: token,
    abi: ERC20_ABI,
    functionName: "balanceOf",
    args: account ? [account] : undefined,
    query: { enabled: !!token && !!account && !isNative },
  });

  return {
    balance: isNative ? ethBalance?.value : (erc20Balance as bigint | undefined),
    refetch,
  };
}

// ─── Approve ──────────────────────────────────

export function useApprove() {
  const {
    writeContract,
    data: hash,
    isPending,
    error,
    reset,
  } = useWriteContract();

  const { isLoading: isConfirming, isSuccess } =
    useWaitForTransactionReceipt({ hash });

  const approve = (token: `0x${string}`, spender: `0x${string}`, amount: bigint) => {
    writeContract({
      address: token,
      abi: ERC20_ABI,
      functionName: "approve",
      args: [spender, amount],
    });
  };

  return { approve, hash, isPending, isConfirming, isSuccess, error, reset };
}

// ─── Swap ──────────────────────────────────

export interface SwapConfig {
  currency0: `0x${string}`;
  currency1: `0x${string}`;
  fee: number;
  tickSpacing: number;
  hooks: `0x${string}`;
  zeroForOne: boolean;
  amountIn: bigint;
  minAmountOut: bigint;
  deadline: bigint;
  value?: bigint;
}

export function useExecuteSwap() {
  const {
    writeContract,
    data: hash,
    isPending: isWriting,
    error: writeError,
    reset,
  } = useWriteContract();

  const { isLoading: isConfirming, isSuccess } =
    useWaitForTransactionReceipt({ hash });

  const swap = (config: SwapConfig) => {
    if (!contracts) return;

    writeContract({
      address: contracts.BastionRouter as `0x${string}`,
      abi: BastionRouterABI,
      functionName: "swapExactInput",
      args: [
        {
          currency0: config.currency0,
          currency1: config.currency1,
          fee: config.fee,
          tickSpacing: config.tickSpacing,
          hooks: config.hooks,
        },
        config.zeroForOne,
        config.amountIn,
        config.minAmountOut,
        config.deadline,
      ],
      value: config.value || 0n,
    });
  };

  return {
    swap,
    hash,
    isWriting,
    isConfirming,
    isSuccess,
    error: writeError,
    reset,
  };
}

// ─── Faucet ──────────────────────────────────

export const FAUCETS: Record<string, `0x${string}`> = {
  "0x410521668Ad1625527562CA90475406b1b9cB8Af": "0x5c45BE6ebc3a6559caFDaA4401BA925a28bf40cc",
  "0x69ce9bACB558F35bCAC2e6fd54caa8770AEE85d4": "0xFE2c5447a7FA44d0758090d2ceb926A1aBaFf620",
};

export function useFaucet(faucetAddress: `0x${string}` | undefined, account: `0x${string}` | undefined) {
  const { data: canClaimData } = useReadContract({
    address: faucetAddress,
    abi: FAUCET_ABI,
    functionName: "canClaim",
    args: account ? [account] : undefined,
    query: { enabled: !!faucetAddress && !!account },
  });

  const {
    writeContract,
    data: hash,
    isPending,
    error,
    reset,
  } = useWriteContract();

  const { isLoading: isConfirming, isSuccess } =
    useWaitForTransactionReceipt({ hash });

  const claim = () => {
    if (!faucetAddress) return;
    writeContract({
      address: faucetAddress,
      abi: FAUCET_ABI,
      functionName: "claim",
    });
  };

  return {
    canClaim: canClaimData as boolean | undefined,
    claim,
    hash,
    isPending,
    isConfirming,
    isSuccess,
    error,
    reset,
  };
}

// ─── Quote (placeholder) ──────────────────────────────────

export function useSwapQuote(
  _tokenIn: string | undefined,
  _tokenOut: string | undefined,
  _amountIn: string
) {
  const [debouncedAmount, setDebouncedAmount] = useState(_amountIn);

  useEffect(() => {
    const timer = setTimeout(() => setDebouncedAmount(_amountIn), 500);
    return () => clearTimeout(timer);
  }, [_amountIn]);

  // Without an on-chain quoter, we estimate 1:1 for same-decimal tokens
  // This is a rough approximation — real production would use a Quoter contract
  const amount = debouncedAmount && parseFloat(debouncedAmount) > 0
    ? debouncedAmount
    : "0";

  return {
    data: amount !== "0" ? amount : undefined,
    isLoading: false,
    error: null,
  };
}
