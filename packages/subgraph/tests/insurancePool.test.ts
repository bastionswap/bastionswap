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
  CompensationClaimed,
  PayoutExecuted,
} from "../generated/InsurancePool/InsurancePool";
import {
  handleCompensationClaimed,
  handlePayoutExecuted,
} from "../src/mappings/insurancePool";
import { handleIssuerRegistered } from "../src/mappings/bastionHook";
import { IssuerRegistered } from "../generated/BastionHook/BastionHook";

let POOL_ID = Bytes.fromHexString(
  "0x0000000000000000000000000000000000000000000000000000000000000001"
);
let ISSUER = Address.fromString("0x0000000000000000000000000000000000000001");
let HOLDER = Address.fromString("0x0000000000000000000000000000000000000099");
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

describe("InsurancePool", () => {
  beforeEach(() => {
    clearStore();
    setupPool();
  });

  test("CompensationClaimed creates Claim and updates totals", () => {
    let event = changetype<CompensationClaimed>(newMockEvent());
    event.parameters = [];
    event.parameters.push(
      new ethereum.EventParam("poolId", ethereum.Value.fromFixedBytes(POOL_ID))
    );
    event.parameters.push(
      new ethereum.EventParam("holder", ethereum.Value.fromAddress(HOLDER))
    );
    event.parameters.push(
      new ethereum.EventParam(
        "amount",
        ethereum.Value.fromUnsignedBigInt(
          BigInt.fromString("500000000000000000")
        )
      )
    );
    handleCompensationClaimed(event);

    let poolId = POOL_ID.toHexString();
    let claimId = poolId + "-" + HOLDER.toHexString();

    assert.entityCount("Claim", 1);
    assert.fieldEquals("Claim", claimId, "amount", "0.5");
    assert.fieldEquals("Claim", claimId, "holder", HOLDER.toHexString());

    assert.fieldEquals("InsurancePool", poolId, "totalClaimed", "0.5");
    assert.fieldEquals(
      "ProtocolStats",
      "global",
      "totalCompensationPaid",
      "0.5"
    );
  });

  test("PayoutExecuted updates trigger state", () => {
    let event = changetype<PayoutExecuted>(newMockEvent());
    event.parameters = [];
    event.parameters.push(
      new ethereum.EventParam("poolId", ethereum.Value.fromFixedBytes(POOL_ID))
    );
    event.parameters.push(
      new ethereum.EventParam(
        "triggerType",
        ethereum.Value.fromUnsignedBigInt(BigInt.fromI32(1))
      )
    );
    event.parameters.push(
      new ethereum.EventParam(
        "totalPayout",
        ethereum.Value.fromUnsignedBigInt(
          BigInt.fromString("1000000000000000000")
        )
      )
    );
    handlePayoutExecuted(event);

    let poolId = POOL_ID.toHexString();
    assert.fieldEquals("InsurancePool", poolId, "isTriggered", "true");
    assert.fieldEquals("InsurancePool", poolId, "triggerType", "1");
    assert.fieldEquals(
      "ProtocolStats",
      "global",
      "totalTriggersActivated",
      "1"
    );
  });
});
