import { BigDecimal, BigInt } from "@graphprotocol/graph-ts";
import {
  EscrowCreated,
  LiquidityAdded,
  LPRemovalRecorded,
  ForceRemoval,
  ForceRemovalFailed,
  CommitmentSet,
} from "../../generated/EscrowVault/EscrowVault";
import {
  Escrow,
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
  escrow.totalLiquidity = toDecimal(event.params.liquidity);
  escrow.removedLiquidity = ZERO_BD;
  escrow.remainingLiquidity = toDecimal(event.params.liquidity);
  escrow.lockDuration = BigInt.fromI32(event.params.lockDuration);
  escrow.vestingDuration = BigInt.fromI32(event.params.vestingDuration);
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
    toDecimal(event.params.liquidity)
  );
  stats.save();
}

export function handleLiquidityAdded(event: LiquidityAdded): void {
  let escrowId = event.params.escrowId.toHexString();
  let escrow = Escrow.load(escrowId);
  if (escrow != null) {
    let newTotal = toDecimal(event.params.newTotal);
    escrow.totalLiquidity = newTotal;
    escrow.remainingLiquidity = newTotal.minus(escrow.removedLiquidity);
    escrow.save();

    // Update protocol stats
    let addedAmount = toDecimal(event.params.liquidityAdded);
    let stats = getOrCreateProtocolStats();
    stats.totalEscrowLocked = stats.totalEscrowLocked.plus(addedAmount);
    stats.save();
  }
}

export function handleLPRemovalRecorded(event: LPRemovalRecorded): void {
  let escrowId = event.params.escrowId.toHexString();
  let escrow = Escrow.load(escrowId);
  if (escrow != null) {
    let removedAmount = toDecimal(event.params.liquidityRemoved);
    escrow.removedLiquidity = escrow.removedLiquidity.plus(removedAmount);
    escrow.remainingLiquidity = escrow.totalLiquidity.minus(escrow.removedLiquidity);
    escrow.save();
  }
}

export function handleForceRemoval(event: ForceRemoval): void {
  let escrowId = event.params.escrowId.toHexString();
  let escrow = Escrow.load(escrowId);
  if (escrow != null) {
    escrow.isTriggered = true;
    let liquidityRemoved = toDecimal(event.params.liquidityRemoved);
    escrow.removedLiquidity = escrow.totalLiquidity;
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

export function handleForceRemovalFailed(event: ForceRemovalFailed): void {
  let escrowId = event.params.escrowId.toHexString();
  let escrow = Escrow.load(escrowId);
  if (escrow != null) {
    // Escrow is still marked as triggered even if force removal failed
    escrow.isTriggered = true;
    escrow.removedLiquidity = escrow.totalLiquidity;
    escrow.remainingLiquidity = ZERO_BD;
    escrow.save();
  }
}

export function handleCommitmentSet(event: CommitmentSet): void {
  let escrowId = event.params.escrowId.toHexString();

  let commitment = new Commitment(escrowId);
  commitment.escrow = escrowId;
  commitment.dailyWithdrawLimit = BigInt.fromI32(
    event.params.newCommitment.dailyWithdrawLimit
  );
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
