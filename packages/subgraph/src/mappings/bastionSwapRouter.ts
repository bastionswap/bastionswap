import { SwapExecuted } from "../../generated/BastionSwapRouter/BastionSwapRouter";
import { Pool, Swap } from "../../generated/schema";

export function handleSwapExecuted(event: SwapExecuted): void {
  let poolId = event.params.poolId.toHexString();
  let pool = Pool.load(poolId);
  if (pool == null) return;

  let swapId =
    event.transaction.hash.toHexString() +
    "-" +
    event.logIndex.toString();

  let swap = new Swap(swapId);
  swap.pool = poolId;
  swap.sender = event.params.sender;
  swap.amount0 = event.params.amount0;
  swap.amount1 = event.params.amount1;
  swap.sqrtPriceX96 = event.params.sqrtPriceX96;
  swap.tick = event.params.tick;
  swap.timestamp = event.block.timestamp;
  swap.blockNumber = event.block.number;
  swap.transaction = event.transaction.hash;
  swap.save();
}
