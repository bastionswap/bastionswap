import { useReadContract, useChainId } from "wagmi";
import { getContracts } from "@/config/contracts";
import { InsurancePoolABI } from "@/config/abis";

/**
 * Calculate estimated compensation for a holder based on their token balance.
 * Contract signature: calculateCompensation(PoolId poolId, uint256 holderBalance)
 * Formula: (payoutBalance * holderBalance) / totalEligibleSupply
 */
export function useEstimatedCompensation(
  poolId: `0x${string}` | undefined,
  holderBalance: bigint | undefined
) {
  const chainId = useChainId();
  const contracts = getContracts(chainId);

  return useReadContract({
    address: contracts?.InsurancePool as `0x${string}`,
    abi: InsurancePoolABI,
    functionName: "calculateCompensation",
    args: poolId && holderBalance !== undefined ? [poolId, holderBalance] : undefined,
    query: { enabled: !!poolId && holderBalance !== undefined && holderBalance > 0n },
  });
}
