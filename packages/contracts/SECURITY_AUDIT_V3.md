# BastionSwap Security Audit V3

**Date:** 2026-03-17
**Scope:** All contracts in `packages/contracts/src/` (BastionHook, EscrowVault, InsurancePool, TriggerOracle, ReputationEngine, BastionSwapRouter, BastionPositionRouter)
**Method:** Manual review + Slither static analysis
**Auditor:** Claude Opus 4.6

---

## Executive Summary

| Severity | Count | Status |
|----------|-------|--------|
| Critical | 1 | Acknowledged |
| High     | 3 | All Fixed |
| Medium   | 3 | Open |
| Low      | 4 | L-01, L-02 Fixed |
| Informational | 2 | — |

---

## Critical

### C-01: Issuer Sell Limits Bypassable via Non-Cooperating Router

**Status: ACKNOWLEDGED — Will Not Fix**

**Location:** `BastionHook.sol:489`

**Description:**

The hook identifies the actual swapper using hookData:

```solidity
address actualSwapper = (hookData.length == 32) ? abi.decode(hookData, (address)) : sender;
```

If `hookData.length != 32`, the hook falls back to `sender`, which is the **router contract address** (the contract that called `poolManager.swap()`), not the end-user. Only `BastionSwapRouter` cooperates by passing `abi.encode(sender)` as hookData.

The issuer can deploy a minimal contract that calls `poolManager.unlock()` → `poolManager.swap()` without passing hookData. The hook will see the custom contract address as `actualSwapper`, which is not `poolIssuer`, so all sell limits are bypassed.

**Why Acknowledged:**

This is a fundamental on-chain identity limitation, not a fixable bug. The issuer bypassing via a custom router is equivalent to transferring tokens to another wallet and selling — something ERC-20 `transfer` always allows, and the Hook has no authority to block.

Introducing an approved-router allowlist would:
- Restrict regular users' swaps (must use whitelisted routers)
- Create perpetual aggregator/router whitelist management burden
- Break the core value proposition: "protected from any frontend/router"

**Mitigation (off-chain):**
- Frontend dashboard shows "Issuer holds X% outside LP" warning
- ReputationEngine tracks issuer behavior for user risk assessment
- Token-level transfer restrictions (if token contract cooperates) remain an option for issuers who want stronger guarantees

---

## High

### H-01: Fallback Insurance Claims Allow Double-Dipping via Token Transfers

**Status: FIXED** — Token lockup added in `claimCompensationFallback`

**Location:** `InsurancePool.sol:312-342`

**Description:**

In fallback mode (`claimCompensationFallback`), the holder's balance is verified via `balanceOf` at claim time. The `claimed` mapping is per-address. An attacker could:
1. Hold tokens at address A when trigger fires
2. Wait for fallback mode (24h after trigger)
3. Claim from address A with `holderBalance = actual balance`
4. Transfer tokens to address B
5. Claim from address B with the same tokens

**Impact:** An attacker with a relatively small token position could drain the majority of the insurance pool in fallback mode, leaving legitimate holders with nothing.

**Fix Applied:**

Added `safeTransferFrom` to lock the claimer's issued tokens into the InsurancePool contract before executing the claim. This prevents transfer-and-reclaim attacks since the tokens are no longer in the claimer's wallet after claiming.

```solidity
// InsurancePool.sol — claimCompensationFallback, before _executeClaimTransfers:
SafeTransferLib.safeTransferFrom(ERC20(pool.issuedToken), msg.sender, address(this), holderBalance);
```

Note: Claimers must `approve` the InsurancePool to transfer their issued tokens before calling `claimCompensationFallback`. Frontend must guide the approve step (or use Permit2).

---

### H-02: Unclaimed Insurance Funds Permanently Locked After Claim Expiry

**Status: FIXED** — `sweepExpiredPool` added to InsurancePool

**Location:** `InsurancePool.sol:392-410`

**Description:**

After a trigger event, claimants have a limited window. After expiry, no claims are possible and `executeEmergencyWithdraw` blocks triggered pools (`AlreadyTriggered`). Unclaimed ETH, issued tokens, and base tokens become permanently locked.

