import { BigDecimal, BigInt } from "@graphprotocol/graph-ts";
import {
  Initialize,
  Swap as SwapEvent,
  ModifyLiquidity,
} from "../../generated/PoolManager/PoolManager";
import { Pool } from "../../generated/schema";
import {
  ZERO_BD,
  ZERO_BI,
  sqrtPriceX96ToPrice,
  absBigInt,
  getOrCreatePoolHourData,
  getOrCreatePoolDayData,
} from "./helpers";

let Q96 = BigInt.fromI32(2).pow(96);

function calculateReserves(
  sqrtPriceX96: BigInt,
  liquidity: BigInt
): BigDecimal[] {
  if (sqrtPriceX96.equals(ZERO_BI) || liquidity.equals(ZERO_BI)) {
    return [ZERO_BD, ZERO_BD];
  }

  // reserve0 = liquidity * 2^96 / sqrtPriceX96
  // reserve1 = liquidity * sqrtPriceX96 / 2^96
  // Use BigDecimal to avoid overflow and get decimal results
  let liqBD = liquidity.toBigDecimal();
  let sqrtPriceBD = sqrtPriceX96.toBigDecimal();
  let q96BD = Q96.toBigDecimal();

  let reserve0 = liqBD.times(q96BD).div(sqrtPriceBD);
  let reserve1 = liqBD.times(sqrtPriceBD).div(q96BD);

  return [reserve0, reserve1];
}

export function handleInitialize(event: Initialize): void {
  let poolId = event.params.id.toHexString();
  let pool = Pool.load(poolId);
  if (pool == null) {
    pool = new Pool(poolId);
    pool.token0 = event.params.currency0;
    pool.token1 = event.params.currency1;
    pool.hook = event.params.hooks;
    pool.fee = event.params.fee;
    pool.tickSpacing = event.params.tickSpacing;
    pool.isBastion = false;
    pool.createdAt = event.block.timestamp;
    pool.createdTx = event.transaction.hash;
  } else {
    pool.token0 = event.params.currency0;
    pool.token1 = event.params.currency1;
    pool.fee = event.params.fee;
    pool.tickSpacing = event.params.tickSpacing;
  }

  pool.sqrtPriceX96 = event.params.sqrtPriceX96;
  pool.liquidity = ZERO_BI;
  pool.reserve0 = ZERO_BD;
  pool.reserve1 = ZERO_BD;
  pool.save();
}

export function handleSwap(event: SwapEvent): void {
  let poolId = event.params.id.toHexString();
  let pool = Pool.load(poolId);
  if (pool == null) return;

  pool.sqrtPriceX96 = event.params.sqrtPriceX96;
  pool.liquidity = event.params.liquidity;

  let reserves = calculateReserves(event.params.sqrtPriceX96, event.params.liquidity);
  pool.reserve0 = reserves[0];
  pool.reserve1 = reserves[1];
  pool.save();

  // Update OHLCV data
  let price = sqrtPriceX96ToPrice(event.params.sqrtPriceX96);
  let absAmount0 = absBigInt(event.params.amount0);
  let absAmount1 = absBigInt(event.params.amount1);

  let hourData = getOrCreatePoolHourData(poolId, event.block.timestamp, price);
  hourData.close = price;
  if (price.gt(hourData.high)) hourData.high = price;
  if (price.lt(hourData.low)) hourData.low = price;
  hourData.volumeToken0 = hourData.volumeToken0.plus(absAmount0);
  hourData.volumeToken1 = hourData.volumeToken1.plus(absAmount1);
  hourData.txCount = hourData.txCount + 1;
  hourData.save();

  let dayData = getOrCreatePoolDayData(poolId, event.block.timestamp, price);
  dayData.close = price;
  if (price.gt(dayData.high)) dayData.high = price;
  if (price.lt(dayData.low)) dayData.low = price;
  dayData.volumeToken0 = dayData.volumeToken0.plus(absAmount0);
  dayData.volumeToken1 = dayData.volumeToken1.plus(absAmount1);
  dayData.txCount = dayData.txCount + 1;
  dayData.save();
}

export function handleModifyLiquidity(event: ModifyLiquidity): void {
  let poolId = event.params.id.toHexString();
  let pool = Pool.load(poolId);
  if (pool == null) return;

  // ModifyLiquidity provides a delta; accumulate it onto stored liquidity
  let currentLiquidity = pool.liquidity ? pool.liquidity! : ZERO_BI;
  let delta = event.params.liquidityDelta;
  let newLiquidity = currentLiquidity.plus(delta);
  if (newLiquidity.lt(ZERO_BI)) {
    newLiquidity = ZERO_BI;
  }
  pool.liquidity = newLiquidity;

  let sqrtPrice = pool.sqrtPriceX96 ? pool.sqrtPriceX96! : ZERO_BI;
  let reserves = calculateReserves(sqrtPrice, newLiquidity);
  pool.reserve0 = reserves[0];
  pool.reserve1 = reserves[1];
  pool.save();
}
