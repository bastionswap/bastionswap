import { useReadContract, useChainId } from "wagmi";
import { getContracts } from "@/config/contracts";
import { BastionHookABI } from "@/config/abis";

export function usePoolInfo(poolId: `0x${string}` | undefined) {
  const chainId = useChainId();
  const contracts = getContracts(chainId);

  const { data } = useReadContract({
    address: contracts?.BastionHook as `0x${string}`,
    abi: BastionHookABI,
    functionName: "getPoolInfo",
    args: poolId ? [poolId] : undefined,
    query: { enabled: !!poolId },
  });

  const result = data as [string, bigint, string, bigint] | undefined;

  return {
    issuer: result?.[0] as `0x${string}` | undefined,
    escrowId: result?.[1],
    issuedToken: result?.[2] as `0x${string}` | undefined,
    totalLiquidity: result?.[3],
  };
}
