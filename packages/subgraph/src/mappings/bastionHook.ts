import { BigDecimal } from "@graphprotocol/graph-ts";
import {
  IssuerRegistered,
  EscrowCreated,
  InsuranceFeeDeposited,
  IssuerSaleReported,
  LPRemovalReported,
  ExternalCallFailed,
} from "../../generated/BastionHook/BastionHook";
import { Pool, InsurancePool as InsurancePoolEntity } from "../../generated/schema";
import {
  toDecimal,
  getOrCreateProtocolStats,
  getOrCreateIssuer,
} from "./helpers";

let ZERO_BD = BigDecimal.fromString("0");

export function handleIssuerRegistered(event: IssuerRegistered): void {
  let poolId = event.params.poolId.toHexString();
  let pool = Pool.load(poolId);
  if (pool == null) {
    // Initialize event hasn't fired yet — create new entity
    pool = new Pool(poolId);
    pool.token0 = event.params.issuedToken; // placeholder — updated by Initialize
    pool.token1 = event.params.issuedToken; // placeholder — updated by Initialize
    pool.createdAt = event.block.timestamp;
    pool.createdTx = event.transaction.hash;
  }

  pool.hook = event.address;
  pool.isBastion = true;
  pool.issuedToken = event.params.issuedToken;

  let issuer = getOrCreateIssuer(
    event.params.issuer.toHexString(),
    event.block.timestamp
  );
  pool.issuer = issuer.id;
  pool.save();

  // Create insurance pool entity
  let insurance = new InsurancePoolEntity(poolId);
  insurance.pool = poolId;
  insurance.balance = ZERO_BD;
  insurance.escrowEthBalance = ZERO_BD;
  insurance.escrowTokenBalance = ZERO_BD;
  insurance.isTriggered = false;
  insurance.useMerkleProof = false;
  insurance.totalClaimed = ZERO_BD;
  insurance.feeRate = 100; // default 1% (100 bps)
  insurance.holderCount = 0;
  insurance.save();

  pool.insurancePool = insurance.id;
  pool.save();

  // Update protocol stats
  let stats = getOrCreateProtocolStats();
  stats.totalBastionPools = stats.totalBastionPools + 1;
  stats.save();
}

export function handleEscrowCreated(event: EscrowCreated): void {
  let poolId = event.params.poolId.toHexString();
  let pool = Pool.load(poolId);
  if (pool != null) {
    pool.escrow = event.params.escrowId.toHexString();
    pool.save();
  }
}

export function handleInsuranceFeeDeposited(
  event: InsuranceFeeDeposited
): void {
  let poolId = event.params.poolId.toHexString();
  let insurance = InsurancePoolEntity.load(poolId);
  if (insurance != null) {
    let amount = toDecimal(event.params.amount);
    insurance.balance = insurance.balance.plus(amount);
    insurance.save();

    let stats = getOrCreateProtocolStats();
    stats.totalInsuranceBalance = stats.totalInsuranceBalance.plus(amount);
    stats.save();
  }
}

export function handleIssuerSaleReported(event: IssuerSaleReported): void {
  // Logged for frontend notifications — no entity updates needed
}

export function handleLPRemovalReported(event: LPRemovalReported): void {
  // Logged for monitoring — no entity updates needed
}

export function handleExternalCallFailed(event: ExternalCallFailed): void {
  // Logged for monitoring — no entity updates needed
}
