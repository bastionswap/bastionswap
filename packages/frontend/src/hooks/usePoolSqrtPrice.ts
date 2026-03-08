import { useChainId } from "wagmi";
import { useReadContract } from "wagmi";
import { keccak256, encodeAbiParameters } from "viem";
import { getContracts } from "@/config/contracts";
import { PoolManagerABI } from "@/config/abis";

const POOLS_SLOT = 6n;

function computePoolSlots(poolId: `0x${string}`) {
  const base = BigInt(
    keccak256(
      encodeAbiParameters(
        [{ type: "bytes32" }, { type: "uint256" }],
        [poolId, POOLS_SLOT]
      )
    )
  );
  return {
    slot0: ("0x" + base.toString(16).padStart(64, "0")) as `0x${string}`,
  };
}

export function usePoolSqrtPrice(poolId: string | undefined) {
  const chainId = useChainId();
  const contracts = getContracts(chainId);
  const slots = poolId ? computePoolSlots(poolId as `0x${string}`) : null;

  const { data: slot0Raw } = useReadContract({
    address: contracts?.PoolManager as `0x${string}`,
    abi: PoolManagerABI,
    functionName: "extsload",
    args: slots ? [slots.slot0] : undefined,
    query: { enabled: !!slots && !!contracts, refetchInterval: 15_000 },
  });

  const sqrtPriceX96 = slot0Raw
    ? BigInt(slot0Raw as string) & ((1n << 160n) - 1n)
    : undefined;

  return { sqrtPriceX96 };
}
