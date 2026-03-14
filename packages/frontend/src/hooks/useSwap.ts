"use client";

import { useEffect, useRef, useState } from "react";
import { useReceiptWithTimeout } from "./useReceiptTimeout";
import {
  useWriteContract,
  useWaitForTransactionReceipt,
  useReadContract,
  useBalance,
  usePublicClient,
  useChainId,
  useSignTypedData,
  useAccount,
} from "wagmi";
import { useQuery } from "@tanstack/react-query";
import { parseUnits, formatUnits, encodeFunctionData, decodeFunctionResult, decodeErrorResult, encodeAbiParameters, parseAbiParameters } from "viem";
import { getContracts } from "@/config/contracts";
import { BastionSwapRouterABI, BastionHookABI, PoolManagerABI } from "@/config/abis";
import { parseErrorMessage, matchSelector } from "@/utils/errorMessages";

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

const PERMIT2_ADDRESS = "0x000000000022D473030F116dDEE9F6B43aC78BA3" as `0x${string}`;
const MAX_UINT256 = BigInt("0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff");

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

function generatePermit2Nonce(): bigint {
  const timestamp = BigInt(Date.now());
  const random = BigInt(Math.floor(Math.random() * 0xFFFFFFFF));
  return (timestamp << 32n) | random;
}

// ─── Error re-simulation helpers ──────────────────────────────────

/** Combined error ABI entries from all contracts for revert data decoding */
const COMBINED_ERROR_ABI = [
  ...(BastionHookABI as any[]).filter((e) => e.type === "error"),
  ...(BastionSwapRouterABI as any[]).filter((e) => e.type === "error"),
  ...(PoolManagerABI as any[]).filter((e) => e.type === "error"),
];

/** Walk the error cause chain looking for hex revert data */
function extractRevertDataFromError(error: unknown): `0x${string}` | null {
  if (!error || typeof error !== "object") return null;
  let e: any = error;
  for (let depth = 0; depth < 10 && e; depth++) {
    // .data as hex string (RawContractError, RpcRequestError)
    if (typeof e.data === "string" && e.data.startsWith("0x") && e.data.length >= 10) {
      return e.data as `0x${string}`;
    }
    // .data as object with nested .data (some viem wrappers)
    if (e.data && typeof e.data === "object" && typeof e.data.data === "string" && e.data.data.startsWith("0x")) {
      return e.data.data as `0x${string}`;
    }
    // .details may contain hex (some RPCs embed revert data in the error message)
    if (typeof e.details === "string") {
      const hexMatch = e.details.match(/(?:^|[\s:])?(0x[0-9a-fA-F]{8,})/);
      if (hexMatch) return hexMatch[1] as `0x${string}`;
    }
    e = e.cause;
  }
  // Try .walk() for viem errors
  if (typeof (error as any).walk === "function") {
    try {
      const walked = (error as any).walk((e: any) => typeof e?.data === "string" && e.data.startsWith("0x"));
      if (walked?.data && typeof walked.data === "string") return walked.data as `0x${string}`;
    } catch {}
  }
  return null;
}

/** Encoded calldata + value for exact replay */
interface RawCallData {
  data: `0x${string}`;
  value: bigint;
}

/**
 * Re-simulate a failed swap via eth_call to extract revert data.
 * Replays the exact same call — eth_call often returns revert data
 * even when eth_estimateGas (used by writeContract internally) doesn't.
 */
async function resimulateForError(
  publicClient: any,
  routerAddr: `0x${string}`,
  account: `0x${string}`,
  callData: RawCallData,
): Promise<string | null> {
  try {
    await publicClient.call({
      to: routerAddr,
      data: callData.data,
      account,
      value: callData.value,
    });
    return null; // Simulation passed — error was elsewhere
  } catch (err) {
    const revertData = extractRevertDataFromError(err);
    if (!revertData) return null;

    // Try friendly message via selector map (handles WrappedError unwrapping)
    const friendly = matchSelector(revertData);
    if (friendly) return friendly;

    // Try decoding error name via combined ABI
    try {
      const decoded = decodeErrorResult({ abi: COMBINED_ERROR_ABI as any, data: revertData });
      return `Transaction failed: ${decoded.errorName}`;
    } catch {}

    return null;
  }
}

// ─── Token Allowance (checks against Permit2) ──────────────────────────────────

