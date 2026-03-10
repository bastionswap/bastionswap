import { LOCAL_CONTRACTS } from "./contracts.generated";

export const CONTRACTS = {
  84532: {
    BastionHook: "0x61590C0544B562571AAad49e255496a0a0350AC8",
    EscrowVault: "0xBE3D91851aAf9F6A2ca8B47567180305996E16Dd",
    InsurancePool: "0xf908a6c13C80290993A7c2d57023c8531Ecf3406",
    TriggerOracle: "0x782b6e95072f88fcc7729F46c5FF19a1Fdad2D3b",
    ReputationEngine: "0x3eC8DeFc934fbD99fC64EFBae4B7e72f24DAF034",
    PoolManager: "0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408",
    BastionSwapRouter: "0xF21Ae872b7C544b83b25b1D639190Dd98C7a8062",
    BastionPositionRouter: "0x7Bcf5618c55AadDD2451b93102285267622Bb67A",
  },
} as const;

const ALL_CONTRACTS: Record<number, Record<string, string>> = {
  ...CONTRACTS,
  ...LOCAL_CONTRACTS,
};

export type SupportedChainId = keyof typeof CONTRACTS | keyof typeof LOCAL_CONTRACTS;

export function getContracts(chainId: number) {
  return ALL_CONTRACTS[chainId];
}
