import { useState, useEffect, useCallback } from "react";
import { useReceiptWithTimeout } from "./useReceiptTimeout";
import {
  useWriteContract,
  useWaitForTransactionReceipt,
  useAccount,
  useChainId,
  usePublicClient,
  useSignTypedData,
} from "wagmi";
import { parseAbi, encodeAbiParameters, parseAbiParameters, parseEther, parseUnits } from "viem";
import { getContracts } from "@/config/contracts";
import { BastionPositionRouterABI } from "@/config/abis";

const erc20Abi = parseAbi([
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
]);

const ZERO_ADDR = "0x0000000000000000000000000000000000000000" as `0x${string}`;
const PERMIT2_ADDRESS = "0x000000000022D473030F116dDEE9F6B43aC78BA3" as `0x${string}`;
const MAX_UINT256 = BigInt("0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff");

export type CreatePoolStep =
  | "idle"
  | "checking-permit2"
  | "approving-permit2-token"
  | "confirming-permit2-token"
  | "approving-permit2-base"
  | "confirming-permit2-base"
  | "signing"
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

function generatePermit2Nonce(): bigint {
  const timestamp = BigInt(Date.now());
  const random = BigInt(Math.floor(Math.random() * 0xFFFFFFFF));
  return (timestamp << 32n) | random;
}

// EIP-712 types for Permit2 SignatureTransfer
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

