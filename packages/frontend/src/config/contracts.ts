import { LOCAL_CONTRACTS } from "./contracts.generated";

export const CONTRACTS = {
  84532: {
    BastionHook: "0x31215Df7FC43e8fe65D8d307dfa23C420A384Ac8",
    EscrowVault: "0x49b84547934F79401763eCB2B45Ad50283b936DC",
    InsurancePool: "0x4946726489ca14943D37A73201c74CdB42b544b7",
    TriggerOracle: "0xaD9bf0659DdbcF9380183dE0FB6f2b38Edc25c33",
    ReputationEngine: "0xce4F36907E7602D32A239d4D8c068a8b38A3cfA3",
    PoolManager: "0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408",
    BastionSwapRouter: "0x836BDc9FD273E7D04440A3c020b803C9f93a7A28",
    BastionPositionRouter: "0x47D59B67b2E39E74443Dbdb84B0dEf9E00F19537",
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
