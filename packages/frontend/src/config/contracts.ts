import { LOCAL_CONTRACTS } from "./contracts.generated";

export const CONTRACTS = {
  84532: {
    BastionHook: "0xfeD3C0F50312cB437F999a03D98576115bA90Ac0",
    EscrowVault: "0x83D2A0be3C7f5728a560B76BBB29b0a2fDb97241",
    InsurancePool: "0x37ce342D5366999D2C526908e88772C61a45bC4a",
    TriggerOracle: "0x624d89EddE24BE86a971bDaf8268561d40D0c730",
    ReputationEngine: "0xeB8529cD6bE727355C07cc0685140ADE49198A43",
    PoolManager: "0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408",
    BastionRouter: "0x7D0789EE508A15FB2bE29CfaC81f51C51b733447",
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
