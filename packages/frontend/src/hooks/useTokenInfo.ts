"use client";

import { useReadContracts } from "wagmi";

const ERC20_ABI = [
  {
    type: "function",
    name: "name",
    inputs: [],
    outputs: [{ type: "string" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "symbol",
    inputs: [],
    outputs: [{ type: "string" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "decimals",
    inputs: [],
    outputs: [{ type: "uint8" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "totalSupply",
    inputs: [],
    outputs: [{ type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "balanceOf",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ type: "uint256" }],
    stateMutability: "view",
  },
] as const;

export interface TokenInfo {
  address: string;
  name: string | null;
  symbol: string | null;
  decimals: number | null;
}

const NATIVE_ETH = "0x0000000000000000000000000000000000000000";

function isNativeETH(address: string | undefined): boolean {
  return !!address && address.toLowerCase() === NATIVE_ETH;
}

export function useTokenInfo(address: `0x${string}` | undefined) {
  const isETH = isNativeETH(address);

  const { data, isLoading } = useReadContracts({
    contracts: address && !isETH
      ? [
          { address, abi: ERC20_ABI, functionName: "name" },
          { address, abi: ERC20_ABI, functionName: "symbol" },
          { address, abi: ERC20_ABI, functionName: "decimals" },
        ]
      : undefined,
    query: { enabled: !!address && !isETH },
  });

  if (isETH) {
    return {
      name: "Ether",
      symbol: "ETH",
      decimals: 18,
      isLoading: false,
      displayName: "ETH",
    };
  }

  const name = data?.[0]?.status === "success" ? (data[0].result as string) : null;
  const symbol = data?.[1]?.status === "success" ? (data[1].result as string) : null;
  const decimals = data?.[2]?.status === "success" ? Number(data[2].result) : null;

  return {
    name,
    symbol,
    decimals,
    isLoading,
    displayName: symbol || (address ? `${address.slice(0, 6)}...${address.slice(-4)}` : ""),
  };
}

export function useTokenBalance(
  tokenAddress: `0x${string}` | undefined,
  account: `0x${string}` | undefined
) {
  const { data, isLoading } = useReadContracts({
    contracts:
      tokenAddress && account
        ? [
            {
              address: tokenAddress,
              abi: ERC20_ABI,
              functionName: "balanceOf",
              args: [account],
            },
            {
              address: tokenAddress,
              abi: ERC20_ABI,
              functionName: "totalSupply",
            },
          ]
        : undefined,
    query: { enabled: !!tokenAddress && !!account },
  });

  const balance = data?.[0]?.status === "success" ? (data[0].result as bigint) : undefined;
  const totalSupply = data?.[1]?.status === "success" ? (data[1].result as bigint) : undefined;

  return { balance, totalSupply, isLoading };
}
