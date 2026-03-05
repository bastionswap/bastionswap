import { useReadContract } from "wagmi";
import { baseSepolia } from "wagmi/chains";
import { getContracts } from "@/config/contracts";
import { BastionHookABI } from "@/config/abis";

const contracts = getContracts(baseSepolia.id);

export function usePoolInfo(poolId: `0x${string}` | undefined) {
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
