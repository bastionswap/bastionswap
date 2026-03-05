import { BigDecimal } from "@graphprotocol/graph-ts";
import { Initialize } from "../../generated/PoolManager/PoolManager";
import { Pool } from "../../generated/schema";

export function handleInitialize(event: Initialize): void {
  let poolId = event.params.id.toHexString();
  let pool = Pool.load(poolId);
  if (pool == null) {
    // Pool entity may not exist yet if Initialize fires before IssuerRegistered.
    // Create a skeleton — IssuerRegistered handler will fill in the rest.
    pool = new Pool(poolId);
    pool.token0 = event.params.currency0;
    pool.token1 = event.params.currency1;
    pool.hook = event.params.hooks;
    pool.fee = event.params.fee;
    pool.tickSpacing = event.params.tickSpacing;
    pool.isBastion = false; // will be set true by IssuerRegistered
    pool.createdAt = event.block.timestamp;
    pool.createdTx = event.transaction.hash;
    pool.totalLiquidity = BigDecimal.fromString("0");
    pool.save();
  } else {
    pool.token0 = event.params.currency0;
    pool.token1 = event.params.currency1;
    pool.fee = event.params.fee;
    pool.tickSpacing = event.params.tickSpacing;
    pool.save();
  }
}
