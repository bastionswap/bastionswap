import { formatUnits } from "viem";

export function shortenAddress(address: string, chars = 4): string {
  return `${address.slice(0, chars + 2)}...${address.slice(-chars)}`;
}

export function formatTokenAmount(
  amount: bigint,
  decimals = 18,
  displayDecimals = 4
): string {
  const formatted = formatUnits(amount, decimals);
  const num = parseFloat(formatted);
  if (num === 0) return "0";
  if (num < 0.0001) return "<0.0001";
  return num.toLocaleString("en-US", {
    maximumFractionDigits: displayDecimals,
  });
}

export function formatUSD(amount: number): string {
  return new Intl.NumberFormat("en-US", {
    style: "currency",
    currency: "USD",
  }).format(amount);
}

export function formatBps(bps: number): string {
  return `${(bps / 100).toFixed(2)}%`;
}

export function formatDuration(seconds: number): string {
  const days = Math.floor(seconds / 86400);
  const hours = Math.floor((seconds % 86400) / 3600);
  if (days > 0) return `${days}d ${hours}h`;
  const minutes = Math.floor((seconds % 3600) / 60);
  return `${hours}h ${minutes}m`;
}

export function timeUntil(timestamp: number): string {
  const now = Math.floor(Date.now() / 1000);
  const diff = timestamp - now;
  if (diff <= 0) return "Now";
  return formatDuration(diff);
}

/** Format a numeric string with thousand separators (e.g. "1234567.89" → "1,234,567.89") */
export function formatWithCommas(value: string): string {
  if (!value) return "";
  const [intPart, decPart] = value.split(".");
  const formatted = intPart.replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  return decPart !== undefined ? `${formatted}.${decPart}` : formatted;
}

/** Strip commas and return raw value only if it's a valid partial number, otherwise return null */
export function sanitizeNumericInput(raw: string): string | null {
  const stripped = raw.replace(/,/g, "");
  if (stripped === "" || /^\d*\.?\d*$/.test(stripped)) return stripped;
  return null;
}

export function explorerUrl(
  addressOrTx: string,
  type: "address" | "tx" = "address"
): string {
  return `https://sepolia.basescan.org/${type}/${addressOrTx}`;
}
