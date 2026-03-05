import { useState, useEffect, useCallback } from "react";
import {
  useWriteContract,
  useWaitForTransactionReceipt,
  useAccount,
  useChainId,
} from "wagmi";
import { parseAbi, encodeAbiParameters, parseAbiParameters, parseEther } from "viem";
import { getContracts } from "@/config/contracts";
import { BastionRouterABI } from "@/config/abis";

const erc20Abi = parseAbi([
  "function approve(address spender, uint256 amount) returns (bool)",
]);

export type CreatePoolStep =
  | "idle"
  | "approving-hook"
  | "confirming-hook-approval"
  | "approving-router"
  | "confirming-router-approval"
  | "creating"
  | "confirming-creation"
  | "done"
  | "error";

export interface CreatePoolInput {
  tokenAddress: `0x${string}`;
  ethAmount: string;       // in ETH (e.g. "1.5")
  tokenAmount: string;     // in token units (e.g. "1000000")
  escrowAmount: string;    // in token units
  vestingSchedule: { timeOffset: number; basisPoints: number }[];
  commitment: {
    dailyWithdrawLimit: number;
    lockDuration: number;
    maxSellPercent: number;
  };
  triggerConfig: {
    lpRemovalThreshold: number;
    dumpThresholdPercent: number;
    dumpWindowSeconds: number;
    taxDeviationThreshold: number;
    slowRugWindowSeconds: number;
    slowRugCumulativeThreshold: number;
  };
}

export const DEFAULT_TRIGGER_CONFIG = {
  lpRemovalThreshold: 5000,
  dumpThresholdPercent: 3000,
  dumpWindowSeconds: 86400,
  taxDeviationThreshold: 500,
  slowRugWindowSeconds: 86400,
  slowRugCumulativeThreshold: 8000,
};

function computeSqrtPriceX96(ethAmount: bigint, tokenAmount: bigint): bigint {
  // currency0 = address(0) (native ETH), currency1 = token
  // price = token1_per_token0 = tokenAmount / ethAmount
  // sqrtPriceX96 = sqrt(tokenAmount / ethAmount) * 2^96
  // = sqrt(tokenAmount * 2^192 / ethAmount)
  if (ethAmount === 0n || tokenAmount === 0n) {
    return 79228162514264337593543950336n; // 1:1 fallback
  }
  const numerator = tokenAmount * (1n << 192n);
  const ratio = numerator / ethAmount;
  return sqrt(ratio);
}

function sqrt(x: bigint): bigint {
  if (x === 0n) return 0n;
  let z = x;
  let y = (z + 1n) / 2n;
  while (y < z) {
    z = y;
    y = (z + x / z) / 2n;
  }
  return z;
}

