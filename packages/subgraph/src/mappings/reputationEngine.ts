import { ReputationUpdated } from "../../generated/ReputationEngine/ReputationEngine";
import { getOrCreateIssuer } from "./helpers";

export function handleReputationUpdated(event: ReputationUpdated): void {
  let issuer = getOrCreateIssuer(
    event.params.issuer.toHexString(),
    event.block.timestamp
  );
  issuer.reputationScore = event.params.newScore;
  issuer.lastUpdated = event.block.timestamp;

  // Track escrow completions (EventType.ESCROW_COMPLETED = 0)
  if (event.params.eventType == 0) {
    issuer.totalEscrowsCompleted = issuer.totalEscrowsCompleted + 1;
  }

  issuer.save();
}