export function useTokenAllowance(
  token: `0x${string}` | undefined,
  owner: `0x${string}` | undefined,
  spender: `0x${string}` | undefined
) {
  const isNative = token === "0x0000000000000000000000000000000000000000";
  // Check allowance against Permit2 (not the router)
  const { data, refetch } = useReadContract({
    address: token,
    abi: ERC20_ABI,
    functionName: "allowance",
    args: owner ? [owner, PERMIT2_ADDRESS] : undefined,
    query: { enabled: !!token && !!owner && !isNative },
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

// ─── Approve (to Permit2, one-time max approval) ──────────────────────────────────

export function useApprove() {
  const {
    writeContract,
    data: hash,
    isPending,
    error,
    reset,
  } = useWriteContract();

  const { isLoading: isReceiptLoading, isSuccess: isReceiptSuccess } =
    useWaitForTransactionReceipt({ hash });
  const { isConfirming, isSuccess } = useReceiptWithTimeout(hash, isReceiptLoading, isReceiptSuccess);

  const approve = (token: `0x${string}`, _spender: `0x${string}`, _amount: bigint) => {
    // Always approve to Permit2 with max approval (one-time, reusable)
    writeContract({
      address: token,
      abi: ERC20_ABI,
      functionName: "approve",
      args: [PERMIT2_ADDRESS, MAX_UINT256],
    });
  };

  return { approve, hash, isPending, isConfirming, isSuccess, error, reset };
}

// ─── Auto-Approve + Swap (unified flow) ──────────────────────────────────

export type AutoApprovePhase = "idle" | "approving" | "waitingApproval" | "swapping";

export function useSwapWithAutoApprove() {
  const [phase, setPhase] = useState<AutoApprovePhase>("idle");
  const [approveError, setApproveError] = useState<Error | null>(null);

  const { writeContractAsync } = useWriteContract();
  const publicClient = usePublicClient();

  const execute = async ({
    needsApproval,
    tokenAddress,
    swapFn,
    refetchAllowance,
  }: {
    needsApproval: boolean;
    tokenAddress: `0x${string}`;
    swapFn: () => void;
    refetchAllowance: () => void;
  }) => {
    setApproveError(null);

    try {
      if (needsApproval) {
        setPhase("approving");
        const hash = await writeContractAsync({
          address: tokenAddress,
          abi: ERC20_ABI,
          functionName: "approve",
          args: [PERMIT2_ADDRESS, MAX_UINT256],
        });

        setPhase("waitingApproval");
        await publicClient!.waitForTransactionReceipt({ hash });
        refetchAllowance();
      }

      setPhase("swapping");
      swapFn();
    } catch (err) {
      setApproveError(err as Error);
      setPhase("idle");
    }
  };

  const reset = () => {
    setPhase("idle");
    setApproveError(null);
  };

  return { execute, phase, approveError, reset };
}

// ─── Swap with Permit2 ──────────────────────────────────

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
  const publicClient = usePublicClient();
  const { address: account } = useAccount();

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

  const { isLoading: isReceiptLoading, isSuccess: isReceiptSuccess } =
    useWaitForTransactionReceipt({ hash });
  const { isConfirming, isSuccess } = useReceiptWithTimeout(hash, isReceiptLoading, isReceiptSuccess);

  const [pendingSwap, setPendingSwap] = useState<SwapConfig | null>(null);
  const [permitNonce, setPermitNonce] = useState<bigint>(0n);
  const [permitDeadline, setPermitDeadline] = useState<bigint>(0n);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);
  const [isDecodingError, setIsDecodingError] = useState(false);
  const lastCallRef = useRef<RawCallData | null>(null);

  // When writeContract fails, re-simulate via eth_call to get decoded revert reason
  useEffect(() => {
    if (writeError && lastCallRef.current && publicClient && account && contracts) {
      setIsDecodingError(true);
      resimulateForError(
        publicClient,
        contracts.BastionSwapRouter as `0x${string}`,
        account,
        lastCallRef.current,
      )
        .then((decoded) => { setErrorMessage(decoded || parseErrorMessage(writeError)); })
        .catch(() => { setErrorMessage(parseErrorMessage(writeError)); })
        .finally(() => { setIsDecodingError(false); });
    } else if (!writeError) {
      setErrorMessage(null);
      setIsDecodingError(false);
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [writeError]);

  // When signature is received, submit the swap with Permit2
  useEffect(() => {
    if (signature && pendingSwap && contracts) {
      const config = pendingSwap;
      const inputToken = config.zeroForOne ? config.currency0 : config.currency1;

      const permitSingle = {
        permit: {
          permitted: {
            token: inputToken,
            amount: config.amountIn,
          },
          nonce: permitNonce,
          deadline: permitDeadline,
        },
        signature,
      };

      const args = [
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
        permitSingle,
      ] as const;

      // Store encoded calldata for re-simulation (exact same call)
      lastCallRef.current = {
        data: encodeFunctionData({
          abi: BastionSwapRouterABI,
          functionName: "swapExactInputPermit2",
          args,
        }),
        value: 0n,
      };

      writeContract({
        address: contracts.BastionSwapRouter as `0x${string}`,
        abi: BastionSwapRouterABI,
        functionName: "swapExactInputPermit2",
        args,
        value: 0n,
      });
      setPendingSwap(null);
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [signature]);

  const swap = (config: SwapConfig) => {
    if (!contracts) return;
    setErrorMessage(null);

    const inputToken = config.zeroForOne ? config.currency0 : config.currency1;
    const isNativeInput = inputToken === "0x0000000000000000000000000000000000000000";
    const poolKey = {
      currency0: config.currency0,
      currency1: config.currency1,
      fee: config.fee,
      tickSpacing: config.tickSpacing,
      hooks: config.hooks,
    };
    const swapArgs = [poolKey, config.zeroForOne, config.amountIn, config.minAmountOut, config.deadline] as const;

    if (isNativeInput) {
      // Store encoded calldata for re-simulation
      lastCallRef.current = {
        data: encodeFunctionData({
          abi: BastionSwapRouterABI,
          functionName: "swapExactInput",
          args: swapArgs,
        }),
        value: config.value || 0n,
      };

      // Native ETH — use original swapExactInput directly (no permit needed)
      writeContract({
        address: contracts.BastionSwapRouter as `0x${string}`,
        abi: BastionSwapRouterABI,
        functionName: "swapExactInput",
        args: swapArgs,
        value: config.value || 0n,
      });
    } else {
      // ERC20 input — sign Permit2 first, then submit swap
      // lastCallRef will be updated in the Permit2 useEffect with the full calldata
      const nonce = generatePermit2Nonce();
      const deadline = config.deadline;
      const routerAddress = contracts.BastionSwapRouter as `0x${string}`;

      setPendingSwap(config);
      setPermitNonce(nonce);
      setPermitDeadline(deadline);

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
            token: inputToken,
            amount: config.amountIn,
          },
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
    setPendingSwap(null);
    setErrorMessage(null);
    setIsDecodingError(false);
    lastCallRef.current = null;
  };

  return {
    swap,
    hash,
    isWriting: isWriting || isSigning,
    isConfirming,
    isSuccess,
    error: signError || writeError,
    errorMessage: signError ? parseErrorMessage(signError) : errorMessage,
    isDecodingError,
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

  const { isLoading: isReceiptLoading, isSuccess: isReceiptSuccess } =
    useWaitForTransactionReceipt({ hash });
  const { isConfirming, isSuccess } = useReceiptWithTimeout(hash, isReceiptLoading, isReceiptSuccess);

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

// ─── Multi-Hop Swap ──────────────────────────────────

import type { SwapStep } from "@/hooks/useSwapRoute";

export interface MultiHopSwapConfig {
  steps: SwapStep[];
  amountIn: bigint;
  minAmountOut: bigint;
  deadline: bigint;
  inputToken: `0x${string}`;
  value?: bigint;
}

export function useExecuteMultiHopSwap() {
  const chainId = useChainId();
  const contracts = getContracts(chainId);
  const publicClient = usePublicClient();
  const { address: account } = useAccount();

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

  const { isLoading: isReceiptLoading, isSuccess: isReceiptSuccess } =
    useWaitForTransactionReceipt({ hash });
  const { isConfirming, isSuccess } = useReceiptWithTimeout(hash, isReceiptLoading, isReceiptSuccess);

  const [pendingSwap, setPendingSwap] = useState<MultiHopSwapConfig | null>(null);
  const [permitNonce, setPermitNonce] = useState<bigint>(0n);
  const [permitDeadline, setPermitDeadline] = useState<bigint>(0n);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);
  const [isDecodingError, setIsDecodingError] = useState(false);
  const lastCallRef = useRef<RawCallData | null>(null);

  // When writeContract fails, re-simulate via eth_call to get decoded revert reason
  useEffect(() => {
    if (writeError && lastCallRef.current && publicClient && account && contracts) {
      setIsDecodingError(true);
      resimulateForError(
        publicClient,
        contracts.BastionSwapRouter as `0x${string}`,
        account,
        lastCallRef.current,
      )
        .then((decoded) => { setErrorMessage(decoded || parseErrorMessage(writeError)); })
        .catch(() => { setErrorMessage(parseErrorMessage(writeError)); })
        .finally(() => { setIsDecodingError(false); });
    } else if (!writeError) {
      setErrorMessage(null);
      setIsDecodingError(false);
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [writeError]);

  // When signature is received, submit the multi-hop swap with Permit2
  useEffect(() => {
    if (signature && pendingSwap && contracts) {
      const config = pendingSwap;

      const permitSingle = {
        permit: {
          permitted: {
            token: config.inputToken,
            amount: config.amountIn,
          },
          nonce: permitNonce,
          deadline: permitDeadline,
        },
        signature,
      };

      const args = [
        config.steps,
        config.amountIn,
        config.minAmountOut,
        config.deadline,
        permitSingle,
      ] as const;

      // Store encoded calldata for re-simulation (exact same call)
      lastCallRef.current = {
        data: encodeFunctionData({
          abi: BastionSwapRouterABI,
          functionName: "swapMultiHopPermit2",
          args,
        }),
        value: 0n,
      };

      writeContract({
        address: contracts.BastionSwapRouter as `0x${string}`,
        abi: BastionSwapRouterABI,
        functionName: "swapMultiHopPermit2",
        args,
        value: 0n,
      });
      setPendingSwap(null);
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [signature]);

  const swap = (config: MultiHopSwapConfig) => {
    if (!contracts) return;
    setErrorMessage(null);

    const isNativeInput = config.inputToken === "0x0000000000000000000000000000000000000000";
    const swapArgs = [config.steps, config.amountIn, config.minAmountOut, config.deadline] as const;

    if (isNativeInput) {
      // Store encoded calldata for re-simulation
      lastCallRef.current = {
        data: encodeFunctionData({
          abi: BastionSwapRouterABI,
          functionName: "swapMultiHop",
          args: swapArgs,
        }),
        value: config.value || 0n,
      };

      writeContract({
        address: contracts.BastionSwapRouter as `0x${string}`,
        abi: BastionSwapRouterABI,
        functionName: "swapMultiHop",
        args: swapArgs,
        value: config.value || 0n,
      });
    } else {
      // lastCallRef will be updated in the Permit2 useEffect with the full calldata
      const nonce = generatePermit2Nonce();
      const deadline = config.deadline;
      const routerAddress = contracts.BastionSwapRouter as `0x${string}`;

      setPendingSwap(config);
      setPermitNonce(nonce);
      setPermitDeadline(deadline);

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
            token: config.inputToken,
            amount: config.amountIn,
          },
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
    setPendingSwap(null);
    setErrorMessage(null);
    setIsDecodingError(false);
    lastCallRef.current = null;
  };

  return {
    swap,
    hash,
    isWriting: isWriting || isSigning,
    isConfirming,
    isSuccess,
    error: signError || writeError,
    errorMessage: signError ? parseErrorMessage(signError) : errorMessage,
    isDecodingError,
    reset,
  };
}

// ─── Multi-Hop Quote (on-chain simulation) ──────────────────────────────────

export interface MultiHopQuoteParams {
  steps: SwapStep[];
  amountIn: bigint;
  inputToken: `0x${string}`;
}

export function useMultiHopQuote(params: MultiHopQuoteParams | null) {
  const chainId = useChainId();
  const contracts = getContracts(chainId);
  const publicClient = usePublicClient();

  return useQuery({
    queryKey: [
      "multiHopQuote",
      params?.steps?.length,
      params?.amountIn?.toString(),
      params?.inputToken,
      // Include step details for cache key
      params?.steps?.map(s => `${s.poolKey.currency0}-${s.poolKey.currency1}-${s.zeroForOne}`).join("|"),
    ],
    queryFn: async () => {
      if (!publicClient || !params || !contracts || params.amountIn <= 0n) return null;

      const routerAddr = contracts.BastionSwapRouter as `0x${string}`;

      const data = encodeFunctionData({
        abi: BastionSwapRouterABI,
        functionName: "swapMultiHop",
        args: [
          params.steps,
          params.amountIn,
          0n, // minAmountOut = 0 for quote
          BigInt(Math.floor(Date.now() / 1000) + 3600),
        ],
      });

      const isNativeInput = params.inputToken === "0x0000000000000000000000000000000000000000";
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
                  address: QUOTE_ACCOUNT,
                  balance: params.amountIn * 2n,
                },
              ]
            : [
                {
                  address: params.inputToken,
                  stateDiff: [
                    { slot: balSlot, value: MAX_UINT256_HEX },
                    { slot: allowSlot, value: MAX_UINT256_HEX },
                  ],
                },
              ],
        });

        if (!result.data) return null;

        return decodeFunctionResult({
          abi: BastionSwapRouterABI,
          functionName: "swapMultiHop",
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
const MAX_UINT256_HEX = "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" as `0x${string}`;

function computeStorageSlots(account: `0x${string}`, spender: `0x${string}`) {
  // Solmate ERC20 layout: balanceOf at slot 3, allowance at slot 4
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
      const routerAddr = contracts.BastionSwapRouter as `0x${string}`;

      // Quote uses the original swapExactInput (no permit needed for simulation)
      const data = encodeFunctionData({
        abi: BastionSwapRouterABI,
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
                  address: QUOTE_ACCOUNT,
                  balance: params.amountIn * 2n,
                },
              ]
            : [
                {
                  address: inputToken,
                  stateDiff: [
                    { slot: balSlot, value: MAX_UINT256_HEX },
                    { slot: allowSlot, value: MAX_UINT256_HEX },
                  ],
                },
              ],
        });

        if (!result.data) return null;

        return decodeFunctionResult({
          abi: BastionSwapRouterABI,
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