export function useCreateBastionPool() {
  const { address } = useAccount();
  const chainId = useChainId();
  const contracts = getContracts(chainId);
  const publicClient = usePublicClient();

  const [step, setStep] = useState<CreatePoolStep>("idle");
  const [error, setError] = useState<Error | null>(null);
  const [input, setInput] = useState<CreatePoolInput | null>(null);

  // Approve token → Permit2
  const {
    writeContract: writeApproveToken,
    data: approveTokenHash,
    error: approveTokenError,
    reset: resetApproveToken,
  } = useWriteContract();
  const { isLoading: isApproveTokenLoading, isSuccess: isApproveTokenSuccess } =
    useWaitForTransactionReceipt({ hash: approveTokenHash });
  const { isSuccess: isApproveTokenConfirmed } = useReceiptWithTimeout(approveTokenHash, isApproveTokenLoading, isApproveTokenSuccess);

  // Approve base token → Permit2
  const {
    writeContract: writeApproveBase,
    data: approveBaseHash,
    error: approveBaseError,
    reset: resetApproveBase,
  } = useWriteContract();
  const { isLoading: isApproveBaseLoading, isSuccess: isApproveBaseSuccess } =
    useWaitForTransactionReceipt({ hash: approveBaseHash });
  const { isSuccess: isApproveBaseConfirmed } = useReceiptWithTimeout(approveBaseHash, isApproveBaseLoading, isApproveBaseSuccess);

  // Sign Permit2 typed data
  const {
    signTypedData,
    data: signature,
    error: signError,
    reset: resetSign,
  } = useSignTypedData();

  // Create pool
  const {
    writeContract: writeCreatePool,
    data: createPoolHash,
    error: createPoolError,
    reset: resetCreatePool,
  } = useWriteContract();
  const { isLoading: isCreatePoolLoading, isSuccess: isCreatePoolReceipt } =
    useWaitForTransactionReceipt({ hash: createPoolHash });
  const { isSuccess: isCreatePoolConfirmed } = useReceiptWithTimeout(createPoolHash, isCreatePoolLoading, isCreatePoolReceipt);

  // Stored permit data for use after signing
  const [permitState, setPermitState] = useState<{
    nonce: bigint;
    deadline: bigint;
    isBatch: boolean;
  } | null>(null);

  // --- State machine transitions ---

  // Token permit2 approval tx submitted → confirming
  useEffect(() => {
    if (approveTokenHash && step === "approving-permit2-token") {
      setStep("confirming-permit2-token");
    }
  }, [approveTokenHash, step]);

  // Token permit2 approval confirmed → check base or sign
  useEffect(() => {
    if (isApproveTokenConfirmed && step === "confirming-permit2-token" && input && contracts) {
      _afterTokenPermit2Approved();
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isApproveTokenConfirmed, step]);

  // Base permit2 approval tx submitted → confirming
  useEffect(() => {
    if (approveBaseHash && step === "approving-permit2-base") {
      setStep("confirming-permit2-base");
    }
  }, [approveBaseHash, step]);

  // Base permit2 approval confirmed → sign
  useEffect(() => {
    if (isApproveBaseConfirmed && step === "confirming-permit2-base") {
      _requestSignature(input ?? undefined);
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isApproveBaseConfirmed, step]);

  // Signature received → submit createPoolPermit2
  useEffect(() => {
    if (signature && step === "signing" && input && contracts && permitState) {
      setStep("creating");
      _submitCreatePoolPermit2(input, signature);
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [signature, step]);

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
    const err = approveTokenError || approveBaseError || signError || createPoolError;
    if (err) {
      setError(err);
      setStep("error");
    }
  }, [approveTokenError, approveBaseError, signError, createPoolError]);

  // --- Check Permit2 allowance ---
  async function _checkPermit2Allowance(token: `0x${string}`): Promise<bigint> {
    if (!publicClient || !address) return 0n;
    try {
      return await publicClient.readContract({
        address: token,
        abi: erc20Abi,
        functionName: "allowance",
        args: [address, PERMIT2_ADDRESS],
      });
    } catch {
      return 0n;
    }
  }

  // --- After token is approved to Permit2 ---
  // Called from useEffect where `input` state is available after re-render
  async function _afterTokenPermit2Approved() {
    if (!input || !contracts) return;
    const isNativeBase = input.baseToken === ZERO_ADDR;

    if (isNativeBase) {
      _requestSignature(input);
    } else {
      const baseAllowance = await _checkPermit2Allowance(input.baseToken);
      if (baseAllowance >= parseUnits(input.baseAmount, input.baseDecimals)) {
        _requestSignature(input);
      } else {
        setStep("approving-permit2-base");
        writeApproveBase({
          address: input.baseToken,
          abi: erc20Abi,
          functionName: "approve",
          args: [PERMIT2_ADDRESS, MAX_UINT256],
        });
      }
    }
  }

  // --- Request EIP-712 signature ---
  function _requestSignature(overrideInput?: CreatePoolInput) {
    const params = overrideInput || input;
    if (!params || !contracts || !address) return;
    setStep("signing");

    const isNativeBase = params.baseToken === ZERO_ADDR;
    const tokenWei = parseEther(params.tokenAmount);
    const baseWei = parseUnits(params.baseAmount, params.baseDecimals);
    const nonce = generatePermit2Nonce();
    const deadline = BigInt(Math.floor(Date.now() / 1000) + 1800); // 30 min

    const routerAddress = contracts.BastionPositionRouter as `0x${string}`;

    if (isNativeBase) {
      // Single permit for the issued token only
      setPermitState({ nonce, deadline, isBatch: false });

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
            token: params.tokenAddress,
            amount: tokenWei,
          },
          spender: routerAddress,
          nonce,
          deadline,
        },
      });
    } else {
      // Batch permit for both tokens
      // Tokens must be ordered: currency0 (lower address) first
      const baseAddr = params.baseToken.toLowerCase();
      const tokenAddr = params.tokenAddress.toLowerCase();
      const baseIsCurrency0 = baseAddr < tokenAddr;

      const permitted = baseIsCurrency0
        ? [
            { token: params.baseToken, amount: baseWei },
            { token: params.tokenAddress, amount: tokenWei },
          ]
        : [
            { token: params.tokenAddress, amount: tokenWei },
            { token: params.baseToken, amount: baseWei },
          ];

      setPermitState({ nonce, deadline, isBatch: true });

      signTypedData({
        domain: {
          name: "Permit2",
          chainId,
          verifyingContract: PERMIT2_ADDRESS,
        },
        types: PERMIT_BATCH_TRANSFER_FROM_TYPES,
        primaryType: "PermitBatchTransferFrom",
        message: {
          permitted,
          spender: routerAddress,
          nonce,
          deadline,
        },
      });
    }
  }

  // --- Submit createPoolPermit2 ---
  function _submitCreatePoolPermit2(params: CreatePoolInput, sig: `0x${string}`) {
    if (!contracts || !address || !permitState) return;

    const isNativeBase = params.baseToken === ZERO_ADDR;
    const baseWei = parseUnits(params.baseAmount, params.baseDecimals);
    const tokenWei = parseEther(params.tokenAmount);

    const baseAddr = params.baseToken.toLowerCase();
    const tokenAddr = params.tokenAddress.toLowerCase();
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
        params.tokenAddress,
        params.lockDuration,
        params.vestingDuration,
        [
          params.commitment.dailyWithdrawLimit,
          params.commitment.maxSellPercent,
        ] as const,
        [
          params.triggerConfig.lpRemovalThreshold,
          params.triggerConfig.dumpThresholdPercent,
          params.triggerConfig.dumpWindowSeconds,
          params.triggerConfig.taxDeviationThreshold,
          params.triggerConfig.slowRugWindowSeconds,
          params.triggerConfig.slowRugCumulativeThreshold,
        ] as const,
      ],
    );

    // Encode permitData based on single vs batch
    let permitData: `0x${string}`;

    if (isNativeBase) {
      // Single permit: encode Permit2Single struct (PermitTransferFrom + signature)
      permitData = encodeAbiParameters(
        parseAbiParameters([
          "((address token, uint256 amount) permitted, uint256 nonce, uint256 deadline)",
          "bytes",
        ]),
        [
          {
            permitted: { token: params.tokenAddress, amount: tokenWei },
            nonce: permitState.nonce,
            deadline: permitState.deadline,
          },
          sig,
        ],
      );
    } else {
      // Batch permit: encode Permit2Batch struct
      const permitted = baseIsCurrency0
        ? [
            { token: params.baseToken, amount: baseWei },
            { token: params.tokenAddress, amount: tokenWei },
          ]
        : [
            { token: params.tokenAddress, amount: tokenWei },
            { token: params.baseToken, amount: baseWei },
          ];

      permitData = encodeAbiParameters(
        parseAbiParameters([
          "((address token, uint256 amount)[] permitted, uint256 nonce, uint256 deadline)",
          "bytes",
        ]),
        [
          {
            permitted,
            nonce: permitState.nonce,
            deadline: permitState.deadline,
          },
          sig,
        ],
      );
    }

    writeCreatePool({
      address: contracts.BastionPositionRouter as `0x${string}`,
      abi: BastionPositionRouterABI,
      functionName: "createPoolPermit2",
      args: [
        params.tokenAddress,
        params.baseToken,
        3000,
        tokenWei,
        baseWei,
        sqrtPriceX96,
        hookData,
        permitData,
      ],
      value: isNativeBase ? baseWei : 0n,
    });
  }

  const isPoolAlreadyExists =
    step === "error" &&
    error !== null &&
    /PoolAlreadyInitialized|0x7983c051/.test(error.message);

  const startCreation = useCallback(
    async (params: CreatePoolInput) => {
      if (!contracts || !address) return;

      setInput(params);
      setError(null);
      setPermitState(null);
      resetApproveToken();
      resetApproveBase();
      resetSign();
      resetCreatePool();

      setStep("checking-permit2");

      try {
        // Validate token has deployed code
        if (publicClient) {
          const code = await publicClient.getCode({ address: params.tokenAddress });
          if (!code || code === "0x") {
            setError(new Error(`No contract found at token address ${params.tokenAddress}. Make sure the token is deployed.`));
            setStep("error");
            return;
          }
        }

        const tokenWei = parseEther(params.tokenAmount);
        const isNativeBase = params.baseToken === ZERO_ADDR;
        const baseWei = parseUnits(params.baseAmount, params.baseDecimals);

        // Check token allowance to Permit2
        const tokenAllowance = await _checkPermit2Allowance(params.tokenAddress);
        const needTokenApproval = tokenAllowance < tokenWei;

        // Check base allowance to Permit2 (only for ERC20 base)
        let needBaseApproval = false;
        if (!isNativeBase) {
          const baseAllowance = await _checkPermit2Allowance(params.baseToken);
          needBaseApproval = baseAllowance < baseWei;
        }

        if (!needTokenApproval && !needBaseApproval) {
          // Both approved to Permit2 — go straight to signing
          _requestSignature(params);
        } else if (!needTokenApproval && needBaseApproval) {
          // Token already approved to Permit2, need base approval
          setStep("approving-permit2-base");
          writeApproveBase({
            address: params.baseToken,
            abi: erc20Abi,
            functionName: "approve",
            args: [PERMIT2_ADDRESS, MAX_UINT256],
          });
        } else {
          // Need token approval to Permit2
          setStep("approving-permit2-token");
          writeApproveToken({
            address: params.tokenAddress,
            abi: erc20Abi,
            functionName: "approve",
            args: [PERMIT2_ADDRESS, MAX_UINT256],
          });
        }
      } catch (err) {
        setError(err instanceof Error ? err : new Error(String(err)));
        setStep("error");
      }
    },
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [contracts, address, writeApproveToken, writeApproveBase, resetApproveToken, resetApproveBase, resetSign, resetCreatePool, publicClient],
  );

  const reset = useCallback(() => {
    setStep("idle");
    setError(null);
    setInput(null);
    setPermitState(null);
    resetApproveToken();
    resetApproveBase();
    resetSign();
    resetCreatePool();
  }, [resetApproveToken, resetApproveBase, resetSign, resetCreatePool]);

  // Total steps: approve(s) + sign + create
  const totalSteps = (() => {
    if (!input) return 2; // sign + create
    const isNativeBase = input.baseToken === ZERO_ADDR;
    // Worst case: approve token + approve base + sign + create = 4
    // Best case: sign + create = 2
    if (isNativeBase) return 3; // approve token (maybe) + sign + create
    return 4; // approve token + approve base + sign + create
  })();

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
