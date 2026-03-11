import {
  TriggerDetected,
  TriggerExecuted,
} from "../../generated/TriggerOracle/TriggerOracle";
import { TriggerEvent } from "../../generated/schema";
import { triggerTypeName, getOrCreateProtocolStats } from "./helpers";

export function handleTriggerDetected(event: TriggerDetected): void {
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
  trigger.escrowForceRemoved = false;
  trigger.withMerkleRoot = false;
  trigger.save();
}

export function handleTriggerExecuted(event: TriggerExecuted): void {
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
  trigger.escrowForceRemoved = true;
  trigger.withMerkleRoot = event.params.withMerkleRoot;
  trigger.save();

  // Update protocol stats
  let stats = getOrCreateProtocolStats();
  stats.totalTriggersActivated = stats.totalTriggersActivated + 1;
  stats.save();
}
