export const CONTRACTS = {
  84532: {
    BastionHook: "0x243bD148C9DFeE05584182d420f319e234D80AC0",
    EscrowVault: "0xC36E784E1dff616bDae4EAc7B310F0934FaF04a4",
    InsurancePool: "0xB98E0Fb673e5a0C6e15F1D0a9f36E7dA954A0D5E",
    TriggerOracle: "0xD2BD10D3f2e3a057F0040663B1EEbf4d1874fEAB",
    ReputationEngine: "0x78dA752e9dBD73a9b0C0F5ddD15e854D2B879524",
    PoolManager: "0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408",
  },
} as const;

export type SupportedChainId = keyof typeof CONTRACTS;

export function getContracts(chainId: number) {
  return CONTRACTS[chainId as SupportedChainId];
}
