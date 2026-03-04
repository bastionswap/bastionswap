import { useWriteContract, useWaitForTransactionReceipt } from "wagmi";
import { parseUnits } from "viem";

export function useExecuteSwap() {
  const {
    writeContract,
    data: hash,
    isPending: isWriting,
    error: writeError,
  } = useWriteContract();

  const { isLoading: isConfirming, isSuccess } =
    useWaitForTransactionReceipt({ hash });

  return {
    swap: writeContract,
    hash,
    isWriting,
    isConfirming,
    isSuccess,
    error: writeError,
  };
}

export function useSwapQuote(
  _tokenIn: string | undefined,
  _tokenOut: string | undefined,
  _amountIn: string
) {
  // In production, this would call a quoter contract or compute off-chain
  // For now, return a placeholder
  const amountIn = _amountIn || "0";
  const parsedAmount = amountIn && parseFloat(amountIn) > 0 ? amountIn : "0";

  return {
    data: parsedAmount !== "0" ? parsedAmount : undefined,
    isLoading: false,
    error: null,
  };
}
