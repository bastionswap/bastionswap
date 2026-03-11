import { BigDecimal } from "@graphprotocol/graph-ts";
import {
  FeeDeposited,
  PayoutExecuted,
  CompensationClaimed,
  FeeRateUpdated,
  EscrowFundsReceived,
  MerkleRootSubmitted,
} from "../../generated/InsurancePool/InsurancePool";
import {
  InsurancePool as InsurancePoolEntity,
  Claim,
} from "../../generated/schema";
import { toDecimal, getOrCreateProtocolStats } from "./helpers";

export function handleFeeDeposited(event: FeeDeposited): void {
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

export function handlePayoutExecuted(event: PayoutExecuted): void {
  let poolId = event.params.poolId.toHexString();
  let insurance = InsurancePoolEntity.load(poolId);
  if (insurance != null) {
    insurance.isTriggered = true;
    insurance.triggerType = event.params.triggerType;
    insurance.save();

    let stats = getOrCreateProtocolStats();
    stats.totalTriggersActivated = stats.totalTriggersActivated + 1;
    stats.save();
  }
}

export function handleCompensationClaimed(event: CompensationClaimed): void {
  let poolId = event.params.poolId.toHexString();
  let holder = event.params.holder.toHexString();
  let claimId = poolId + "-" + holder;

  let claim = new Claim(claimId);
  claim.pool = poolId;
  claim.holder = event.params.holder;
  claim.amount = toDecimal(event.params.amount);
  claim.claimedAt = event.block.timestamp;
  claim.transactionHash = event.transaction.hash;
  claim.save();

  // Update insurance pool totals
  let insurance = InsurancePoolEntity.load(poolId);
  if (insurance != null) {
    insurance.totalClaimed = insurance.totalClaimed.plus(
      toDecimal(event.params.amount)
    );
    insurance.save();
  }

  // Update protocol stats
  let stats = getOrCreateProtocolStats();
  stats.totalCompensationPaid = stats.totalCompensationPaid.plus(
    toDecimal(event.params.amount)
  );
  stats.save();
}

export function handleEscrowFundsReceived(event: EscrowFundsReceived): void {
  let poolId = event.params.poolId.toHexString();
  let insurance = InsurancePoolEntity.load(poolId);
  if (insurance != null) {
    let ethAmount = toDecimal(event.params.ethAmount);
    let tokenAmount = toDecimal(event.params.tokenAmount);
    insurance.escrowEthBalance = insurance.escrowEthBalance.plus(ethAmount);
    insurance.escrowTokenBalance = insurance.escrowTokenBalance.plus(tokenAmount);
    insurance.save();
  }
}

export function handleFeeRateUpdated(event: FeeRateUpdated): void {
  // FeeRate is global — update all future pools' default
  // For now, this is a global event with no poolId; log only
}

export function handleMerkleRootSubmitted(event: MerkleRootSubmitted): void {
  let poolId = event.params.poolId.toHexString();
  let insurance = InsurancePoolEntity.load(poolId);
  if (insurance != null) {
    insurance.merkleRoot = event.params.root;
    insurance.useMerkleProof = true;
    insurance.save();
  }
}
