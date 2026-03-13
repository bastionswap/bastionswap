import { LOCAL_CONTRACTS } from "./contracts.generated";

export const CONTRACTS = {
  84532: {
    BastionHook: "0x47fF5bd209FEB22ec88e43beC94074280fb34ac8",
    EscrowVault: "0x8e77cC19BC537934149f512a9D407131b1D5e4D0",
    InsurancePool: "0x2A6318a1ae6BB618EB24cAF77d8E3716c9F02A6E",
    TriggerOracle: "0xb5b66fcd286f5cE54040C55e56244aB200A192Dd",
    ReputationEngine: "0x8De50d4e18a990c2867E2C2D5d7693B62FAe6780",
    PoolManager: "0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408",
    BastionSwapRouter: "0xA4344dAb82C09FFD9ad4a10476b53C9e6c44e4cE",
    BastionPositionRouter: "0x05D0E576c2B1A3234B296f36c392CcE228eeE459",
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
