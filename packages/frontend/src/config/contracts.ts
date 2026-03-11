import { LOCAL_CONTRACTS } from "./contracts.generated";

export const CONTRACTS = {
  84532: {
    BastionHook: "0x88214539803B55a86f7e924BCE0eECB6B610cac8",
    EscrowVault: "0x0e7A077Bbc902f179Ae136D3a9810b97eB1aEB3b",
    InsurancePool: "0x9646d06B5d7F914481214e8870C883a4D2B5f858",
    TriggerOracle: "0x3909f264a3f92622c05420Fb0af6F219600825B8",
    ReputationEngine: "0x093D568eCc2620Af3E11Eb2906a5DdC08Defa0d8",
    PoolManager: "0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408",
    BastionSwapRouter: "0x8997d846A8bF5E8Ef662aFC620f35aB692dc166C",
    BastionPositionRouter: "0x3Ae0B68e0e36A57d8e416CD4e57d89058d0d1A11",
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
