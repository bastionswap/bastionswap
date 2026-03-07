"use client";

import { useEffect, useState } from "react";
import {
  useWriteContract,
  useWaitForTransactionReceipt,
  useChainId,
  useSignTypedData,
} from "wagmi";
import { useQuery } from "@tanstack/react-query";
import { gql } from "graphql-request";
import { graphClient } from "@/config/subgraph";
import { getContracts } from "@/config/contracts";
import { BastionRouterABI } from "@/config/abis";

const PERMIT2_ADDRESS = "0x000000000022D473030F116dDEE9F6B43aC78BA3" as `0x${string}`;

const PERMIT_TRANSFER_FROM_TYPES = {
  PermitTransferFrom: [
    { name: "permitted", type: "TokenPermissions" },
    { name: "spender", type: "address" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
  TokenPermissions: [
    { name: "token", type: "address" },
    { name: "amount", type: "uint256" },
  ],
} as const;

const PERMIT_BATCH_TRANSFER_FROM_TYPES = {
  PermitBatchTransferFrom: [
    { name: "permitted", type: "TokenPermissions[]" },
    { name: "spender", type: "address" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
  TokenPermissions: [
    { name: "token", type: "address" },
    { name: "amount", type: "uint256" },
  ],
} as const;

function generatePermit2Nonce(): bigint {
  const timestamp = BigInt(Date.now());
  const random = BigInt(Math.floor(Math.random() * 0xFFFFFFFF));
  return (timestamp << 32n) | random;
}

// ─── Subgraph: User Positions ──────────────────────────────────

export interface SubgraphPosition {
  id: string;
  owner: string;
  tickLower: number;
  tickUpper: number;
  liquidity: string;
  isFullRange: boolean;
  createdAt: string;
  lastUpdatedAt: string;
}

const USER_POSITIONS_QUERY = gql`
  query UserPositions($poolId: String!, $owner: Bytes!) {
    positions(
      where: { pool: $poolId, owner: $owner, liquidity_gt: "0" }
      orderBy: createdAt
      orderDirection: desc
    ) {
      id
      owner
      tickLower
      tickUpper
      liquidity
      isFullRange
      createdAt
      lastUpdatedAt
    }
  }
`;

export function useUserPositions(poolId: string | undefined, userAddress: string | undefined) {
  return useQuery({
    queryKey: ["userPositions", poolId, userAddress],
    queryFn: () =>
      graphClient.request<{ positions: SubgraphPosition[] }>(USER_POSITIONS_QUERY, {
        poolId: poolId!.toLowerCase(),
        owner: userAddress!.toLowerCase(),
      }),
    select: (data) => data.positions,
    enabled: !!poolId && !!userAddress,
    refetchInterval: 15_000,
  });
}

// ─── Add Liquidity V2 ──────────────────────────────────

export interface AddLiquidityConfig {
  poolKey: {
    currency0: `0x${string}`;
    currency1: `0x${string}`;
    fee: number;
    tickSpacing: number;
    hooks: `0x${string}`;
  };
  tickLower: number;
  tickUpper: number;
  amount0Max: bigint;
  amount1Max: bigint;
  deadline: bigint;
  value?: bigint; // ETH to send
}

export function useAddLiquidity() {
  const chainId = useChainId();
  const contracts = getContracts(chainId);

  const {
    signTypedData,
    data: signature,
    error: signError,
    reset: resetSign,
    isPending: isSigning,
  } = useSignTypedData();

  const {
    writeContract,
    data: hash,
    isPending: isWriting,
    error: writeError,
    reset: resetWrite,
  } = useWriteContract();

  const { isLoading: isConfirming, isSuccess } =
    useWaitForTransactionReceipt({ hash });

  const [pendingAdd, setPendingAdd] = useState<AddLiquidityConfig | null>(null);
  const [permitNonce, setPermitNonce] = useState<bigint>(0n);
  const [permitDeadline, setPermitDeadline] = useState<bigint>(0n);

  useEffect(() => {
    if (signature && pendingAdd && contracts) {
      const config = pendingAdd;
      const hasNative =
        config.poolKey.currency0 === "0x0000000000000000000000000000000000000000";

      let permitData: `0x${string}`;
      if (hasNative) {
        // Single Permit2 for the ERC20 side (currency1)
        const { encodeAbiParameters } = require("viem") as typeof import("viem");
        permitData = encodeAbiParameters(
          [
            {
              type: "tuple",
              components: [
                { type: "tuple", name: "permitted", components: [{ type: "address", name: "token" }, { type: "uint256", name: "amount" }] },
                { type: "uint256", name: "nonce" },
                { type: "uint256", name: "deadline" },
              ],
            },
            { type: "bytes" },
          ],
          [
            {
              permitted: { token: config.poolKey.currency1, amount: config.amount1Max },
              nonce: permitNonce,
              deadline: permitDeadline,
            },
            signature as `0x${string}`,
          ]
        );
      } else {
        // Batch Permit2 for both ERC20s
        const { encodeAbiParameters } = require("viem") as typeof import("viem");
        permitData = encodeAbiParameters(
          [
            {
              type: "tuple",
              components: [
                {
                  type: "tuple[]",
                  name: "permitted",
                  components: [{ type: "address", name: "token" }, { type: "uint256", name: "amount" }],
                },
                { type: "uint256", name: "nonce" },
                { type: "uint256", name: "deadline" },
              ],
            },
            { type: "bytes" },
          ],
          [
            {
              permitted: [
                { token: config.poolKey.currency0, amount: config.amount0Max },
                { token: config.poolKey.currency1, amount: config.amount1Max },
              ],
              nonce: permitNonce,
              deadline: permitDeadline,
            },
            signature as `0x${string}`,
          ]
        );
      }

      writeContract({
        address: contracts.BastionRouter as `0x${string}`,
        abi: BastionRouterABI,
        functionName: "addLiquidityV2Permit2",
        args: [
          config.poolKey,
          config.tickLower,
          config.tickUpper,
          config.amount0Max,
          config.amount1Max,
          config.deadline,
          permitData,
        ],
        value: config.value || 0n,
      });
      setPendingAdd(null);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [signature]);

  const addLiquidity = (config: AddLiquidityConfig) => {
    if (!contracts) return;

    const hasNative =
      config.poolKey.currency0 === "0x0000000000000000000000000000000000000000";

    if (hasNative && config.amount1Max === 0n) {
      // ETH-only (no ERC20 to permit)
      writeContract({
        address: contracts.BastionRouter as `0x${string}`,
        abi: BastionRouterABI,
        functionName: "addLiquidityV2",
        args: [
          config.poolKey,
          config.tickLower,
          config.tickUpper,
          config.amount0Max,
          config.amount1Max,
          config.deadline,
        ],
        value: config.value || 0n,
      });
      return;
    }

    // Need Permit2 for ERC20(s)
    const nonce = generatePermit2Nonce();
    const deadline = config.deadline;
    const routerAddress = contracts.BastionRouter as `0x${string}`;

    setPendingAdd(config);
    setPermitNonce(nonce);
    setPermitDeadline(deadline);

    if (hasNative) {
      // Sign single permit for currency1
      signTypedData({
        domain: {
          name: "Permit2",
          chainId,
          verifyingContract: PERMIT2_ADDRESS,
        },
        types: PERMIT_TRANSFER_FROM_TYPES,
        primaryType: "PermitTransferFrom",
        message: {
          permitted: {
            token: config.poolKey.currency1,
            amount: config.amount1Max,
          },
          spender: routerAddress,
          nonce,
          deadline,
        },
      });
    } else {
      // Sign batch permit for both tokens
      signTypedData({
        domain: {
          name: "Permit2",
          chainId,
          verifyingContract: PERMIT2_ADDRESS,
        },
        types: PERMIT_BATCH_TRANSFER_FROM_TYPES,
        primaryType: "PermitBatchTransferFrom",
        message: {
          permitted: [
            { token: config.poolKey.currency0, amount: config.amount0Max },
            { token: config.poolKey.currency1, amount: config.amount1Max },
          ],
          spender: routerAddress,
          nonce,
          deadline,
        },
      });
    }
  };

  const reset = () => {
    resetSign();
    resetWrite();
    setPendingAdd(null);
  };

  return {
    addLiquidity,
    hash,
    isWriting: isWriting || isSigning,
    isConfirming,
    isSuccess,
    error: signError || writeError,
    reset,
  };
}

// ─── Remove Liquidity V2 ──────────────────────────────────

export interface RemoveLiquidityConfig {
  poolKey: {
    currency0: `0x${string}`;
    currency1: `0x${string}`;
    fee: number;
    tickSpacing: number;
    hooks: `0x${string}`;
  };
  tickLower: number;
  tickUpper: number;
  liquidityToRemove: bigint;
  amount0Min: bigint;
  amount1Min: bigint;
  deadline: bigint;
}

export function useRemoveLiquidity() {
  const chainId = useChainId();
  const contracts = getContracts(chainId);

  const {
    writeContract,
    data: hash,
    isPending: isWriting,
    error,
    reset,
  } = useWriteContract();

  const { isLoading: isConfirming, isSuccess } =
    useWaitForTransactionReceipt({ hash });

  const removeLiquidity = (config: RemoveLiquidityConfig) => {
    if (!contracts) return;

    writeContract({
      address: contracts.BastionRouter as `0x${string}`,
      abi: BastionRouterABI,
      functionName: "removeLiquidityV2",
      args: [
        config.poolKey,
        config.tickLower,
        config.tickUpper,
        config.liquidityToRemove,
        config.amount0Min,
        config.amount1Min,
        config.deadline,
      ],
    });
  };

  return {
    removeLiquidity,
    hash,
    isWriting,
    isConfirming,
    isSuccess,
    error,
    reset,
  };
}

// ─── Collect Fees ──────────────────────────────────

export function useCollectFees() {
  const chainId = useChainId();
  const contracts = getContracts(chainId);

  const {
    writeContract,
    data: hash,
    isPending: isWriting,
    error,
    reset,
  } = useWriteContract();

  const { isLoading: isConfirming, isSuccess } =
    useWaitForTransactionReceipt({ hash });

  const collectFees = (
    poolKey: {
      currency0: `0x${string}`;
      currency1: `0x${string}`;
      fee: number;
      tickSpacing: number;
      hooks: `0x${string}`;
    },
    tickLower: number,
    tickUpper: number
  ) => {
    if (!contracts) return;

    writeContract({
      address: contracts.BastionRouter as `0x${string}`,
      abi: BastionRouterABI,
      functionName: "collectFees",
      args: [poolKey, tickLower, tickUpper],
    });
  };

  return {
    collectFees,
    hash,
    isWriting,
    isConfirming,
    isSuccess,
    error,
    reset,
  };
}
