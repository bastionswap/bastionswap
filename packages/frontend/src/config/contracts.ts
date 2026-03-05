export const CONTRACTS = {
  84532: {
    BastionHook: "0xC85852313B9BE98Be4EA17E212caeb6BB56e4Ac0",
    EscrowVault: "0xADdb75264a16a9d5727c5743859a39B4d57CD669",
    InsurancePool: "0x86b43706D57f948f704836a13Eb989833EE44611",
    TriggerOracle: "0x221D8a269626C0C43970874571eab5a45a434683",
    ReputationEngine: "0x3a3160A9257FDaBbbD1CfEA6f31763B064D24A7f",
    PoolManager: "0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408",
    BastionRouter: "0x1aDcd4553C05a0A3eDDD022AF9788E4408D4395b",
  },
} as const;

export type SupportedChainId = keyof typeof CONTRACTS;

export function getContracts(chainId: number) {
  return CONTRACTS[chainId as SupportedChainId];
}
