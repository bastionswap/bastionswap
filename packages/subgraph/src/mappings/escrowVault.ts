import { BigDecimal, BigInt } from "@graphprotocol/graph-ts";
import {
  EscrowCreated,
  LPRemovalRecorded,
  Lockdown,
  CommitmentSet,
} from "../../generated/EscrowVault/EscrowVault";
import {
  Escrow,
  VestingMilestone,
  Commitment,
  Pool,
} from "../../generated/schema";
import {
  toDecimal,
  getOrCreateProtocolStats,
  getOrCreateIssuer,
} from "./helpers";

let ZERO_BD = BigDecimal.fromString("0");

export function handleEscrowVaultCreated(event: EscrowCreated): void {
  let escrowId = event.params.escrowId.toHexString();
  let poolId = event.params.poolId.toHexString();

  let escrow = new Escrow(escrowId);
  escrow.pool = poolId;
  escrow.issuer = event.params.issuer;
  escrow.totalLiquidity = toDecimal(BigInt.fromI64(event.params.liquidity));
  escrow.removedLiquidity = ZERO_BD;
  escrow.remainingLiquidity = toDecimal(BigInt.fromI64(event.params.liquidity));
  escrow.isTriggered = false;
  escrow.createdAt = event.block.timestamp;
  escrow.save();

  // Link escrow to pool
  let pool = Pool.load(poolId);
  if (pool != null) {
    pool.escrow = escrowId;
    pool.save();
  }

  // Update issuer stats
  let issuer = getOrCreateIssuer(
    event.params.issuer.toHexString(),
    event.block.timestamp
  );
  issuer.totalEscrowsCreated = issuer.totalEscrowsCreated + 1;
  issuer.lastUpdated = event.block.timestamp;
  issuer.save();

  // Update protocol stats
  let stats = getOrCreateProtocolStats();
  stats.totalEscrowLocked = stats.totalEscrowLocked.plus(
    toDecimal(BigInt.fromI64(event.params.liquidity))
  );
  stats.save();
}

export function handleLPRemovalRecorded(event: LPRemovalRecorded): void {
  let escrowId = event.params.escrowId.toHexString();
  let escrow = Escrow.load(escrowId);
  if (escrow != null) {
    let removedAmount = toDecimal(BigInt.fromI64(event.params.liquidityRemoved));
    escrow.removedLiquidity = escrow.removedLiquidity.plus(removedAmount);
    escrow.remainingLiquidity = escrow.totalLiquidity.minus(escrow.removedLiquidity);
    escrow.save();
  }
}

export function handleLockdown(event: Lockdown): void {
  let escrowId = event.params.escrowId.toHexString();
  let escrow = Escrow.load(escrowId);
  if (escrow != null) {
    escrow.isTriggered = true;
    escrow.remainingLiquidity = ZERO_BD;
    escrow.save();

    // Update issuer stats
    let issuer = getOrCreateIssuer(
      escrow.issuer.toHexString(),
      event.block.timestamp
    );
    issuer.totalTriggersActivated = issuer.totalTriggersActivated + 1;
    issuer.lastUpdated = event.block.timestamp;
    issuer.save();
  }
}

export function handleCommitmentSet(event: CommitmentSet): void {
  let escrowId = event.params.escrowId.toHexString();

  let commitment = new Commitment(escrowId);
  commitment.escrow = escrowId;
  commitment.dailyWithdrawLimit = BigInt.fromI32(
    event.params.newCommitment.dailyWithdrawLimit
  );
  commitment.lockDuration = event.params.newCommitment.lockDuration;
  commitment.maxSellPercent = BigInt.fromI32(
    event.params.newCommitment.maxSellPercent
  );
  commitment.save();

  let escrow = Escrow.load(escrowId);
  if (escrow != null) {
    escrow.commitment = escrowId;
    escrow.save();
  }
}
