/**
 * Maps contract revert errors and common wallet errors to user-friendly messages.
 */

const ERROR_MAP: Record<string, string> = {
  // ─── Wallet / Provider ────────────────────────────────
  "User rejected": "Transaction rejected by user.",
  "User denied": "Transaction rejected by user.",
  "user rejected": "Transaction rejected by user.",

  // ─── BastionRouter ────────────────────────────────────
  Expired: "Transaction expired. Please try again.",
  InsufficientOutput: "Swap would produce less than your minimum. Increase slippage or reduce amount.",
  ExcessiveInput: "Swap would require more than your maximum. Increase slippage or reduce amount.",
  SlippageExceeded: "Price moved beyond your slippage tolerance. Try again or increase slippage.",
  TooManyHops: "Too many hops in multi-hop route (max 4).",
  ZeroHops: "No swap route found between these tokens.",
  HookNotSet: "Protocol not fully initialized. Please try again later.",

  // ─── BastionHook ──────────────────────────────────────
  ExceedsVestedAmount: "Cannot remove more LP than vested amount. Check your vesting schedule.",
  EscrowTriggered: "This pool has been flagged. Fee collection is blocked.",
  BelowMinBaseAmount: "Base token amount is below the required minimum.",
  NoAllowedBaseToken: "At least one token must be an allowed base token (ETH, WETH, or USDC).",
  InvalidHookData: "Invalid pool creation data.",

  // ─── BastionHook: Issuer Limits ─────────────────────
  IssuerDailySellExceeded: "Daily sell limit exceeded. You cannot sell more issued tokens today.",
  IssuerWeeklySellExceeded: "Weekly sell limit exceeded. You cannot sell more issued tokens this week.",
  IssuerDumpDetected: "Sell limit exceeded. Your cumulative sells have breached the allowed threshold.",
  PoolTriggered: "This pool has been triggered. Issuer sells and LP removal are permanently blocked.",
  DailyLpRemovalExceeded: "Daily LP removal limit exceeded. Try again tomorrow.",
  WeeklyLpRemovalExceeded: "Weekly LP removal limit exceeded. Try again next week.",

  // ─── Pool ─────────────────────────────────────────────
  PoolAlreadyInitialized: "A pool already exists for this token pair.",
  "0x7983c051": "A pool already exists for this token pair.",

  // ─── ERC-20 / Approval ────────────────────────────────
  "insufficient allowance": "Token approval insufficient. Please approve first.",
  "transfer amount exceeds balance": "Insufficient token balance.",
  "ERC20: transfer amount exceeds balance": "Insufficient token balance.",

  // ─── Permit2 ──────────────────────────────────────────
  InvalidNonce: "Permit signature expired. Please try again.",
  SignatureExpired: "Permit signature expired. Please try again.",

  // ─── Network ──────────────────────────────────────────
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

  const message =
    error instanceof Error
      ? error.message
      : typeof error === "string"
        ? error
        : String(error);

  // Check each known pattern
  for (const [pattern, friendly] of Object.entries(ERROR_MAP)) {
    if (message.includes(pattern)) {
      return friendly;
    }
  }

  // Fallback: try to extract a short reason from the raw message
  const reasonMatch = message.match(/reason="([^"]+)"/);
  if (reasonMatch) return reasonMatch[1];

  const revertMatch = message.match(/reverted with reason string '([^']+)'/);
  if (revertMatch) return revertMatch[1];

  // Final fallback: truncate the raw message
  if (message.length > 120) return message.slice(0, 120) + "…";
  return message;
}
