/**
 * Convert sqrtPriceX96 to a human-readable price (token1 per token0),
 * adjusted for token decimal differences.
 */
export function sqrtPriceX96ToPrice(
  sqrtPriceX96: bigint,
  token0Decimals: number,
  token1Decimals: number
): number {
  const price = Number(sqrtPriceX96) ** 2 / 2 ** 192;
  return price * 10 ** (token0Decimals - token1Decimals);
}
