export const CONTRACTS = {
  84532: {
    BastionHook: "0x248B92269Bb935d76D871D5E271f29879A144AC0",
    EscrowVault: "0x2C01998931380d7F4f3F292aa1023B51CDeA9dcD",
    InsurancePool: "0x4EFE9E50d5bA7774459bea20f656aBBFd1887a98",
    TriggerOracle: "0x04D369129F5722E8d4a9621F0AE8247BE487Ec82",
    ReputationEngine: "0x0a5a7346c64FC65Ce1AdFA21eA98931bd4A38b4E",
    PoolManager: "0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408",
  },
} as const;

export type SupportedChainId = keyof typeof CONTRACTS;

export function getContracts(chainId: number) {
  return CONTRACTS[chainId as SupportedChainId];
}
