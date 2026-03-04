import {
  assert,
  describe,
  test,
  clearStore,
  beforeEach,
  newMockEvent,
} from "matchstick-as";
import { Address, BigInt, Bytes, ethereum } from "@graphprotocol/graph-ts";
import {
  EscrowCreated,
  VestedReleased,
  Redistributed,
} from "../generated/EscrowVault/EscrowVault";
import {
  handleEscrowVaultCreated,
  handleVestedReleased,
  handleRedistributed,
} from "../src/mappings/escrowVault";
import { handleIssuerRegistered } from "../src/mappings/bastionHook";
import { IssuerRegistered } from "../generated/BastionHook/BastionHook";

let POOL_ID = Bytes.fromHexString(
  "0x0000000000000000000000000000000000000000000000000000000000000001"
);
let ESCROW_ID = BigInt.fromI32(42);
let ISSUER = Address.fromString("0x0000000000000000000000000000000000000001");
let TOKEN = Address.fromString("0x0000000000000000000000000000000000000002");

function setupPool(): void {
  let event = changetype<IssuerRegistered>(newMockEvent());
  event.parameters = [];
  event.parameters.push(
    new ethereum.EventParam("poolId", ethereum.Value.fromFixedBytes(POOL_ID))
  );
  event.parameters.push(
    new ethereum.EventParam("issuer", ethereum.Value.fromAddress(ISSUER))
  );
  event.parameters.push(
    new ethereum.EventParam("issuedToken", ethereum.Value.fromAddress(TOKEN))
  );
  handleIssuerRegistered(event);
}

function createEscrowCreatedEvent(amount: BigInt): EscrowCreated {
  let event = changetype<EscrowCreated>(newMockEvent());
  event.parameters = [];
  event.parameters.push(
    new ethereum.EventParam(
      "escrowId",
      ethereum.Value.fromUnsignedBigInt(ESCROW_ID)
    )
  );
  event.parameters.push(
    new ethereum.EventParam("poolId", ethereum.Value.fromFixedBytes(POOL_ID))
  );
  event.parameters.push(
    new ethereum.EventParam("issuer", ethereum.Value.fromAddress(ISSUER))
  );
  event.parameters.push(
    new ethereum.EventParam("amount", ethereum.Value.fromUnsignedBigInt(amount))
  );
  return event;
}

describe("EscrowVault", () => {
  beforeEach(() => {
    clearStore();
    setupPool();
  });

  test("EscrowCreated creates Escrow entity", () => {
    let amount = BigInt.fromString("5000000000000000000"); // 5 ETH
    let event = createEscrowCreatedEvent(amount);
    handleEscrowVaultCreated(event);

    let escrowId = ESCROW_ID.toHexString();
    assert.entityCount("Escrow", 1);
    assert.fieldEquals("Escrow", escrowId, "totalLocked", "5");
    assert.fieldEquals("Escrow", escrowId, "released", "0");
    assert.fieldEquals("Escrow", escrowId, "remaining", "5");
    assert.fieldEquals("Escrow", escrowId, "isTriggered", "false");

    // Check issuer stats
    assert.fieldEquals(
      "Issuer",
      ISSUER.toHexString(),
      "totalEscrowsCreated",
      "1"
    );

    // Check protocol stats
    assert.fieldEquals("ProtocolStats", "global", "totalEscrowLocked", "5");
  });

  test("VestedReleased updates released and remaining", () => {
    let amount = BigInt.fromString("5000000000000000000"); // 5 ETH
    handleEscrowVaultCreated(createEscrowCreatedEvent(amount));

    let releaseEvent = changetype<VestedReleased>(newMockEvent());
    releaseEvent.parameters = [];
    releaseEvent.parameters.push(
      new ethereum.EventParam(
        "escrowId",
        ethereum.Value.fromUnsignedBigInt(ESCROW_ID)
      )
    );
    releaseEvent.parameters.push(
      new ethereum.EventParam(
        "releasedAmount",
        ethereum.Value.fromUnsignedBigInt(
          BigInt.fromString("2000000000000000000")
        )
      )
    );
    handleVestedReleased(releaseEvent);

    let escrowId = ESCROW_ID.toHexString();
    assert.fieldEquals("Escrow", escrowId, "released", "2");
    assert.fieldEquals("Escrow", escrowId, "remaining", "3");
  });

  test("Redistributed sets isTriggered flag", () => {
    let amount = BigInt.fromString("5000000000000000000");
    handleEscrowVaultCreated(createEscrowCreatedEvent(amount));

    let redistEvent = changetype<Redistributed>(newMockEvent());
    redistEvent.parameters = [];
    redistEvent.parameters.push(
      new ethereum.EventParam(
        "escrowId",
        ethereum.Value.fromUnsignedBigInt(ESCROW_ID)
      )
    );
    redistEvent.parameters.push(
      new ethereum.EventParam(
        "triggerType",
        ethereum.Value.fromUnsignedBigInt(BigInt.fromI32(1))
      )
    );
    redistEvent.parameters.push(
      new ethereum.EventParam(
        "redistributedAmount",
        ethereum.Value.fromUnsignedBigInt(
          BigInt.fromString("5000000000000000000")
        )
      )
    );
    handleRedistributed(redistEvent);

    let escrowId = ESCROW_ID.toHexString();
    assert.fieldEquals("Escrow", escrowId, "isTriggered", "true");
    assert.fieldEquals("Escrow", escrowId, "remaining", "0");
  });
});
