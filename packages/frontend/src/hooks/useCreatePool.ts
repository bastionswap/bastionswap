import { useWriteContract, useWaitForTransactionReceipt } from "wagmi";

export function useCreateBastionPool() {
  const {
    writeContract,
    data: hash,
    isPending: isWriting,
    error: writeError,
  } = useWriteContract();

  const { isLoading: isConfirming, isSuccess } =
    useWaitForTransactionReceipt({ hash });

  return {
    createPool: writeContract,
    hash,
    isWriting,
    isConfirming,
    isSuccess,
    error: writeError,
  };
}
