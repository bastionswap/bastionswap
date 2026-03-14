import { BigInt } from "@graphprotocol/graph-ts";
import { SwapExecuted } from "../../generated/BastionSwapRouter/BastionSwapRouter";
import { Pool, Swap } from "../../generated/schema";
import {
  absBigInt,
  toDecimal,
  toDecimal6,
  getOrCreateProtocolStats,
} from "./helpers";

// Base Sepolia USDC — update for mainnet deployment
let USDC_ADDRESS = "0x036cbd53842c5426634e7929541ec2318f3dcf7e";

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

  // Accumulate base token volume
  let issuedHex = pool.issuedToken ? pool.issuedToken!.toHexString() : "";
  if (issuedHex == "") return;

  let token0Hex = pool.token0.toHexString();
  let baseAmount: BigInt;
  let baseHex: string;
  if (token0Hex == issuedHex) {
    baseAmount = absBigInt(event.params.amount1);
    baseHex = pool.token1.toHexString();
  } else {
    baseAmount = absBigInt(event.params.amount0);
    baseHex = token0Hex;
  }

  let stats = getOrCreateProtocolStats();
  if (baseHex == USDC_ADDRESS) {
    stats.totalVolumeUSDC = stats.totalVolumeUSDC.plus(toDecimal6(baseAmount));
  } else {
    stats.totalVolumeETH = stats.totalVolumeETH.plus(toDecimal(baseAmount));
  }
  stats.save();
}
