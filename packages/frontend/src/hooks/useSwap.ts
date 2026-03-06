"use client";

import { useEffect, useState } from "react";
import {
  useWriteContract,
  useWaitForTransactionReceipt,
  useReadContract,
  useBalance,
  usePublicClient,
  useChainId,
} from "wagmi";
import { useQuery } from "@tanstack/react-query";
import { parseUnits, formatUnits, encodeFunctionData, decodeFunctionResult } from "viem";
import { getContracts } from "@/config/contracts";
import { BastionRouterABI } from "@/config/abis";

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

  const { data: ethBalance, refetch: refetchEth } = useBalance({
    address: account,
    query: { enabled: !!account && isNative },
  });

  const { data: erc20Balance, refetch: refetchErc20 } = useReadContract({
    address: token,
    abi: ERC20_ABI,
    functionName: "balanceOf",
    args: account ? [account] : undefined,
    query: { enabled: !!token && !!account && !isNative },
  });

  return {
    balance: isNative ? ethBalance?.value : (erc20Balance as bigint | undefined),
    refetch: isNative ? refetchEth : refetchErc20,
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
  const chainId = useChainId();
  const contracts = getContracts(chainId);

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

// ─── Quote (on-chain simulation) ──────────────────────────────────

export interface QuoteParams {
  currency0: `0x${string}`;
  currency1: `0x${string}`;
  fee: number;
  tickSpacing: number;
  hooks: `0x${string}`;
  zeroForOne: boolean;
  amountIn: bigint;
}

// Dummy account for quoting — we override its balance/allowance via eth_call stateOverride
const QUOTE_ACCOUNT = "0x0000000000000000000000000000000000000001" as const;
const MAX_UINT256 = "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" as `0x${string}`;

function computeStorageSlots(account: `0x${string}`, spender: `0x${string}`) {
  // Solmate ERC20 layout: balanceOf at slot 3, allowance at slot 4
  // balanceOf[account] = keccak256(abi.encode(account, 3))
  // allowance[account][spender] = keccak256(abi.encode(spender, keccak256(abi.encode(account, 4))))
  const { keccak256: k, encodeAbiParameters } = require("viem") as typeof import("viem");
  const addrUint = [{ type: "address" as const }, { type: "uint256" as const }] as const;
  const balSlot = k(encodeAbiParameters(addrUint, [account, 3n]));
  const innerSlot = k(encodeAbiParameters(addrUint, [account, 4n]));
  const allowSlot = k(encodeAbiParameters(
    [{ type: "address" as const }, { type: "bytes32" as const }],
    [spender, innerSlot],
  ));
  return { balSlot, allowSlot };
}

export function useSwapQuote(params: QuoteParams | null) {
  const chainId = useChainId();
  const contracts = getContracts(chainId);
  const publicClient = usePublicClient();

  return useQuery({
    queryKey: [
      "swapQuote",
      params?.currency0,
      params?.currency1,
      params?.zeroForOne,
      params?.amountIn?.toString(),
    ],
    queryFn: async () => {
      if (!publicClient || !params || !contracts || params.amountIn <= 0n) return null;

      const inputToken = params.zeroForOne ? params.currency0 : params.currency1;
      const routerAddr = contracts.BastionRouter as `0x${string}`;

      const data = encodeFunctionData({
        abi: BastionRouterABI,
        functionName: "swapExactInput",
        args: [
          {
            currency0: params.currency0,
            currency1: params.currency1,
            fee: params.fee,
            tickSpacing: params.tickSpacing,
            hooks: params.hooks,
          },
          params.zeroForOne,
          params.amountIn,
          0n, // minAmountOut = 0 for quote
          BigInt(Math.floor(Date.now() / 1000) + 3600),
        ],
      });

      const isNativeInput = inputToken === "0x0000000000000000000000000000000000000000";
      const { balSlot, allowSlot } = computeStorageSlots(QUOTE_ACCOUNT, routerAddr);

      try {
        const result = await publicClient.call({
          to: routerAddr,
          data,
          account: QUOTE_ACCOUNT,
          value: isNativeInput ? params.amountIn : 0n,
          stateOverride: isNativeInput
            ? [
                {
                  // Give the dummy account enough ETH
                  address: QUOTE_ACCOUNT,
                  balance: params.amountIn * 2n,
                },
              ]
            : [
                {
                  address: inputToken,
                  stateDiff: [
                    { slot: balSlot, value: MAX_UINT256 },
                    { slot: allowSlot, value: MAX_UINT256 },
                  ],
                },
              ],
        });

        if (!result.data) return null;

        return decodeFunctionResult({
          abi: BastionRouterABI,
          functionName: "swapExactInput",
          data: result.data,
        }) as bigint;
      } catch {
        return null;
      }
    },
    enabled: !!publicClient && !!params && params.amountIn > 0n,
    refetchInterval: 15_000,
    staleTime: 10_000,
  });
}
