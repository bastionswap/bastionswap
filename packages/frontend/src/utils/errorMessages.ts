/**
 * Maps contract revert errors and common wallet errors to user-friendly messages.
 */

// ─── Selector → friendly message (4-byte error selectors) ──────────
const SELECTOR_MAP: Record<string, string> = {
  // BastionSwapRouter
  "0x203d82d8": "Transaction expired. Please try again.",
  "0x2c19b8b8": "Swap would produce less than your minimum. Increase slippage or reduce amount.",
  "0xce8c6762": "Swap would require more than your maximum. Increase slippage or reduce amount.",
  "0x0a83c852": "Too many hops in multi-hop route (max 4).",
  "0xbbaf8a8b": "No swap route found between these tokens.",
  "0x86972930": "Protocol not fully initialized. Please try again later.",

  // BastionHook: Issuer Limits
  "0xd029a970": "Daily sell limit exceeded. You cannot sell more issued tokens today.",
  "0x61515b9d": "Weekly sell limit exceeded. You cannot sell more issued tokens this week.",
  "0x04b52046": "Sell limit exceeded. Your cumulative sells have breached the allowed threshold.",
  "0x14b4b54a": "This pool has been triggered. Issuer sells and LP removal are permanently blocked.",
  "0x8b6c93dc": "Daily LP removal limit exceeded. Try again tomorrow.",
  "0x260cf2bd": "Weekly LP removal limit exceeded. Try again next week.",

  // BastionHook: Pool / Liquidity
  "0xcaedca12": "Cannot remove more LP than vested amount. Check your vesting schedule.",
  "0x14e6fd6b": "This pool has been flagged. Fee collection is blocked.",
  "0xcc5bd5e9": "Base token amount is below the required minimum.",
  "0x6caeec78": "At least one token must be an allowed base token (ETH, WETH, or USDC).",
  "0xd59b569a": "Invalid pool creation data.",
  "0xa84b0dcd": "Pool TVL cap exceeded. Try a smaller amount.",
  "0x7983c051": "A pool already exists for this token pair.",
  "0x4eb4f9fb": "Value out of allowed range.",
  "0xd92e233d": "Invalid address (zero address).",
  "0xe140b7f2": "Swapper must be identified via hookData. Use BastionSwapRouter.",
  "0xac99fced": "Commitment parameters are too lenient.",
  "0x49eeb0b3": "Lock duration is too short.",
  "0x1543817c": "Vesting duration is too short.",

  // V4 PoolManager
  "0x486aa307": "Pool not initialized.",
  "0xbe8b8507": "Swap amount cannot be zero.",
};

// WrappedError(address,bytes) and Wrap__FailedHookCall(address,bytes)
const WRAPPED_ERROR_SELECTOR = "0x965668b8";
const FAILED_HOOK_CALL_SELECTOR = "0x319d54c3";
// Wrap__FailedHookCall(address,bytes4,bytes,bytes) — V4 hook call failure with extra args
const FAILED_HOOK_CALL_V2_SELECTOR = "0x90bfb865";

const WRAPPER_SELECTORS = new Set([
  WRAPPED_ERROR_SELECTOR,
  FAILED_HOOK_CALL_SELECTOR,
  FAILED_HOOK_CALL_V2_SELECTOR,
]);

/**
 * Try to extract the inner error selector from wrapped error data.
 *
 * Format 1: WrappedError(address,bytes) / Wrap__FailedHookCall(address,bytes)
 *   selector(4) + address(32) + offset(32) + length(32) + innerData(...)
 *   Inner selector at hex position 200.
 *
 * Format 2: Wrap__FailedHookCall(address,bytes4,bytes,bytes)
 *   selector(4) + address(32) + bytes4(32) + offset1(32) + offset2(32) + length(32) + innerData(...)
 *   Inner selector at hex position 328.
 */
