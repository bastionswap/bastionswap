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

/**
 * For full-range positions, given one token amount and sqrtPriceX96,
 * compute the required amount of the other token.
 *
 * Uses simplified ratio: amount1/amount0 = price, which is accurate
 * for full-range positions where tick bounds are extreme.
 */
export function computePairedAmount(
  sqrtPriceX96: bigint,
  inputAmount: bigint,
  isToken0: boolean,
  decimals0: number,
  decimals1: number
): bigint {
  const price = sqrtPriceX96ToPrice(sqrtPriceX96, decimals0, decimals1);
  if (price <= 0) return 0n;

  if (isToken0) {
    const amount0Float = Number(inputAmount) / 10 ** decimals0;
    const amount1Float = amount0Float * price;
    return BigInt(Math.floor(amount1Float * 10 ** decimals1));
  } else {
    const amount1Float = Number(inputAmount) / 10 ** decimals1;
    const amount0Float = amount1Float / price;
    return BigInt(Math.floor(amount0Float * 10 ** decimals0));
  }
}
