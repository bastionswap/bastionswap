import { BigDecimal, BigInt } from "@graphprotocol/graph-ts";
import { Issuer, ProtocolStats } from "../../generated/schema";

let ZERO_BD = BigDecimal.fromString("0");
let ZERO_BI = BigInt.fromI32(0);
let WAD = BigInt.fromI32(10).pow(18);

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