**Fix Applied:**

Added `sweepExpiredPool(PoolId poolId)` function (governance-only, nonReentrant):
- Requires pool to be triggered
- Requires all claim periods to have expired + 30-day grace period
- Sweeps remaining ETH, issued tokens, and ERC-20 base tokens to treasury
- Uses `balanceOf` for token amounts to capture any rounding dust

---

### H-03: Inconsistent Trigger State When Force Removal Fails

**Status: FIXED** — try/catch removed; EscrowVault failure now reverts entire trigger

**Location:** `TriggerOracle.sol:193-238`

**Description:**

`TriggerOracle._executeImmediate` previously wrapped the `EscrowVault.triggerForceRemoval` call in try/catch. If it reverted, TriggerOracle silently continued with `isTriggered = true`, but EscrowVault and BastionHook states were rolled back — creating permanent inconsistency where the trigger couldn't be re-fired yet the issuer retained full LP access.

**Fix Applied:**

Replaced try/catch with a direct call so failure propagates and reverts the entire trigger transaction:

```solidity
// TriggerOracle._executeImmediate — was try/catch, now direct call:
if (issuer != address(0)) {
    uint256 escrowId = _computeEscrowId(poolId, issuer);
    IEscrowVault(ESCROW_VAULT).triggerForceRemoval(escrowId, uint8(triggerType));
}
```

If force removal fails, the entire trigger reverts atomically — no state inconsistency. The trigger can be re-attempted after the underlying issue is resolved.

---

## Medium

### M-01: Issuer LP Addition via addLiquidityV2 Causes Accounting Mismatch

**Status: Open**

**Location:** `BastionHook.sol:317-328`

**Description:**

When the issuer adds liquidity after pool creation via `BastionPositionRouter.addLiquidityV2`, the router uses `salt = bytes32(uint256(uint160(sender)))` (BastionPositionRouter.sol:617). However, BastionHook's `beforeAddLiquidity` detects this as an issuer addition and increments `_issuerLiquidity`:

```solidity
} else if (liquidity > 0 && sender == _issuerLPOwner[poolId]) {
    if (hookData.length > 0) {
        address user = abi.decode(hookData, (address));
        if (user == _issuers[poolId]) {
            escrowVault.addLiquidity(escrowId, liquidity);
            _issuerLiquidity[poolId] += liquidity;  // line 326
        }
    }
}
```

The additional LP goes to `salt = issuerAddress` (a different position than `salt = 0`), but `_issuerLiquidity` tracks it as if it were at `salt = 0`. During force removal, `forceRemoveIssuerLP` attempts to remove `_issuerLiquidity` amount from `salt = 0`, which will revert in PoolManager.

**Impact:** Force removal breaks for any pool where the issuer adds LP via `addLiquidityV2`. With H-03 fixed, this will cause the entire trigger to revert atomically (no inconsistency), but the trigger cannot succeed until the mismatch is resolved.

**Recommended Fix:**

Either:
1. Don't track `addLiquidityV2` additions as issuer LP (they're in a different position)
2. Or force all issuer additions to use salt=0 via a dedicated `addIssuerLiquidity` path

---

### M-02: Reverting Issuer Contract Permanently Blocks Treasury Claims

**Status: Open**

**Location:** `InsurancePool.sol:527-529`

**Description:**

In `claimTreasuryFunds`, the issuer's reward is sent via low-level call:

```solidity
if (issuerEth > 0) {
    (bool s1,) = issuer.call{value: issuerEth}("");
    if (!s1) revert TransferFailed();  // line 529
}
```

If the issuer address is a contract that reverts on ETH receipt, the entire `claimTreasuryFunds` transaction reverts permanently. Similarly, if USDC blacklists the issuer address, the `safeTransfer` at line 547 reverts, blocking all ERC-20 fee claims.

**Recommended Fix:**

Use a pull pattern or try/catch, sending failed issuer portion to treasury:
```solidity
(bool s1,) = issuer.call{value: issuerEth}("");
if (!s1) {
    (bool s2,) = treasury.call{value: issuerEth}("");
    if (!s2) revert TransferFailed();
}
```

