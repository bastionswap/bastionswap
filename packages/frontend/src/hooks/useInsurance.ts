import { useReadContract } from "wagmi";
import { baseSepolia } from "wagmi/chains";
import { getContracts } from "@/config/contracts";
import { InsurancePoolABI } from "@/config/abis";

const contracts = getContracts(baseSepolia.id);

/**
 * Calculate estimated compensation for a holder based on their token balance.
 * Contract signature: calculateCompensation(PoolId poolId, uint256 holderBalance)
 * Formula: (payoutBalance * holderBalance) / totalEligibleSupply
 */
export function useEstimatedCompensation(
  poolId: `0x${string}` | undefined,
  holderBalance: bigint | undefined
) {
  return useReadContract({
    address: contracts?.InsurancePool as `0x${string}`,
    abi: InsurancePoolABI,
    functionName: "calculateCompensation",
    args: poolId && holderBalance !== undefined ? [poolId, holderBalance] : undefined,
    query: { enabled: !!poolId && holderBalance !== undefined && holderBalance > 0n },
  });
}
