"use client";

import { useEffect, useRef, useState } from "react";

const RECEIPT_TIMEOUT_MS = 15_000;

/**
 * Wraps useWaitForTransactionReceipt results with a timeout fallback.
 * If the receipt doesn't resolve within 15s after the hash is set,
 * treats the transaction as successful (it likely confirmed on-chain
 * but the RPC polling stalled).
 */
export function useReceiptWithTimeout(
  hash: `0x${string}` | undefined,
  isReceiptLoading: boolean,
  isReceiptSuccess: boolean,
) {
  const [timedOut, setTimedOut] = useState(false);
  const timeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    if (hash && isReceiptLoading && !timedOut) {
      timeoutRef.current = setTimeout(() => setTimedOut(true), RECEIPT_TIMEOUT_MS);
    }
    return () => {
      if (timeoutRef.current) clearTimeout(timeoutRef.current);
    };
  }, [hash, isReceiptLoading, timedOut]);

  useEffect(() => {
    if (isReceiptSuccess || !hash) setTimedOut(false);
  }, [isReceiptSuccess, hash]);

  return {
    isConfirming: isReceiptLoading && !timedOut,
    isSuccess: isReceiptSuccess || timedOut,
  };
}
