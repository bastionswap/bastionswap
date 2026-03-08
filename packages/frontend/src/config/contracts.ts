import { LOCAL_CONTRACTS } from "./contracts.generated";

export const CONTRACTS = {
  84532: {
    BastionHook: "0x3E1fb370C3C38Ed972566E2eaF6fbBe6E9b44AC8",
    EscrowVault: "0x477e57e4c276D9E974c813Ba5c98C09a6CF8dB16",
    InsurancePool: "0x2f811557dCFFBa313c9E01b9aDBF55F3D0AB1540",
    TriggerOracle: "0x6DA43Ee5ba896D2e20d47Ff0E62Fa24C6eb9025b",
    ReputationEngine: "0xB6E7B03AE5161c9FD482e0f8156C8161601FaE3d",
    PoolManager: "0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408",
    BastionSwapRouter: "0x796E0773c5fe19c0C650abF1bAE5d2AEd995dA78",
    BastionPositionRouter: "0x6c195167000Be5ADbA07A4D43e68ba1D3a7C269b",
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
