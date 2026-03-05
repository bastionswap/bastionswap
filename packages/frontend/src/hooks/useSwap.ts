import { useWriteContract, useWaitForTransactionReceipt } from "wagmi";
import { baseSepolia } from "wagmi/chains";
import { parseUnits } from "viem";
import { getContracts } from "@/config/contracts";
import { BastionRouterABI } from "@/config/abis";

const contracts = getContracts(baseSepolia.id);

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
  value?: bigint; // ETH to send if selling native ETH
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

export function useSwapQuote(
  _tokenIn: string | undefined,
  _tokenOut: string | undefined,
  _amountIn: string
) {
  // Placeholder — in production this would simulate via eth_call or use a quoter
  const amountIn = _amountIn || "0";
  const parsedAmount = amountIn && parseFloat(amountIn) > 0 ? amountIn : "0";

  return {
    data: parsedAmount !== "0" ? parsedAmount : undefined,
    isLoading: false,
    error: null,
  };
}
