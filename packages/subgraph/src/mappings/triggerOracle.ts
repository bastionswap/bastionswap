import { BigDecimal } from "@graphprotocol/graph-ts";
import {
  TriggerPending,
  TriggerExecuted,
  MerkleRootSubmitted,
} from "../../generated/TriggerOracle/TriggerOracle";
import {
  TriggerEvent,
  InsurancePool as InsurancePoolEntity,
} from "../../generated/schema";
import { triggerTypeName, getOrCreateProtocolStats } from "./helpers";

export function handleTriggerPending(event: TriggerPending): void {
  let poolId = event.params.poolId.toHexString();
  let triggerType = event.params.triggerType;
  let id =
    poolId +
    "-" +
    triggerType.toString() +
    "-" +
    event.block.timestamp.toString();

  let trigger = new TriggerEvent(id);
  trigger.pool = poolId;
  trigger.triggerType = triggerType;
  trigger.triggerTypeName = triggerTypeName(triggerType);
  trigger.timestamp = event.block.timestamp;
  trigger.transactionHash = event.transaction.hash;
  trigger.withMerkleRoot = false;
  trigger.save();
}

export function handleTriggerExecuted(event: TriggerExecuted): void {
  let poolId = event.params.poolId.toHexString();
  let triggerType = event.params.triggerType;

  // Try to find the most recent pending trigger event for this pool+type
  // Since we can't query, create a new event record for execution
  let id =
    poolId +
    "-" +
    triggerType.toString() +
    "-" +
    event.block.timestamp.toString();

  let trigger = new TriggerEvent(id);
  trigger.pool = poolId;
  trigger.triggerType = triggerType;
  trigger.triggerTypeName = triggerTypeName(triggerType);
  trigger.timestamp = event.block.timestamp;
  trigger.transactionHash = event.transaction.hash;
  trigger.withMerkleRoot = event.params.withMerkleRoot;
  trigger.save();

  // Update protocol stats
  let stats = getOrCreateProtocolStats();
  stats.totalTriggersActivated = stats.totalTriggersActivated + 1;
  stats.save();
}

export function handleMerkleRootSubmitted(event: MerkleRootSubmitted): void {
  let poolId = event.params.poolId.toHexString();
  let insurance = InsurancePoolEntity.load(poolId);
  if (insurance != null) {
    insurance.merkleRoot = event.params.merkleRoot;
    insurance.useMerkleProof = true;
    insurance.save();
  }
}