export function useCreateBastionPool() {
  const { address } = useAccount();
  const chainId = useChainId();
  const contracts = getContracts(chainId);

  const [step, setStep] = useState<CreatePoolStep>("idle");
  const [error, setError] = useState<Error | null>(null);
  const [input, setInput] = useState<CreatePoolInput | null>(null);

  // Step 1: Approve token → BastionHook (for escrow transfer)
  const {
    writeContract: writeApproveHook,
    data: approveHookHash,
    isPending: isApproveHookPending,
    error: approveHookError,
    reset: resetApproveHook,
  } = useWriteContract();

  const { isSuccess: isApproveHookConfirmed } = useWaitForTransactionReceipt({
    hash: approveHookHash,
  });

  // Step 2: Approve token → BastionRouter (for LP settlement)
  const {
    writeContract: writeApproveRouter,
    data: approveRouterHash,
    isPending: isApproveRouterPending,
    error: approveRouterError,
    reset: resetApproveRouter,
  } = useWriteContract();

  const { isSuccess: isApproveRouterConfirmed } =
    useWaitForTransactionReceipt({ hash: approveRouterHash });

  // Step 3: Create pool
  const {
    writeContract: writeCreatePool,
    data: createPoolHash,
    isPending: isCreatePoolPending,
    error: createPoolError,
    reset: resetCreatePool,
  } = useWriteContract();

  const { isSuccess: isCreatePoolConfirmed } = useWaitForTransactionReceipt({
    hash: createPoolHash,
  });

  // Chain: hook approval confirmed → start router approval
  useEffect(() => {
    if (isApproveHookConfirmed && step === "confirming-hook-approval" && input && contracts) {
      setStep("approving-router");
      const totalTokenNeeded = parseEther(input.tokenAmount);
      writeApproveRouter({
        address: input.tokenAddress,
        abi: erc20Abi,
        functionName: "approve",
        args: [contracts.BastionRouter as `0x${string}`, totalTokenNeeded],
      });
    }
  }, [isApproveHookConfirmed, step, input, contracts, writeApproveRouter]);

  // Chain: router approval confirmed → create pool
  useEffect(() => {
    if (isApproveRouterConfirmed && step === "confirming-router-approval" && input && contracts && address) {
      setStep("creating");

      const ethWei = parseEther(input.ethAmount);
      const tokenWei = parseEther(input.tokenAmount);
      const escrowWei = parseEther(input.escrowAmount);
      const sqrtPriceX96 = computeSqrtPriceX96(ethWei, tokenWei);

      const hookData = encodeAbiParameters(
        parseAbiParameters([
          "address",
          "address",
          "uint256",
          "(uint40,uint16)[]",
          "(uint16,uint40,uint16)",
          "(uint16,uint16,uint40,uint16,uint40,uint16)",
        ]),
        [
          address,
          input.tokenAddress,
          escrowWei,
          input.vestingSchedule.map((s) =>
            [s.timeOffset, s.basisPoints] as const
          ),
          [
            input.commitment.dailyWithdrawLimit,
            input.commitment.lockDuration,
            input.commitment.maxSellPercent,
          ] as const,
          [
            input.triggerConfig.lpRemovalThreshold,
            input.triggerConfig.dumpThresholdPercent,
            input.triggerConfig.dumpWindowSeconds,
            input.triggerConfig.taxDeviationThreshold,
            input.triggerConfig.slowRugWindowSeconds,
            input.triggerConfig.slowRugCumulativeThreshold,
          ] as const,
        ],
      );

      const hookAddr = contracts.BastionHook as `0x${string}`;
      const zeroAddr = "0x0000000000000000000000000000000000000000" as `0x${string}`;

      writeCreatePool({
        address: contracts.BastionRouter as `0x${string}`,
        abi: BastionRouterABI,
        functionName: "createPool",
        args: [
          {
            key: {
              currency0: zeroAddr,
              currency1: input.tokenAddress,
              fee: 3000,
              tickSpacing: 60,
              hooks: hookAddr,
            },
            sqrtPriceX96,
            amount0Max: ethWei,
            amount1Max: tokenWei,
            hookData,
          },
        ],
        value: ethWei,
      });
    }
  }, [isApproveRouterConfirmed, step, input, contracts, address, writeCreatePool]);

  // Chain: pool creation confirmed → done
  useEffect(() => {
    if (isCreatePoolConfirmed && step === "confirming-creation") {
      setStep("done");
    }
  }, [isCreatePoolConfirmed, step]);

  // Track pending → confirming transitions
  useEffect(() => {
    if (approveHookHash && step === "approving-hook") {
      setStep("confirming-hook-approval");
    }
  }, [approveHookHash, step]);

  useEffect(() => {
    if (approveRouterHash && step === "approving-router") {
      setStep("confirming-router-approval");
    }
  }, [approveRouterHash, step]);

  useEffect(() => {
    if (createPoolHash && step === "creating") {
      setStep("confirming-creation");
    }
  }, [createPoolHash, step]);

  // Error handling
  useEffect(() => {
    const err = approveHookError || approveRouterError || createPoolError;
    if (err) {
      setError(err);
      setStep("error");
    }
  }, [approveHookError, approveRouterError, createPoolError]);

  const startCreation = useCallback(
    (params: CreatePoolInput) => {
      if (!contracts) return;

      setInput(params);
      setError(null);
      setStep("approving-hook");
      resetApproveHook();
      resetApproveRouter();
      resetCreatePool();

      const escrowWei = parseEther(params.escrowAmount);
      writeApproveHook({
        address: params.tokenAddress,
        abi: erc20Abi,
        functionName: "approve",
        args: [contracts.BastionHook as `0x${string}`, escrowWei],
      });
    },
    [contracts, writeApproveHook, resetApproveHook, resetApproveRouter, resetCreatePool],
  );

  const reset = useCallback(() => {
    setStep("idle");
    setError(null);
    setInput(null);
    resetApproveHook();
    resetApproveRouter();
    resetCreatePool();
  }, [resetApproveHook, resetApproveRouter, resetCreatePool]);

  return {
    step,
    error,
    hash: createPoolHash,
    startCreation,
    reset,
    isActive: step !== "idle" && step !== "done" && step !== "error",
  };
}
