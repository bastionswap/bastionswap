import { useState, useEffect, useCallback } from "react";
import {
  useWriteContract,
  useWaitForTransactionReceipt,
  useAccount,
  useChainId,
} from "wagmi";
import { parseAbi, encodeAbiParameters, parseAbiParameters, parseEther, parseUnits } from "viem";
import { getContracts } from "@/config/contracts";
import { BastionRouterABI } from "@/config/abis";

const erc20Abi = parseAbi([
  "function approve(address spender, uint256 amount) returns (bool)",
]);

const ZERO_ADDR = "0x0000000000000000000000000000000000000000" as `0x${string}`;

export type CreatePoolStep =
  | "idle"
  | "approving-token"
  | "confirming-token-approval"
  | "approving-base"
  | "confirming-base-approval"
  | "creating"
  | "confirming-creation"
  | "done"
  | "error";

export interface CreatePoolInput {
  tokenAddress: `0x${string}`;
  baseToken: `0x${string}`;  // address(0) for native ETH, or WETH/USDC address
  baseAmount: string;        // in base token units (e.g. "1.5" ETH or "2000" USDC)
  baseDecimals: number;      // 18 for ETH/WETH, 6 for USDC
  tokenAmount: string;       // in token units (e.g. "1000000")
  lockDuration: number;      // in seconds (min 7 days)
  vestingDuration: number;   // in seconds (min 7 days)
  commitment: {
    dailyWithdrawLimit: number;
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

function computeSqrtPriceX96(amount0: bigint, amount1: bigint): bigint {
  // sqrtPriceX96 = sqrt(amount1 / amount0) * 2^96
  if (amount0 === 0n || amount1 === 0n) {
    return 79228162514264337593543950336n; // 1:1 fallback
  }
  const numerator = amount1 * (1n << 192n);
  const ratio = numerator / amount0;
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

  // Approve issued token → router
  const {
    writeContract: writeApproveToken,
    data: approveTokenHash,
    error: approveTokenError,
    reset: resetApproveToken,
  } = useWriteContract();
  const { isSuccess: isApproveTokenConfirmed } =
    useWaitForTransactionReceipt({ hash: approveTokenHash });

  // Approve base token (WETH/USDC) → router
  const {
    writeContract: writeApproveBase,
    data: approveBaseHash,
    error: approveBaseError,
    reset: resetApproveBase,
  } = useWriteContract();
  const { isSuccess: isApproveBaseConfirmed } =
    useWaitForTransactionReceipt({ hash: approveBaseHash });

  // Create pool
  const {
    writeContract: writeCreatePool,
    data: createPoolHash,
    error: createPoolError,
    reset: resetCreatePool,
  } = useWriteContract();
  const { isSuccess: isCreatePoolConfirmed } =
    useWaitForTransactionReceipt({ hash: createPoolHash });

  // --- State machine transitions ---

  // Token approval tx submitted → confirming
  useEffect(() => {
    if (approveTokenHash && step === "approving-token") {
      setStep("confirming-token-approval");
    }
  }, [approveTokenHash, step]);

  // Token approval confirmed → approve base (if ERC20) or create pool (if native ETH)
  useEffect(() => {
    if (isApproveTokenConfirmed && step === "confirming-token-approval" && input && contracts) {
      const isNativeBase = input.baseToken === ZERO_ADDR;
      if (isNativeBase) {
        // Skip base approval, go straight to create
        setStep("creating");
        _submitCreatePool();
      } else {
        // Need to approve base token too
        setStep("approving-base");
        const baseWei = parseUnits(input.baseAmount, input.baseDecimals);
        writeApproveBase({
          address: input.baseToken,
          abi: erc20Abi,
          functionName: "approve",
          args: [contracts.BastionRouter as `0x${string}`, baseWei],
        });
      }
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isApproveTokenConfirmed, step]);

  // Base approval tx submitted → confirming
  useEffect(() => {
    if (approveBaseHash && step === "approving-base") {
      setStep("confirming-base-approval");
    }
  }, [approveBaseHash, step]);

  // Base approval confirmed → create pool
  useEffect(() => {
    if (isApproveBaseConfirmed && step === "confirming-base-approval") {
      setStep("creating");
      _submitCreatePool();
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isApproveBaseConfirmed, step]);

  // Create pool tx submitted → confirming
  useEffect(() => {
    if (createPoolHash && step === "creating") {
      setStep("confirming-creation");
    }
  }, [createPoolHash, step]);

  // Create pool confirmed → done
  useEffect(() => {
    if (isCreatePoolConfirmed && step === "confirming-creation") {
      setStep("done");
    }
  }, [isCreatePoolConfirmed, step]);

  // Error handling
  useEffect(() => {
    const err = approveTokenError || approveBaseError || createPoolError;
    if (err) {
      setError(err);
      setStep("error");
    }
  }, [approveTokenError, approveBaseError, createPoolError]);

  // --- Submit create pool transaction ---
  function _submitCreatePool() {
    if (!input || !contracts || !address) return;

    const isNativeBase = input.baseToken === ZERO_ADDR;
    const baseWei = parseUnits(input.baseAmount, input.baseDecimals);
    const tokenWei = parseEther(input.tokenAmount);

    // Sort currencies: lower address is currency0
    const baseAddr = input.baseToken.toLowerCase();
    const tokenAddr = input.tokenAddress.toLowerCase();
    const baseIsCurrency0 = baseAddr < tokenAddr;
    const amount0 = baseIsCurrency0 ? baseWei : tokenWei;
    const amount1 = baseIsCurrency0 ? tokenWei : baseWei;
    const sqrtPriceX96 = computeSqrtPriceX96(amount0, amount1);

    const hookData = encodeAbiParameters(
      parseAbiParameters([
        "address",
        "address",
        "uint40",
        "uint40",
        "(uint16,uint16)",
        "(uint16,uint16,uint40,uint16,uint40,uint16)",
      ]),
      [
        address,
        input.tokenAddress,
        input.lockDuration,
        input.vestingDuration,
        [
          input.commitment.dailyWithdrawLimit,
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

    writeCreatePool({
      address: contracts.BastionRouter as `0x${string}`,
      abi: BastionRouterABI,
      functionName: "createPool",
      args: [
        input.tokenAddress,
        input.baseToken,
        3000,
        tokenWei,
        sqrtPriceX96,
        hookData,
      ],
      value: isNativeBase ? baseWei : 0n,
    });
  }

  const isPoolAlreadyExists =
    step === "error" &&
    error !== null &&
    /PoolAlreadyInitialized|0x7983c051/.test(error.message);

  const startCreation = useCallback(
    (params: CreatePoolInput) => {
      if (!contracts) return;

      setInput(params);
      setError(null);
      setStep("approving-token");
      resetApproveToken();
      resetApproveBase();
      resetCreatePool();

      const totalTokenNeeded = parseEther(params.tokenAmount);
      writeApproveToken({
        address: params.tokenAddress,
        abi: erc20Abi,
        functionName: "approve",
        args: [contracts.BastionRouter as `0x${string}`, totalTokenNeeded],
      });
    },
    [contracts, writeApproveToken, resetApproveToken, resetApproveBase, resetCreatePool],
  );

  const reset = useCallback(() => {
    setStep("idle");
    setError(null);
    setInput(null);
    resetApproveToken();
    resetApproveBase();
    resetCreatePool();
  }, [resetApproveToken, resetApproveBase, resetCreatePool]);

  const totalSteps = input && input.baseToken !== ZERO_ADDR ? 3 : 2;

  return {
    step,
    error,
    isPoolAlreadyExists,
    hash: createPoolHash,
    startCreation,
    reset,
    totalSteps,
    isActive: !["idle", "done", "error"].includes(step),
  };
}
