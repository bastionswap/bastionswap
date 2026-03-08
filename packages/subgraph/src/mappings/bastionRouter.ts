import { BigInt } from "@graphprotocol/graph-ts";
import { LiquidityChanged } from "../../generated/BastionPositionRouter/BastionPositionRouter";
import { LiquidityEvent, Position } from "../../generated/schema";
import { ZERO_BI } from "./helpers";

// Full-range ticks for tickSpacing=60: (MIN_TICK / 60) * 60 and (MAX_TICK / 60) * 60
let FULL_RANGE_LOWER = -887220;
let FULL_RANGE_UPPER = 887220;

export function handleLiquidityChanged(event: LiquidityChanged): void {
  let poolId = event.params.poolId.toHexString();
  let user = event.params.user.toHexString();
  let tickLower = event.params.tickLower;
  let tickUpper = event.params.tickUpper;

  let id =
    poolId +
    "-" +
    user +
    "-" +
    tickLower.toString() +
    "-" +
    tickUpper.toString();

  let position = Position.load(id);

  if (position == null) {
    position = new Position(id);
    position.pool = poolId;
    position.owner = event.params.user;
    position.tickLower = tickLower;
    position.tickUpper = tickUpper;
    position.liquidity = BigInt.fromI32(0);
    position.isFullRange =
      tickLower == FULL_RANGE_LOWER && tickUpper == FULL_RANGE_UPPER;
    position.createdAt = event.block.timestamp;
  }

  position.liquidity = position.liquidity.plus(event.params.liquidityDelta);
  position.lastUpdatedAt = event.block.timestamp;
  position.save();

  // Create LiquidityEvent entity
  let eventId = event.transaction.hash.toHexString() + "-" + event.logIndex.toString();
  let liqEvent = new LiquidityEvent(eventId);
  liqEvent.pool = poolId;
  liqEvent.sender = event.params.user;
  liqEvent.type = event.params.liquidityDelta.gt(ZERO_BI) ? "ADD" : "REMOVE";
  liqEvent.amount0 = event.params.amount0;
  liqEvent.amount1 = event.params.amount1;
  liqEvent.liquidity = event.params.liquidityDelta;
  liqEvent.tickLower = tickLower;
  liqEvent.tickUpper = tickUpper;
  liqEvent.timestamp = event.block.timestamp;
  liqEvent.blockNumber = event.block.number;
  liqEvent.transaction = event.transaction.hash;
  liqEvent.save();
}
