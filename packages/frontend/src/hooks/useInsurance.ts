import { useReadContract } from "wagmi";
import { baseSepolia } from "wagmi/chains";
import { getContracts } from "@/config/contracts";
import { InsurancePoolABI } from "@/config/abis";

const contracts = getContracts(baseSepolia.id);

export function useEstimatedCompensation(
  poolId: `0x${string}` | undefined,
  holder: `0x${string}` | undefined
) {
  return useReadContract({
    address: contracts?.InsurancePool as `0x${string}`,
    abi: InsurancePoolABI,
    functionName: "calculateCompensation",
    args: poolId && holder ? [poolId, holder] : undefined,
    query: { enabled: !!poolId && !!holder },
  });
}
