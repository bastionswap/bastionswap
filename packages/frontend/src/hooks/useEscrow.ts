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
  totalLocked: string;
  released: string;
  remaining: string;
} | null) {
  if (!escrow) return { progress: 0, remaining: "0", released: "0" };
  const total = parseFloat(escrow.totalLocked);
  const released = parseFloat(escrow.released);
  const progress = total > 0 ? (released / total) * 100 : 0;
  return {
    progress: Math.min(progress, 100),
    remaining: escrow.remaining,
    released: escrow.released,
  };
}
