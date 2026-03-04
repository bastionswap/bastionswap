import {
  assert,
  describe,
  test,
  clearStore,
  beforeEach,
  newMockEvent,
} from "matchstick-as";
import { Address, BigInt, Bytes } from "@graphprotocol/graph-ts";
import {
  IssuerRegistered,
  InsuranceFeeDeposited,
} from "../generated/BastionHook/BastionHook";
import {
  handleIssuerRegistered,
  handleInsuranceFeeDeposited,
} from "../src/mappings/bastionHook";

let POOL_ID = Bytes.fromHexString(
  "0x0000000000000000000000000000000000000000000000000000000000000001"
);
let ISSUER = Address.fromString("0x0000000000000000000000000000000000000001");
let TOKEN = Address.fromString("0x0000000000000000000000000000000000000002");

function createIssuerRegisteredEvent(): IssuerRegistered {
  let event = changetype<IssuerRegistered>(newMockEvent());
  event.parameters = [];
  event.parameters.push(
    new ethereum.EventParam("poolId", ethereum.Value.fromFixedBytes(POOL_ID))
  );
  event.parameters.push(
    new ethereum.EventParam("issuer", ethereum.Value.fromAddress(ISSUER))
  );
  event.parameters.push(
    new ethereum.EventParam(
      "issuedToken",
      ethereum.Value.fromAddress(TOKEN)
    )
  );
  return event;
}

function createInsuranceFeeDepositedEvent(
  amount: BigInt
): InsuranceFeeDeposited {
  let event = changetype<InsuranceFeeDeposited>(newMockEvent());
  event.parameters = [];
  event.parameters.push(
    new ethereum.EventParam("poolId", ethereum.Value.fromFixedBytes(POOL_ID))
  );
  event.parameters.push(
    new ethereum.EventParam("amount", ethereum.Value.fromUnsignedBigInt(amount))
  );
  return event;
}

import { ethereum } from "@graphprotocol/graph-ts";

describe("BastionHook", () => {
  beforeEach(() => {
    clearStore();
  });

  test("IssuerRegistered creates Pool and Issuer", () => {
    let event = createIssuerRegisteredEvent();
    handleIssuerRegistered(event);

    let poolId = POOL_ID.toHexString();
    assert.entityCount("Pool", 1);
    assert.fieldEquals("Pool", poolId, "isBastion", "true");
    assert.fieldEquals("Pool", poolId, "issuer", ISSUER.toHexString());

    assert.entityCount("Issuer", 1);
    assert.fieldEquals(
      "Issuer",
      ISSUER.toHexString(),
      "totalEscrowsCreated",
      "0"
    );

    assert.entityCount("InsurancePool", 1);
    assert.fieldEquals("InsurancePool", poolId, "balance", "0");

    assert.fieldEquals("ProtocolStats", "global", "totalBastionPools", "1");
  });

  test("InsuranceFeeDeposited increases balance", () => {
    // Setup: create pool first
    let regEvent = createIssuerRegisteredEvent();
    handleIssuerRegistered(regEvent);

    let amount = BigInt.fromString("1000000000000000000"); // 1 ETH
    let feeEvent = createInsuranceFeeDepositedEvent(amount);
    handleInsuranceFeeDeposited(feeEvent);

    let poolId = POOL_ID.toHexString();
    assert.fieldEquals("InsurancePool", poolId, "balance", "1");
  });
});
