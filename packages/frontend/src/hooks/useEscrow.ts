import { useReadContract, useChainId } from "wagmi";
import { getContracts } from "@/config/contracts";
import { EscrowVaultABI } from "@/config/abis";

export function useEscrowStatus(escrowId: bigint | undefined) {
  const chainId = useChainId();
  const contracts = getContracts(chainId);

  return useReadContract({
    address: contracts?.EscrowVault as `0x${string}`,
    abi: EscrowVaultABI,
    functionName: "getEscrowStatus",
    args: escrowId !== undefined ? [escrowId] : undefined,
    query: { enabled: escrowId !== undefined },
  });
}

export function useVestingEndTime(poolId: `0x${string}` | undefined) {
  const chainId = useChainId();
  const contracts = getContracts(chainId);

  return useReadContract({
    address: contracts?.EscrowVault as `0x${string}`,
    abi: EscrowVaultABI,
    functionName: "getVestingEndTime",
    args: poolId ? [poolId] : undefined,
    query: { enabled: !!poolId },
  });
}

export function useVestingProgress(escrow: {
  totalLiquidity: string;
  removedLiquidity: string;
  remainingLiquidity: string;
} | null) {
  if (!escrow) return { progress: 0, remaining: "0", removed: "0" };
  const total = parseFloat(escrow.totalLiquidity);
  const removed = parseFloat(escrow.removedLiquidity);
  const progress = total > 0 ? (removed / total) * 100 : 0;
  return {
    progress: Math.min(progress, 100),
    remaining: escrow.remainingLiquidity,
    removed: escrow.removedLiquidity,
  };
}