---

### M-03: No Emergency Withdrawal Path for ERC-20 Tokens in InsurancePool

**Status: Open**

**Location:** `InsurancePool.sol:392-410`

**Description:**

The emergency withdrawal system only handles ETH. ERC-20 base token fees (`pool.baseTokenFeeBalance`) and escrow tokens have no emergency extraction path. If a pool accumulates significant ERC-20 fees but is never triggered and the issuer never completes vesting, those tokens are permanently locked.

**Note:** For triggered pools, the new `sweepExpiredPool` (H-02 fix) handles post-claim-period ERC-20 recovery. This M-03 issue only affects **non-triggered** pools.

**Recommended Fix:**

Add ERC-20 emergency withdrawal with the same timelock pattern as ETH emergency withdrawal.

---

## Low

### L-01: Missing Zero-Address Check in setBastionRouter

**Status: FIXED**

**Location:** `BastionHook.sol:611-616`, `BastionPositionRouter.sol:101-104`, `BastionSwapRouter.sol:90-93`

**Fix Applied:** Added `if (router == address(0)) revert ZeroAddress();` (or `hook == address(0)`) to all three one-time setter functions:
- `BastionHook.setBastionRouter`
- `BastionPositionRouter.setBastionHook`
- `BastionSwapRouter.setBastionHook`

---

### L-02: Missing Zero-Address Check for Treasury in InsurancePool Constructor

**Status: FIXED**

**Location:** `InsurancePool.sol:160-176`

**Fix Applied:** Added `if (treasury_ == address(0)) revert ZeroAddress();` in the constructor.

---

### L-03: beforeSwap First-Layer Sell Check Uses Wrong Amount for exactOutput Swaps

**Status: Open**

**Location:** `BastionHook.sol:507-509`

**Description:**

For exactOutput sells (`amountSpecified > 0`), the first-layer check in `beforeSwap` uses the output amount as the sell amount, which is incorrect. The second layer (`afterSwap`) correctly uses `BalanceDelta`, so no actual bypass occurs.

**Impact:** Low — second layer catches the real amount.

---

### L-04: Post-Swap Reserve Measurement Slightly Inflates Sell Limit Denominator

**Status: Open**

**Location:** `BastionHook.sol:562, 1221`

**Description:**

`_getPoolIssuedTokenReserve` is called after the swap, so the issuer's sell increases the denominator slightly. The effect is self-dampening and not practically exploitable.

---

## Informational

### I-01: totalEligibleSupply Uses Creation-Time Supply, Not Trigger-Time

**Location:** `BastionHook.sol:912-913`, `TriggerOracle.sol:262`

For mintable/burnable tokens, creation-time supply may differ from trigger-time supply, causing pro-rata claim inaccuracies. Document this limitation for issuers.

---

### I-02: Slither False Positives Summary

| Detector | Finding | Verdict |
|----------|---------|---------|
| `divide-before-multiply` | `(MIN_TICK / tickSpacing) * tickSpacing` | **False positive** — intentional tick alignment |
| `arbitrary-send-erc20` | `safeTransferFrom(sender, poolManager, amount)` | **False positive** — `sender` is `msg.sender` from unlock callback |
| `arbitrary-send-eth` | `_refundETH()` sends to `msg.sender` | **False positive** — correct refund behavior |
| `uninitialized-state` | `InsurancePool._pools` | **False positive** — mappings initialized lazily |
| `incorrect-equality` | `removable == 0` in EscrowVault | **False positive** — correct zero check |
| `reentrancy-no-eth` | EscrowVault.triggerForceRemoval | **True finding but mitigated** — protected by `nonReentrant` |

---

## Verification

| Check | Result |
|-------|--------|
| `forge build` | Compiled successfully |
| `forge build --sizes` | All contracts < 24,576 bytes (BastionHook: 24,524) |
| Non-fork tests | **396 passed**, 0 failed |
| Fork tests (Base mainnet) | **86 passed**, 0 failed |
| **Total** | **482 passed**, 0 failed |
| Critical fixes needed | 0 (C-01 Acknowledged) |
| High fixes needed | 0 (All fixed) |
