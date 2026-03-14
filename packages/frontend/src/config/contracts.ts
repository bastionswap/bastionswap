import { LOCAL_CONTRACTS } from "./contracts.generated";

export const CONTRACTS = {
  84532: {
    BastionHook: "0x6Bc8b16a0cD4820099bC4dEC7896f0840f304aC8",
    EscrowVault: "0x7Fc45a47b54F94FD4cB810A955465490070F664b",
    InsurancePool: "0xD06A57C4Be09B89dc3ca48edB1D9dF1f00F18669",
    TriggerOracle: "0x6Dbf4B751e73e6267c8712c153B116b2d1AD0b2f",
    ReputationEngine: "0x1C04B5363645f046bE48F6874d514687Ad0d58A4",
    PoolManager: "0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408",
    BastionSwapRouter: "0x33F31B691bDe1Cf4f820AE304ab199c28f04aba8",
    BastionPositionRouter: "0xb1B60977ba79346F01df2b733298F73392895c4C",
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
