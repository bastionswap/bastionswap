import { BigInt } from "@graphprotocol/graph-ts";
import { LiquidityChanged } from "../../generated/BastionRouter/BastionRouter";
import { Position } from "../../generated/schema";

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
}