function extractInnerSelector(data: string): string | null {
  const clean = data.startsWith("0x") ? data.slice(2) : data;
  const outerSelector = "0x" + clean.slice(0, 8);

  // Format 1: (address, bytes) — inner at position 200
  if (outerSelector === WRAPPED_ERROR_SELECTOR || outerSelector === FAILED_HOOK_CALL_SELECTOR) {
    if (clean.length >= 200 + 8) {
      const innerSelector = "0x" + clean.slice(200, 208);
      if (WRAPPER_SELECTORS.has(innerSelector)) {
        const deeper = extractInnerSelector("0x" + clean.slice(200));
        if (deeper) return deeper;
      }
      return innerSelector;
    }
  }

  // Format 2: (address, bytes4, bytes, bytes) — inner at position 328
  if (outerSelector === FAILED_HOOK_CALL_V2_SELECTOR) {
    if (clean.length >= 328 + 8) {
      const innerSelector = "0x" + clean.slice(328, 336);
      if (WRAPPER_SELECTORS.has(innerSelector)) {
        const deeper = extractInnerSelector("0x" + clean.slice(328));
        if (deeper) return deeper;
      }
      return innerSelector;
    }
  }

  return null;
}

/**
 * Try to find the error selector from the raw hex data string.
 * Exported so swap hooks can use it after re-simulation.
 */
export function matchSelector(data: string): string | null {
  if (!data || data.length < 10) return null;

  const selector = data.slice(0, 10).toLowerCase();

  // Direct match
  if (SELECTOR_MAP[selector]) return SELECTOR_MAP[selector];

  // Unwrap WrappedError / Wrap__FailedHookCall
  const inner = extractInnerSelector(data);
  if (inner && SELECTOR_MAP[inner]) return SELECTOR_MAP[inner];

  return null;
}

// ─── String pattern → friendly message ──────────────────────────────
const STRING_MAP: Record<string, string> = {
  // Wallet / Provider
  "User rejected": "Transaction rejected by user.",
  "User denied": "Transaction rejected by user.",
  "user rejected": "Transaction rejected by user.",

  // ERC-20 / Approval
  "insufficient allowance": "Token approval insufficient. Please approve first.",
  "transfer amount exceeds balance": "Insufficient token balance.",
  "ERC20: transfer amount exceeds balance": "Insufficient token balance.",

  // Permit2
  InvalidNonce: "Permit signature expired. Please try again.",
  SignatureExpired: "Permit signature expired. Please try again.",

  // Network
  "could not coalesce error": "Network error. Please check your connection and try again.",
  "network changed": "Network changed during transaction. Please try again.",
  "nonce too low": "Transaction conflict. Please try again.",
  "replacement fee too low": "A pending transaction is blocking. Speed it up or wait.",
  "insufficient funds for gas": "Not enough ETH for gas fees.",
};

/**
 * Parses a contract/wallet error and returns a user-friendly message.
 */
