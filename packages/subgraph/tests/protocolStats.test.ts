import {
  assert,
  describe,
  test,
  clearStore,
  beforeEach,
  newMockEvent,
} from "matchstick-as";
import { Address, BigInt, Bytes, ethereum } from "@graphprotocol/graph-ts";
import { IssuerRegistered } from "../generated/BastionHook/BastionHook";
import { EscrowCreated } from "../generated/EscrowVault/EscrowVault";
import { CompensationClaimed } from "../generated/InsurancePool/InsurancePool";
import { TriggerExecuted } from "../generated/TriggerOracle/TriggerOracle";
import { handleIssuerRegistered } from "../src/mappings/bastionHook";
import { handleEscrowVaultCreated } from "../src/mappings/escrowVault";
import { handleCompensationClaimed } from "../src/mappings/insurancePool";
import { handleTriggerExecuted } from "../src/mappings/triggerOracle";

let POOL_ID_1 = Bytes.fromHexString(
  "0x0000000000000000000000000000000000000000000000000000000000000001"
);
let POOL_ID_2 = Bytes.fromHexString(
  "0x0000000000000000000000000000000000000000000000000000000000000002"
);
let ISSUER = Address.fromString("0x0000000000000000000000000000000000000001");
let TOKEN = Address.fromString("0x0000000000000000000000000000000000000002");
let HOLDER = Address.fromString("0x0000000000000000000000000000000000000099");

function registerPool(poolId: Bytes): void {
  let event = changetype<IssuerRegistered>(newMockEvent());
  event.parameters = [];
  event.parameters.push(
    new ethereum.EventParam("poolId", ethereum.Value.fromFixedBytes(poolId))
  );
  event.parameters.push(
    new ethereum.EventParam("issuer", ethereum.Value.fromAddress(ISSUER))
  );
  event.parameters.push(
    new ethereum.EventParam("issuedToken", ethereum.Value.fromAddress(TOKEN))
  );
  handleIssuerRegistered(event);
}

describe("ProtocolStats", () => {
  beforeEach(() => {
    clearStore();
  });

  test("Aggregates correctly across multiple events", () => {
    // Register two pools
    registerPool(POOL_ID_1);
    registerPool(POOL_ID_2);
    assert.fieldEquals("ProtocolStats", "global", "totalBastionPools", "2");

    // Create escrow for pool 1
    let escrowEvent = changetype<EscrowCreated>(newMockEvent());
    escrowEvent.parameters = [];
    escrowEvent.parameters.push(
      new ethereum.EventParam(
        "escrowId",
        ethereum.Value.fromUnsignedBigInt(BigInt.fromI32(1))
      )
    );
    escrowEvent.parameters.push(
      new ethereum.EventParam(
        "poolId",
        ethereum.Value.fromFixedBytes(POOL_ID_1)
      )
    );
    escrowEvent.parameters.push(
      new ethereum.EventParam("issuer", ethereum.Value.fromAddress(ISSUER))
    );
    escrowEvent.parameters.push(
      new ethereum.EventParam(
        "amount",
        ethereum.Value.fromUnsignedBigInt(
          BigInt.fromString("10000000000000000000")
        )
      )
    );
    handleEscrowVaultCreated(escrowEvent);
    assert.fieldEquals("ProtocolStats", "global", "totalEscrowLocked", "10");

    // Trigger executed
    let triggerEvent = changetype<TriggerExecuted>(newMockEvent());
    triggerEvent.parameters = [];
    triggerEvent.parameters.push(
      new ethereum.EventParam(
        "poolId",
        ethereum.Value.fromFixedBytes(POOL_ID_1)
      )
    );
    triggerEvent.parameters.push(
      new ethereum.EventParam(
        "triggerType",
        ethereum.Value.fromUnsignedBigInt(BigInt.fromI32(1))
      )
    );
    triggerEvent.parameters.push(
      new ethereum.EventParam(
        "withMerkleRoot",
        ethereum.Value.fromBoolean(false)
      )
    );
    handleTriggerExecuted(triggerEvent);
    assert.fieldEquals(
      "ProtocolStats",
      "global",
      "totalTriggersActivated",
      "1"
    );

    // Compensation claimed
    let claimEvent = changetype<CompensationClaimed>(newMockEvent());
    claimEvent.parameters = [];
    claimEvent.parameters.push(
      new ethereum.EventParam(
        "poolId",
        ethereum.Value.fromFixedBytes(POOL_ID_1)
      )
    );
    claimEvent.parameters.push(
      new ethereum.EventParam("holder", ethereum.Value.fromAddress(HOLDER))
    );
    claimEvent.parameters.push(
      new ethereum.EventParam(
        "amount",
        ethereum.Value.fromUnsignedBigInt(
          BigInt.fromString("2000000000000000000")
        )
      )
    );
    handleCompensationClaimed(claimEvent);
    assert.fieldEquals(
      "ProtocolStats",
      "global",
      "totalCompensationPaid",
      "2"
    );
  });
});
