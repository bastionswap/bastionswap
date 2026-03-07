import { BigDecimal, BigInt } from "@graphprotocol/graph-ts";
import { Issuer, PoolDayData, PoolHourData, ProtocolStats } from "../../generated/schema";

export let ZERO_BD = BigDecimal.fromString("0");
export let ZERO_BI = BigInt.fromI32(0);
let WAD = BigInt.fromI32(10).pow(18);
let Q96 = BigInt.fromI32(2).pow(96);

export function toDecimal(value: BigInt): BigDecimal {
  return value.toBigDecimal().div(WAD.toBigDecimal());
}

export function triggerTypeName(triggerType: i32): string {
  if (triggerType == 0) return "NONE";
  if (triggerType == 1) return "RUG_PULL";
  if (triggerType == 2) return "ISSUER_DUMP";
  if (triggerType == 3) return "HONEYPOT";
  if (triggerType == 4) return "HIDDEN_TAX";
  if (triggerType == 5) return "SLOW_RUG";
  if (triggerType == 6) return "COMMITMENT_BREACH";
  return "UNKNOWN";
}

export function getOrCreateProtocolStats(): ProtocolStats {
  let stats = ProtocolStats.load("global");
  if (stats == null) {
    stats = new ProtocolStats("global");
    stats.totalBastionPools = 0;
    stats.totalStandardPools = 0;
    stats.totalEscrowLocked = ZERO_BD;
    stats.totalInsuranceBalance = ZERO_BD;
    stats.totalTriggersActivated = 0;
    stats.totalCompensationPaid = ZERO_BD;
    stats.save();
  }
  return stats;
}

export function getOrCreateIssuer(address: string, timestamp: BigInt): Issuer {
  let issuer = Issuer.load(address);
  if (issuer == null) {
    issuer = new Issuer(address);
    issuer.reputationScore = BigInt.fromI32(100);
    issuer.totalEscrowsCreated = 0;
    issuer.totalEscrowsCompleted = 0;
    issuer.totalTriggersActivated = 0;
    issuer.lastUpdated = timestamp;
    issuer.save();
  }
  return issuer;
}

export function sqrtPriceX96ToPrice(sqrtPriceX96: BigInt): BigDecimal {
  let sqrtPriceBD = sqrtPriceX96.toBigDecimal();
  let q96BD = Q96.toBigDecimal();
  let ratio = sqrtPriceBD.div(q96BD);
  return ratio.times(ratio);
}

export function absBigInt(value: BigInt): BigInt {
  if (value.lt(ZERO_BI)) {
    return ZERO_BI.minus(value);
  }
  return value;
}

export function getOrCreatePoolHourData(
  poolId: string,
  timestamp: BigInt,
  price: BigDecimal
): PoolHourData {
  let hourStartUnix = timestamp.toI32() / 3600 * 3600;
  let id = poolId + "-" + hourStartUnix.toString();
  let data = PoolHourData.load(id);
  if (data == null) {
    data = new PoolHourData(id);
    data.pool = poolId;
    data.hourStartUnix = hourStartUnix;
    data.open = price;
    data.close = price;
    data.high = price;
    data.low = price;
    data.volumeToken0 = ZERO_BI;
    data.volumeToken1 = ZERO_BI;
    data.txCount = 0;
  }
  return data;
}

export function getOrCreatePoolDayData(
  poolId: string,
  timestamp: BigInt,
  price: BigDecimal
): PoolDayData {
  let dayStartUnix = timestamp.toI32() / 86400 * 86400;
  let id = poolId + "-" + dayStartUnix.toString();
  let data = PoolDayData.load(id);
  if (data == null) {
    data = new PoolDayData(id);
    data.pool = poolId;
    data.dayStartUnix = dayStartUnix;
    data.open = price;
    data.close = price;
    data.high = price;
    data.low = price;
    data.volumeToken0 = ZERO_BI;
    data.volumeToken1 = ZERO_BI;
    data.txCount = 0;
  }
  return data;
}