export function parseErrorMessage(error: unknown): string {
  if (!error) return "An unknown error occurred.";

  // 1. Try to extract error data from viem's ContractFunctionRevertedError
  const errData = extractErrorData(error);
  if (errData) {
    const matched = matchSelector(errData);
    if (matched) return matched;
  }

  // 2. Fall back to string matching on error message
  const message =
    error instanceof Error
      ? error.message
      : typeof error === "string"
        ? error
        : String(error);

  // Check string patterns
  for (const [pattern, friendly] of Object.entries(STRING_MAP)) {
    if (message.includes(pattern)) {
      return friendly;
    }
  }

  // 3. Try to find hex selectors in the message (e.g. "signature:\n0xd029a970")
  const hexMatches = message.match(/0x[0-9a-fA-F]{8,}/g);
  if (hexMatches) {
    for (const hex of hexMatches) {
      const matched = matchSelector(hex);
      if (matched) return matched;
    }
  }

  // 4. Check if any known error name appears in the message
  const nameMap: Record<string, string> = {
    IssuerDailySellExceeded: SELECTOR_MAP["0xd029a970"],
    IssuerWeeklySellExceeded: SELECTOR_MAP["0x61515b9d"],
    IssuerDumpDetected: SELECTOR_MAP["0x04b52046"],
    PoolTriggered: SELECTOR_MAP["0x14b4b54a"],
    DailyLpRemovalExceeded: SELECTOR_MAP["0x8b6c93dc"],
    WeeklyLpRemovalExceeded: SELECTOR_MAP["0x260cf2bd"],
    ExceedsVestedAmount: SELECTOR_MAP["0xcaedca12"],
    EscrowTriggered: SELECTOR_MAP["0x14e6fd6b"],
    ExceedsMaxTVL: SELECTOR_MAP["0xa84b0dcd"],
    BelowMinBaseAmount: SELECTOR_MAP["0xcc5bd5e9"],
    NoAllowedBaseToken: SELECTOR_MAP["0x6caeec78"],
    Expired: SELECTOR_MAP["0x203d82d8"],
    InsufficientOutput: SELECTOR_MAP["0x2c19b8b8"],
    ExcessiveInput: SELECTOR_MAP["0xce8c6762"],
    SlippageExceeded: "Price moved beyond your slippage tolerance. Try again or increase slippage.",
    TooManyHops: SELECTOR_MAP["0x0a83c852"],
    ZeroHops: SELECTOR_MAP["0xbbaf8a8b"],
    HookNotSet: SELECTOR_MAP["0x86972930"],
    InvalidHookData: SELECTOR_MAP["0xd59b569a"],
    PoolAlreadyInitialized: SELECTOR_MAP["0x7983c051"],
    MustIdentifyUser: SELECTOR_MAP["0xe140b7f2"],
  };
  for (const [name, friendly] of Object.entries(nameMap)) {
    if (message.includes(name)) return friendly;
  }

  // 5. Fallback: try to extract a short reason from the raw message
  const reasonMatch = message.match(/reason="([^"]+)"/);
  if (reasonMatch) return reasonMatch[1];

  const revertMatch = message.match(/reverted with reason string '([^']+)'/);
  if (revertMatch) return revertMatch[1];

  // Final fallback: truncate the raw message
  if (message.length > 120) return message.slice(0, 120) + "…";
  return message;
}

/**
 * Extract hex error data from a viem/wagmi error object.
 * Viem's ContractFunctionRevertedError exposes:
 *   - .raw: full hex revert data (e.g. "0x965668b8..." for WrappedError)
 *   - .signature: 4-byte selector (e.g. "0x965668b8")
 *   - .data: ABI-decoded data (often undefined if ABI lacks error def)
 * The error is typically nested: ContractFunctionExecutionError → ContractFunctionRevertedError
 */
function extractErrorData(error: unknown): string | null {
  if (!error || typeof error !== "object") return null;

  const err = error as any;

  // viem ContractFunctionRevertedError: .raw contains full hex revert data
  if (err.raw && typeof err.raw === "string" && err.raw.startsWith("0x")) {
    return err.raw;
  }

  // .signature is the 4-byte selector (fallback if .raw is missing)
  if (err.signature && typeof err.signature === "string" && err.signature.startsWith("0x")) {
    return err.signature;
  }

  // .data may contain hex string
  if (err.data && typeof err.data === "string" && err.data.startsWith("0x")) {
    return err.data;
  }

  // Check nested cause chain (viem wraps errors: ExecutionError → RevertedError)
  if (err.cause) {
    return extractErrorData(err.cause);
  }

  // wagmi sometimes puts it in err.walk?.()
  if (typeof err.walk === "function") {
    try {
      const walked = err.walk((e: any) => e?.raw || e?.signature);
      if (walked?.raw) return walked.raw;
      if (walked?.signature) return walked.signature;
    } catch {}
  }

  // Check err.info?.error?.data
  if (err.info?.error?.data && typeof err.info.error.data === "string") {
    return err.info.error.data;
  }

  return null;
}
